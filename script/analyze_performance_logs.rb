#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to analyze Postal performance logs and generate CSV for correlation with machine metrics
# Usage: ruby script/analyze_performance_logs.rb [hours_back] [hostname]
# Example: ruby script/analyze_performance_logs.rb 24 e1.edify.press

require 'json'
require 'csv'
require 'time'
require 'optparse'

class PerformanceLogAnalyzer
  attr_reader :hours_back, :hostname, :output_dir

  def initialize(hours_back: 24, hostname: nil)
    @hours_back = hours_back
    @hostname = hostname
    @output_dir = File.join(Dir.pwd, 'tmp', 'performance_analysis')
    @timing_data = []
    @errors = []
  end

  def run
    puts "=" * 80
    puts "POSTAL PERFORMANCE LOG ANALYZER"
    puts "=" * 80
    puts "Analyzing logs from: #{hostname || 'local'}"
    puts "Time range: Last #{hours_back} hours"
    puts "Output directory: #{output_dir}"
    puts "=" * 80
    puts

    ensure_output_directory
    fetch_logs
    parse_logs
    generate_csv
    print_analysis
  end

  private

  def ensure_output_directory
    FileUtils.mkdir_p(output_dir)
  end

  def fetch_logs
    puts "Fetching logs..."
    cutoff_time = Time.now - (hours_back * 3600)

    if hostname
      # Fetch from remote server via SSH
      fetch_remote_logs(cutoff_time)
    elsif ENV['DOCKER_CONTAINER']
      # Running inside Docker - read from container's own logs via log file or stdin
      fetch_docker_internal_logs(cutoff_time)
    else
      # Fetch from local Docker logs (development)
      fetch_local_logs(cutoff_time)
    end

    puts "Fetched #{@raw_logs.lines.count} log lines"
    puts
  end

  def fetch_remote_logs(cutoff_time)
    # Get logs from Docker container on remote host
    # Use 'since' flag to limit time range
    since_flag = "#{hours_back}h"
    command = "ssh #{hostname} 'docker logs --since #{since_flag} postal_worker_1 2>&1 | grep TIMING'"
    
    @raw_logs = `#{command}`
    
    if $?.exitstatus != 0 && $?.exitstatus != 1  # 1 is OK (grep no match)
      puts "ERROR: Failed to fetch logs from #{hostname}"
      exit 1
    end
  end

  def fetch_docker_internal_logs(cutoff_time)
    # Running inside the worker container - fetch logs from the host's Docker daemon
    # This requires the container to have access to the Docker socket
    container_name = ENV['CONTAINER_NAME'] || 'postal_worker_1'
    since_flag = "#{hours_back}h"
    command = "docker logs --since #{since_flag} #{container_name} 2>&1 | grep TIMING"
    
    @raw_logs = `#{command}`
    
    if $?.exitstatus != 0 && $?.exitstatus != 1
      puts "ERROR: Failed to fetch logs from container #{container_name}"
      puts "Make sure Docker socket is mounted or use --server flag for remote analysis"
      exit 1
    end
  end

  def fetch_local_logs(cutoff_time)
    # Assume running in Docker or can access logs locally
    since_flag = "#{hours_back}h"
    command = "docker logs --since #{since_flag} postal_worker_1 2>&1 | grep TIMING"
    
    @raw_logs = `#{command}`
    
    if $?.exitstatus != 0 && $?.exitstatus != 1
      puts "ERROR: Failed to fetch local logs"
      exit 1
    end
  end

  def parse_logs
    puts "Parsing logs..."
    
    @raw_logs.each_line do |line|
      next unless line.include?('[TIMING]')
      
      # Extract JSON from log line
      # Format: timestamp [LEVEL] [TIMING] {...json...}
      json_match = line.match(/\[TIMING\]\s+(.+)$/)
      next unless json_match
      
      begin
        data = JSON.parse(json_match[1])
        
        # Add timestamp from log line if available
        timestamp_match = line.match(/^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})/)
        if timestamp_match
          data['log_timestamp'] = timestamp_match[1]
        elsif data['start_time']
          data['log_timestamp'] = Time.parse(data['start_time']).strftime('%Y-%m-%d %H:%M:%S')
        else
          data['log_timestamp'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
        end
        
        @timing_data << data
      rescue JSON::ParserError => e
        @errors << "Failed to parse JSON: #{line}"
      end
    end
    
    puts "Parsed #{@timing_data.size} timing records"
    puts "Errors: #{@errors.size}" if @errors.any?
    puts
  end

  def generate_csv
    return if @timing_data.empty?

    csv_file = File.join(output_dir, "performance_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv")
    puts "Generating CSV: #{csv_file}"
    
    # Determine all possible keys
    all_keys = @timing_data.flat_map(&:keys).uniq.sort
    
    # Ensure key columns come first
    key_columns = ['log_timestamp', 'message_id', 'server_id', 'queue_id', 'domain', 'status']
    timing_columns = ['inspect_ms', 'dkim_ms', 'deliver_ms', 'total_ms']
    other_columns = all_keys - key_columns - timing_columns
    
    headers = key_columns + timing_columns + other_columns
    
    CSV.open(csv_file, 'w') do |csv|
      csv << headers
      
      @timing_data.each do |data|
        csv << headers.map { |h| data[h] }
      end
    end
    
    puts "CSV generated with #{@timing_data.size} rows"
    puts
  end

  def print_analysis
    return if @timing_data.empty?

    puts "=" * 80
    puts "PERFORMANCE ANALYSIS SUMMARY"
    puts "=" * 80
    puts

    # Overall statistics
    print_overall_stats
    
    # By-server breakdown
    print_server_breakdown
    
    # Status breakdown
    print_status_breakdown
    
    # Timing breakdowns
    print_timing_breakdown
    
    # Slowest messages
    print_slowest_messages
    
    # Server fairness (round-robin check)
    print_server_fairness
    
    # Domain analysis
    print_domain_analysis
  end

  def print_overall_stats
    puts "OVERALL STATISTICS"
    puts "-" * 80
    puts "Total messages processed: #{@timing_data.size}"
    puts "Time range: #{@timing_data.map { |d| d['log_timestamp'] }.compact.minmax.join(' to ')}"
    puts "Unique servers: #{@timing_data.map { |d| d['server_id'] }.compact.uniq.size}"
    puts "Unique domains: #{@timing_data.map { |d| d['domain'] }.compact.uniq.size}"
    puts
  end

  def print_server_breakdown
    puts "BY-SERVER MESSAGE COUNT"
    puts "-" * 80
    
    by_server = @timing_data.group_by { |d| d['server_id'] }
    by_server.sort_by { |sid, data| -data.size }.each do |server_id, data|
      avg_total = average(data.map { |d| d['total_ms'].to_f })
      puts "  Server #{server_id}: #{data.size} messages (avg: #{avg_total.round(2)}ms)"
    end
    puts
  end

  def print_status_breakdown
    puts "STATUS BREAKDOWN"
    puts "-" * 80
    
    by_status = @timing_data.group_by { |d| d['status'] }
    by_status.each do |status, data|
      pct = (data.size.to_f / @timing_data.size * 100).round(2)
      puts "  #{status || 'unknown'}: #{data.size} (#{pct}%)"
    end
    puts
  end

  def print_timing_breakdown
    puts "TIMING BREAKDOWN (milliseconds)"
    puts "-" * 80
    
    metrics = ['inspect_ms', 'dkim_ms', 'deliver_ms', 'total_ms']
    
    metrics.each do |metric|
      values = @timing_data.map { |d| d[metric].to_f }.compact.sort
      next if values.empty?
      
      puts "  #{metric.gsub('_', ' ').upcase}:"
      puts "    Min:    #{values.min.round(2)}ms"
      puts "    Max:    #{values.max.round(2)}ms"
      puts "    Avg:    #{average(values).round(2)}ms"
      puts "    Median: #{percentile(values, 50).round(2)}ms"
      puts "    P95:    #{percentile(values, 95).round(2)}ms"
      puts "    P99:    #{percentile(values, 99).round(2)}ms"
      puts
    end
  end

  def print_slowest_messages
    puts "SLOWEST MESSAGES (by total_ms)"
    puts "-" * 80
    
    slowest = @timing_data.sort_by { |d| -(d['total_ms'].to_f) }.take(10)
    
    slowest.each_with_index do |data, idx|
      puts "  #{idx + 1}. Message #{data['message_id']} (Server #{data['server_id']}) - #{data['domain']}"
      puts "     Total: #{data['total_ms']}ms | " \
           "Inspect: #{data['inspect_ms']}ms | " \
           "DKIM: #{data['dkim_ms']}ms | " \
           "Deliver: #{data['deliver_ms']}ms"
      puts "     Size: #{data['message_size']} bytes | Status: #{data['status']}"
      puts
    end
  end

  def print_server_fairness
    puts "SERVER FAIRNESS (Round-Robin Analysis)"
    puts "-" * 80
    
    # Group by timestamp buckets (1 minute intervals)
    by_minute = @timing_data.group_by do |d|
      Time.parse(d['log_timestamp']).strftime('%Y-%m-%d %H:%M')
    end
    
    # Calculate how many unique servers processed per minute
    servers_per_minute = by_minute.map do |minute, data|
      data.map { |d| d['server_id'] }.compact.uniq.size
    end
    
    if servers_per_minute.any?
      puts "  Average unique servers per minute: #{average(servers_per_minute).round(2)}"
      puts "  Min servers per minute: #{servers_per_minute.min}"
      puts "  Max servers per minute: #{servers_per_minute.max}"
      puts
      
      # Check for any long gaps where a single server dominated
      consecutive_same_server = 0
      max_consecutive = 0
      prev_server = nil
      
      sorted_data = @timing_data.sort_by { |d| d['log_timestamp'] }
      sorted_data.each do |data|
        if data['server_id'] == prev_server
          consecutive_same_server += 1
          max_consecutive = [max_consecutive, consecutive_same_server].max
        else
          consecutive_same_server = 1
          prev_server = data['server_id']
        end
      end
      
      puts "  Max consecutive messages from same server: #{max_consecutive}"
      if max_consecutive > 10
        puts "  ⚠️  WARNING: High consecutive count suggests round-robin may not be working optimally"
      else
        puts "  ✓ Round-robin appears to be working well"
      end
    end
    puts
  end

  def print_domain_analysis
    puts "TOP DOMAINS BY MESSAGE COUNT"
    puts "-" * 80
    
    by_domain = @timing_data.group_by { |d| d['domain'] }
    top_domains = by_domain.sort_by { |domain, data| -data.size }.take(10)
    
    top_domains.each do |domain, data|
      avg_deliver = average(data.map { |d| d['deliver_ms'].to_f })
      puts "  #{domain}: #{data.size} messages (avg delivery: #{avg_deliver.round(2)}ms)"
    end
    puts
  end

  def average(values)
    return 0 if values.empty?
    values.sum.to_f / values.size
  end

  def percentile(sorted_values, percentile)
    return 0 if sorted_values.empty?
    index = (percentile / 100.0 * sorted_values.size).ceil - 1
    sorted_values[[index, 0].max]
  end
end

# Parse command line arguments
options = { hours_back: 24, hostname: nil }

OptionParser.new do |opts|
  opts.banner = "Usage: analyze_performance_logs.rb [options]"
  
  opts.on("-h", "--hours HOURS", Integer, "Hours of logs to analyze (default: 24)") do |h|
    options[:hours_back] = h
  end
  
  opts.on("-s", "--server HOSTNAME", String, "Remote server hostname (e.g., e1.edify.press)") do |s|
    options[:hostname] = s
  end
  
  opts.on("--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

# Run analyzer
analyzer = PerformanceLogAnalyzer.new(
  hours_back: options[:hours_back],
  hostname: options[:hostname]
)

analyzer.run

puts "=" * 80
puts "Analysis complete!"
puts "CSV file available in: #{analyzer.output_dir}"
puts "=" * 80
