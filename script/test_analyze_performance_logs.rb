#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script to verify analyze_performance_logs.rb works with sample data

require_relative 'analyze_performance_logs'

# Create a test analyzer that reads from a file instead of Docker logs
class TestPerformanceLogAnalyzer < PerformanceLogAnalyzer
  def initialize(test_file)
    super(hours_back: 24, hostname: nil)
    @test_file = test_file
  end

  private

  def fetch_logs
    puts "Fetching test logs from: #{@test_file}"
    @raw_logs = File.read(@test_file)
    puts "Fetched #{@raw_logs.lines.count} log lines"
    puts
  end
end

# Run test
if ARGV[0].nil?
  puts "Usage: ruby test_analyze_performance_logs.rb <test_log_file>"
  puts "Example: ruby script/test_analyze_performance_logs.rb tmp/test_timing_logs.txt"
  exit 1
end

test_file = ARGV[0]
unless File.exist?(test_file)
  puts "ERROR: Test file not found: #{test_file}"
  exit 1
end

analyzer = TestPerformanceLogAnalyzer.new(test_file)
analyzer.run

puts "=" * 80
puts "Test complete! Check output in: #{analyzer.output_dir}"
puts "=" * 80
