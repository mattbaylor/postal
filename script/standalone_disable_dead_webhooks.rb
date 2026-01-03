#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone script to disable dead webhooks by connecting directly to MariaDB
# This script runs OUTSIDE Docker and reads credentials from postal.yml
#
# Usage:
#   ruby script/standalone_disable_dead_webhooks.rb [--live] [--config /path/to/postal.yml]
#
# Options:
#   --live           Actually disable webhooks (default is dry-run)
#   --config PATH    Path to postal.yml (default: /opt/postal/config/postal.yml)
#   --threshold N    Minimum failed requests to consider (default: 10)
#   --hours N        Look back window in hours (default: 24)
#
# Environment Variables:
#   DRY_RUN=false    Same as --live
#   CONFIG_PATH      Same as --config
#   FAILURE_THRESHOLD  Same as --threshold
#   TIME_WINDOW_HOURS  Same as --hours

require 'yaml'
require 'mysql2'
require 'optparse'

# Parse command line options
options = {
  dry_run: ENV['DRY_RUN'] != 'false',
  config_path: ENV['CONFIG_PATH'] || '/opt/postal/config/postal.yml',
  failure_threshold: (ENV['FAILURE_THRESHOLD'] || 10).to_i,
  time_window_hours: (ENV['TIME_WINDOW_HOURS'] || 24).to_i
}

OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} [options]"
  
  opts.on('--live', 'Actually disable webhooks (default is dry-run)') do
    options[:dry_run] = false
  end
  
  opts.on('--config PATH', 'Path to postal.yml') do |path|
    options[:config_path] = path
  end
  
  opts.on('--threshold N', Integer, 'Minimum failed requests') do |n|
    options[:failure_threshold] = n
  end
  
  opts.on('--hours N', Integer, 'Look back window in hours') do |n|
    options[:time_window_hours] = n
  end
  
  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit
  end
end.parse!

ERROR_STATUS_CODES = [-2, -1] # -2 = connection failed, -1 = other errors

# Print configuration
puts "=" * 80
puts "Dead Webhook Detector (Standalone)"
puts "=" * 80
puts "Mode: #{options[:dry_run] ? 'DRY RUN (no changes)' : 'LIVE (will disable webhooks)'}"
puts "Config: #{options[:config_path]}"
puts "Threshold: #{options[:failure_threshold]} failed requests in last #{options[:time_window_hours]} hours"
puts "Error codes: #{ERROR_STATUS_CODES.join(', ')}"
puts "=" * 80
puts

# Load postal configuration
unless File.exist?(options[:config_path])
  puts "ERROR: Config file not found: #{options[:config_path]}"
  puts "Please specify the correct path with --config"
  exit 1
end

begin
  postal_config = YAML.load_file(options[:config_path])
rescue => e
  puts "ERROR: Failed to load config file: #{e.message}"
  exit 1
end

# Extract database credentials
main_db = postal_config['main_db']
unless main_db
  puts "ERROR: main_db configuration not found in postal.yml"
  exit 1
end

db_config = {
  host: main_db['host'] || '127.0.0.1',
  port: main_db['port'] || 3306,
  username: main_db['username'] || 'root',
  password: main_db['password'] || '',
  database: main_db['database'] || 'postal'
}

puts "Connecting to database:"
puts "  Host: #{db_config[:host]}:#{db_config[:port]}"
puts "  Database: #{db_config[:database]}"
puts "  Username: #{db_config[:username]}"
puts

# Connect to database
begin
  client = Mysql2::Client.new(
    host: db_config[:host],
    port: db_config[:port],
    username: db_config[:username],
    password: db_config[:password],
    database: db_config[:database]
  )
  puts "✓ Connected to database"
  puts
rescue => e
  puts "ERROR: Failed to connect to database: #{e.message}"
  exit 1
end

# Calculate cutoff time
cutoff_time = Time.now - (options[:time_window_hours] * 3600)
cutoff_time_str = cutoff_time.strftime('%Y-%m-%d %H:%M:%S')

# Find dead webhooks
query = <<-SQL
  SELECT 
    w.id,
    w.server_id,
    w.url,
    w.enabled,
    s.name as server_name,
    COUNT(wr.id) as total_requests,
    SUM(CASE WHEN wr.status IN (#{ERROR_STATUS_CODES.join(',')}) THEN 1 ELSE 0 END) as failed_requests
  FROM webhooks w
  LEFT JOIN servers s ON s.id = w.server_id
  LEFT JOIN webhook_requests wr ON wr.webhook_id = w.id AND wr.created_at > '#{cutoff_time_str}'
  WHERE w.enabled = 1
  GROUP BY w.id
  HAVING failed_requests >= #{options[:failure_threshold]}
  ORDER BY failed_requests DESC
SQL

dead_webhooks = client.query(query).to_a

if dead_webhooks.empty?
  puts "✓ No dead webhooks found!"
  client.close
  exit 0
end

puts "Found #{dead_webhooks.count} dead webhook(s):\n\n"

dead_webhooks.each do |webhook|
  total_requests = webhook['total_requests']
  failed_requests = webhook['failed_requests']
  failure_rate = total_requests > 0 ? (failed_requests.to_f / total_requests * 100).round(1) : 0
  
  # Get last error message
  last_error_query = <<-SQL
    SELECT error, created_at
    FROM webhook_requests
    WHERE webhook_id = #{webhook['id']}
      AND status IN (#{ERROR_STATUS_CODES.join(',')})
    ORDER BY created_at DESC
    LIMIT 1
  SQL
  
  last_error_result = client.query(last_error_query).first
  last_error_msg = last_error_result ? last_error_result['error'] : 'No error message'
  last_error_time = last_error_result ? last_error_result['created_at'] : 'N/A'
  
  # Truncate error message if too long
  last_error_msg = last_error_msg[0..97] + '...' if last_error_msg && last_error_msg.length > 100
  
  puts "Webhook ID: #{webhook['id']}"
  puts "  Server: #{webhook['server_name'] || 'Unknown'} (ID: #{webhook['server_id']})"
  puts "  URL: #{webhook['url']}"
  puts "  Enabled: #{webhook['enabled'] == 1 ? 'true' : 'false'}"
  puts "  Total requests (#{options[:time_window_hours]}h): #{total_requests}"
  puts "  Failed requests: #{failed_requests}"
  puts "  Failure rate: #{failure_rate}%"
  puts "  Last error: #{last_error_msg}"
  puts "  Last attempt: #{last_error_time}"
  
  if options[:dry_run]
    puts "  → Would disable (DRY RUN)"
  else
    # Disable the webhook
    update_query = "UPDATE webhooks SET enabled = 0 WHERE id = #{webhook['id']}"
    client.query(update_query)
    puts "  → DISABLED"
  end
  
  puts
end

puts "=" * 80
if options[:dry_run]
  puts "DRY RUN complete. Run with --live to actually disable webhooks."
else
  puts "Disabled #{dead_webhooks.count} webhook(s)."
end
puts "=" * 80

client.close
