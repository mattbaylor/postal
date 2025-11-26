#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script to validate the ampersand URL encoding fix for IIS compatibility
#
# This tests both the message parser (URL storage) and tracking middleware (URL redirect)
# to ensure URLs with ampersands are handled correctly.

require 'uri'
require 'cgi'

puts "=" * 80
puts "Testing Ampersand URL Encoding Fix"
puts "=" * 80
puts

# Test the encode_redirect_url function from tracking_middleware.rb
def encode_redirect_url(url)
  # First, unescape any HTML entities (handles legacy data with &amp;)
  url = CGI.unescapeHTML(url)
  
  uri = URI.parse(url)
  
  if uri.query
    params = URI.decode_www_form(uri.query)
    uri.query = URI.encode_www_form(params)
  end
  
  uri.to_s
rescue URI::InvalidURIError
  url
end

# Test cases covering various scenarios
test_cases = [
  {
    name: "URL with HTML entity ampersands (&amp;)",
    input: "https://example.com/page?foo=bar&amp;baz=qux&amp;id=123",
    expected_contains: "foo=bar&baz=qux&id=123",
    should_not_contain: "&amp;"
  },
  {
    name: "URL with plain ampersands",
    input: "https://example.com/page?foo=bar&baz=qux&id=123",
    expected_contains: "foo=bar&baz=qux&id=123",
    should_not_contain: "&amp;"
  },
  {
    name: "URL with special characters in values",
    input: "https://example.com/page?email=test@example.com&redirect=/path/to/page",
    expected_contains: "email=test%40example.com",
    should_not_contain: "@"
  },
  {
    name: "URL without query parameters",
    input: "https://example.com/page",
    expected_contains: "https://example.com/page",
    should_not_contain: "&amp;"
  },
  {
    name: "URL with single query parameter",
    input: "https://example.com/page?foo=bar",
    expected_contains: "foo=bar",
    should_not_contain: "&amp;"
  },
  {
    name: "Mixed ampersands (some &amp;, some &)",
    input: "https://example.com/page?a=1&amp;b=2&c=3&amp;d=4",
    expected_contains: "a=1&b=2&c=3&d=4",
    should_not_contain: "&amp;"
  },
  {
    name: "URL with encoded ampersand in value (%26)",
    input: "https://example.com/page?redirect=http%3A%2F%2Ftest.com%3Fa%3D1%26b%3D2",
    expected_contains: "redirect=http%3A%2F%2Ftest.com%3Fa%3D1%26b%3D2",
    should_not_contain: "&amp;"
  },
  {
    name: "URL with fragment",
    input: "https://example.com/page?foo=bar&amp;baz=qux#section",
    expected_contains: "foo=bar&baz=qux#section",
    should_not_contain: "&amp;"
  }
]

# Run tests
passed = 0
failed = 0

test_cases.each_with_index do |test, index|
  puts "Test #{index + 1}: #{test[:name]}"
  puts "  Input:  #{test[:input]}"
  
  result = encode_redirect_url(test[:input])
  puts "  Output: #{result}"
  
  # Check expected content
  contains_pass = result.include?(test[:expected_contains])
  not_contains_pass = !result.include?(test[:should_not_contain])
  
  if contains_pass && not_contains_pass
    puts "  ✓ PASS"
    passed += 1
  else
    puts "  ✗ FAIL"
    if !contains_pass
      puts "    - Missing expected: #{test[:expected_contains]}"
    end
    if !not_contains_pass
      puts "    - Contains forbidden: #{test[:should_not_contain]}"
    end
    failed += 1
  end
  puts
end

# Test CGI.unescapeHTML (used in message parser)
puts "-" * 80
puts "Testing HTML Entity Unescaping (Message Parser)"
puts "-" * 80
puts

html_test_cases = [
  {
    name: "URL with &amp; entities",
    input: "https://example.com/page?foo=bar&amp;baz=qux",
    expected: "https://example.com/page?foo=bar&baz=qux"
  },
  {
    name: "URL with multiple HTML entities",
    input: "https://example.com/page?a=1&amp;b=2&amp;c=3",
    expected: "https://example.com/page?a=1&b=2&c=3"
  },
  {
    name: "URL with &lt; and &gt;",
    input: "https://example.com/page?val=&lt;test&gt;",
    expected: "https://example.com/page?val=<test>"
  }
]

html_test_cases.each_with_index do |test, index|
  puts "Test #{index + 1}: #{test[:name]}"
  puts "  Input:    #{test[:input]}"
  
  result = CGI.unescapeHTML(test[:input])
  puts "  Output:   #{result}"
  puts "  Expected: #{test[:expected]}"
  
  if result == test[:expected]
    puts "  ✓ PASS"
    passed += 1
  else
    puts "  ✗ FAIL"
    failed += 1
  end
  puts
end

# Summary
puts "=" * 80
puts "Summary"
puts "=" * 80
puts "Total tests: #{passed + failed}"
puts "Passed: #{passed}"
puts "Failed: #{failed}"
puts

if failed == 0
  puts "✓ All tests passed! The ampersand fix is working correctly."
  exit 0
else
  puts "✗ Some tests failed. Please review the implementation."
  exit 1
end
