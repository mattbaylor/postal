#!/usr/bin/env ruby
# frozen_string_literal: true

# Integration test for ampersand URL handling
# This test sends actual emails through Postal and validates the tracking URLs

require 'net/smtp'
require 'net/http'
require 'mail'

puts "=" * 80
puts "Postal Ampersand Fix - Integration Test"
puts "=" * 80
puts

# Configuration - UPDATE THESE FOR YOUR ENVIRONMENT
POSTAL_SMTP_HOST = ENV['POSTAL_SMTP_HOST'] || 'localhost'
POSTAL_SMTP_PORT = ENV['POSTAL_SMTP_PORT'] || '25'
POSTAL_API_KEY = ENV['POSTAL_API_KEY'] || ''
TEST_FROM = ENV['TEST_FROM'] || 'test@yourdomain.com'
TEST_TO = ENV['TEST_TO'] || 'recipient@example.com'

# Test URLs with various ampersand scenarios
test_urls = [
  "https://example.com/page?foo=bar&baz=qux&id=123",
  "https://example.com/tracking?source=email&campaign=test&user_id=456",
  "https://shop.example.com/product?id=789&variant=blue&size=large"
]

puts "Configuration:"
puts "  SMTP Host: #{POSTAL_SMTP_HOST}:#{POSTAL_SMTP_PORT}"
puts "  From: #{TEST_FROM}"
puts "  To: #{TEST_TO}"
puts

# Generate test email HTML with links
def generate_test_html(test_urls)
  html = <<~HTML
    <!DOCTYPE html>
    <html>
    <head>
      <title>Ampersand Test Email</title>
    </head>
    <body>
      <h1>Ampersand URL Test</h1>
      <p>This email tests various URLs with query parameters:</p>
      <ul>
  HTML
  
  test_urls.each_with_index do |url, index|
    # In HTML, ampersands should be &amp;
    html_url = url.gsub('&', '&amp;')
    html += "    <li><a href=\"#{html_url}\">Test Link #{index + 1}</a></li>\n"
  end
  
  html += <<~HTML
      </ul>
      <p>Click the links above to test tracking redirect behavior.</p>
    </body>
    </html>
  HTML
  
  html
end

# Generate test email plain text with links
def generate_test_text(test_urls)
  text = "Ampersand URL Test\n\n"
  text += "This email tests various URLs with query parameters:\n\n"
  
  test_urls.each_with_index do |url, index|
    text += "#{index + 1}. #{url}\n"
  end
  
  text += "\nClick the links above to test tracking redirect behavior.\n"
  text
end

puts "Generating test email..."
mail = Mail.new do
  from     TEST_FROM
  to       TEST_TO
  subject  "Ampersand Fix Test - #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
  
  text_part do
    body generate_test_text(test_urls)
  end
  
  html_part do
    content_type 'text/html; charset=UTF-8'
    body generate_test_html(test_urls)
  end
end

puts "Test email generated with #{test_urls.length} test URLs"
puts

# Display what we're testing
puts "Test URLs (as they appear in email HTML with &amp;):"
test_urls.each_with_index do |url, index|
  puts "  #{index + 1}. #{url.gsub('&', '&amp;')}"
end
puts

puts "Expected behavior:"
puts "  1. Postal should extract URLs from email HTML"
puts "  2. Convert &amp; to & when storing in database"
puts "  3. When redirecting, use plain & in Location header (not &amp;)"
puts "  4. IIS and other strict servers should accept the redirect"
puts

puts "To complete this test:"
puts "  1. Run this script to generate and send a test email"
puts "  2. Check that tracking URLs are created in Postal"
puts "  3. Click a tracking link and verify redirect works"
puts "  4. Check HTTP headers to confirm Location uses & not &amp;"
puts

puts "Send this test email? (y/n)"
response = gets.chomp.downcase

if response == 'y'
  begin
    puts "Connecting to SMTP server..."
    Net::SMTP.start(POSTAL_SMTP_HOST, POSTAL_SMTP_PORT) do |smtp|
      smtp.send_message(mail.to_s, TEST_FROM, TEST_TO)
    end
    puts "✓ Test email sent successfully!"
    puts
    puts "Next steps:"
    puts "  1. Check recipient inbox for email"
    puts "  2. Inspect tracking URLs in email source"
    puts "  3. Click links and verify redirects work"
    puts "  4. Use browser dev tools to check Location header format"
  rescue => e
    puts "✗ Failed to send email: #{e.message}"
    puts e.backtrace.first(5).join("\n")
    exit 1
  end
else
  puts "Test cancelled."
  
  # Save email to file for manual inspection
  filename = "/tmp/postal_ampersand_test_#{Time.now.to_i}.eml"
  File.write(filename, mail.to_s)
  puts "Test email saved to: #{filename}"
  puts "You can inspect the email file or send it manually."
end

puts
puts "=" * 80
puts "Manual Validation Steps:"
puts "=" * 80
puts
puts "1. Send test email through Postal with click tracking enabled"
puts "2. View the sent email's raw source"
puts "3. Find tracking URLs - they should look like:"
puts "   https://track.yourdomain.com/server-token/link-token"
puts
puts "4. Click a tracking link"
puts "5. In browser dev tools (Network tab), check the redirect:"
puts "   - Should be HTTP 307 Temporary Redirect"
puts "   - Location header should have plain & between params"
puts "   - Location header should NOT contain &amp;"
puts
puts "6. Verify the final destination URL loads correctly"
puts
puts "Example good Location header:"
puts "  Location: https://example.com/page?foo=bar&baz=qux&id=123"
puts
puts "Example bad Location header (would fail on IIS):"
puts "  Location: https://example.com/page?foo=bar&amp;baz=qux&amp;id=123"
puts "=" * 80
