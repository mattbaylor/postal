#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to identify and disable webhooks that are consistently failing
# Run inside Docker container: docker compose exec worker ruby script/disable_dead_webhooks.rb

require_relative "../config/environment"

# Configuration
DRY_RUN = ENV["DRY_RUN"] != "false" # Default to dry run unless explicitly disabled
FAILURE_THRESHOLD = ENV["FAILURE_THRESHOLD"]&.to_i || 10 # Min failed requests to consider
TIME_WINDOW_HOURS = ENV["TIME_WINDOW_HOURS"]&.to_i || 24 # Look back window
ERROR_STATUS_CODES = [-2, -1] # -2 = connection failed, -1 = other errors

puts "=" * 80
puts "Dead Webhook Detector"
puts "=" * 80
puts "Mode: #{DRY_RUN ? 'DRY RUN (no changes)' : 'LIVE (will disable webhooks)'}"
puts "Threshold: #{FAILURE_THRESHOLD} failed requests in last #{TIME_WINDOW_HOURS} hours"
puts "Error codes: #{ERROR_STATUS_CODES.join(', ')}"
puts "=" * 80
puts

# Find webhooks with recent failures
cutoff_time = TIME_WINDOW_HOURS.hours.ago

dead_webhooks = Webhook.all.select do |webhook|
  next false unless webhook.enabled

  # Count recent failed requests
  failed_count = WebhookRequest.where(webhook_id: webhook.id)
                               .where("created_at > ?", cutoff_time)
                               .where(status: ERROR_STATUS_CODES)
                               .count

  failed_count >= FAILURE_THRESHOLD
end

if dead_webhooks.empty?
  puts "✓ No dead webhooks found!"
  exit 0
end

puts "Found #{dead_webhooks.count} dead webhook(s):\n\n"

dead_webhooks.each do |webhook|
  # Get failure stats
  total_requests = WebhookRequest.where(webhook_id: webhook.id)
                                 .where("created_at > ?", cutoff_time)
                                 .count

  failed_requests = WebhookRequest.where(webhook_id: webhook.id)
                                  .where("created_at > ?", cutoff_time)
                                  .where(status: ERROR_STATUS_CODES)
                                  .count

  failure_rate = total_requests > 0 ? (failed_requests.to_f / total_requests * 100).round(1) : 0

  # Get the server this webhook belongs to
  server = Server.find_by(id: webhook.server_id)
  server_name = server ? server.name : "Unknown"

  # Get last error message
  last_error = WebhookRequest.where(webhook_id: webhook.id)
                             .where(status: ERROR_STATUS_CODES)
                             .order(created_at: :desc)
                             .first
  last_error_msg = last_error&.error || "No error message"

  puts "Webhook ID: #{webhook.id}"
  puts "  Server: #{server_name} (ID: #{webhook.server_id})"
  puts "  URL: #{webhook.url}"
  puts "  Enabled: #{webhook.enabled}"
  puts "  Total requests (#{TIME_WINDOW_HOURS}h): #{total_requests}"
  puts "  Failed requests: #{failed_requests}"
  puts "  Failure rate: #{failure_rate}%"
  puts "  Last error: #{last_error_msg.truncate(100)}"
  puts "  Last attempt: #{last_error&.created_at || 'N/A'}"

  if DRY_RUN
    puts "  → Would disable (DRY RUN)"
  else
    webhook.update!(enabled: false)
    puts "  → DISABLED"
  end

  puts
end

puts "=" * 80
if DRY_RUN
  puts "DRY RUN complete. Run with DRY_RUN=false to actually disable webhooks."
else
  puts "Disabled #{dead_webhooks.count} webhook(s)."
end
puts "=" * 80
