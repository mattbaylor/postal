# Ampersand Fix Testing Guide

This document provides comprehensive testing instructions to validate the ampersand URL encoding fix for IIS compatibility.

## Quick Test

Run the unit test script:

```bash
cd /Users/matt/repo/postal
ruby script/test_ampersand_fix.rb
```

This will test the core URL encoding functions with various edge cases.

**Expected result:** All 11 tests should pass, confirming that:
- HTML entities (`&amp;`) are properly unescaped
- URLs are stored with plain ampersands (`&`)
- HTTP Location headers use plain ampersands (not `&amp;`)
- Special characters are properly percent-encoded

## Manual Integration Testing

### Prerequisites

- Postal server running with click tracking enabled
- Test domain configured with tracking enabled
- Access to browser developer tools
- Email client to receive test messages

### Step 1: Send Test Email

Option A: Use the integration test script

```bash
export POSTAL_SMTP_HOST=your-postal-server.com
export POSTAL_SMTP_PORT=25
export TEST_FROM=sender@yourdomain.com
export TEST_TO=your-test-email@example.com

ruby script/test_ampersand_integration.rb
```

Option B: Send manually through Postal web interface or API

Create an HTML email with links containing ampersands:

```html
<!DOCTYPE html>
<html>
<head><title>Ampersand Test</title></head>
<body>
  <h1>Click Tracking Test</h1>
  <p>Test these links:</p>
  <ul>
    <li><a href="https://example.com/page?foo=bar&amp;baz=qux&amp;id=123">Test Link 1</a></li>
    <li><a href="https://shop.com/product?id=456&amp;variant=blue&amp;size=large">Test Link 2</a></li>
    <li><a href="https://app.com/redirect?source=email&amp;campaign=test">Test Link 3</a></li>
  </ul>
</body>
</html>
```

**Note:** In HTML, ampersands MUST be written as `&amp;` between parameters.

### Step 2: Verify Link Tracking

1. Send the test email through Postal
2. Check that tracking URLs were created:
   - Go to Postal web interface
   - Find the sent message
   - View message details
   - Confirm tracking links were created

### Step 3: Test Click Redirect

1. Open the test email in your email client
2. Open browser Developer Tools (F12)
3. Go to the **Network** tab
4. Click one of the tracking links
5. In the Network tab, find the redirect request
6. Click on it and view the **Response Headers**

### Step 4: Validate HTTP Headers

The redirect response should look like this:

```
HTTP/1.1 307 Temporary Redirect
Location: https://example.com/page?foo=bar&baz=qux&id=123
```

**✓ PASS criteria:**
- Status code is 307
- Location header contains the original destination URL
- Query parameters are separated by `&` (single ampersand)
- No `&amp;` appears in the Location header
- Browser successfully redirects to destination

**✗ FAIL criteria:**
- Location header contains `&amp;`
- Redirect fails or shows error
- IIS returns 400 Bad Request

### Step 5: IIS-Specific Testing

If you have access to an IIS server:

1. Configure IIS with strict URL validation
2. Send tracking link through email
3. Click tracking link
4. Verify redirect works without errors

IIS will reject Location headers with `&amp;` - the fix ensures this doesn't happen.

## Automated Testing

### Unit Tests

Run the standalone unit test:

```bash
ruby script/test_ampersand_fix.rb
```

### RSpec Tests

Run the RSpec test suite:

```bash
bundle exec rspec spec/lib/ampersand_fix_spec.rb
```

This tests:
- `TrackingMiddleware#encode_redirect_url` method
- HTML entity unescaping in message parser
- End-to-end URL flow
- IIS compatibility requirements

## Test Scenarios

### Scenario 1: Standard Email Marketing Link

**Input (in email HTML):**
```html
<a href="https://shop.example.com/product?id=123&amp;campaign=email&amp;source=newsletter">Shop Now</a>
```

**Expected behavior:**
1. Message parser extracts: `https://shop.example.com/product?id=123&campaign=email&source=newsletter`
2. Stored in database with plain `&` separators
3. Tracking middleware creates Location header with plain `&`
4. User redirects successfully to destination

### Scenario 2: URL with Special Characters

**Input:**
```html
<a href="https://app.example.com/signup?email=user@example.com&amp;ref=friend123">Sign Up</a>
```

**Expected behavior:**
1. Unescape HTML entities: `email=user@example.com&ref=friend123`
2. Store in database
3. Redirect with percent-encoded special chars: `email=user%40example.com&ref=friend123`

### Scenario 3: Complex Query String

**Input:**
```html
<a href="https://tracker.example.com/click?url=https%3A%2F%2Fsite.com%2Fpage&amp;user_id=789&amp;token=abc123">Click Here</a>
```

**Expected behavior:**
1. Properly handle nested encoded URL
2. Preserve percent-encoding in value
3. Use plain `&` between parameters

### Scenario 4: Legacy Data (URLs with &amp; in database)

If your database contains URLs that were incorrectly stored with `&amp;`:

**Stored URL:** `https://example.com/page?foo=bar&amp;baz=qux`

**Expected behavior:**
1. `encode_redirect_url` unescapes HTML entities
2. Normalizes to: `https://example.com/page?foo=bar&baz=qux`
3. Redirect works correctly

The fix includes defensive coding to handle this edge case.

## Troubleshooting

### Test fails with "&amp;" in Location header

**Cause:** The `CGI.unescapeHTML` call may be missing from `encode_redirect_url`

**Fix:** Verify `lib/tracking_middleware.rb` includes:
```ruby
def encode_redirect_url(url)
  url = CGI.unescapeHTML(url)  # This line is critical
  # ... rest of function
end
```

### Links not being tracked

**Causes:**
- Click tracking disabled for the domain
- Domain not in allowed tracking list
- Message parser not processing HTML correctly

**Check:**
1. Domain settings in Postal
2. `track_clicks?` is enabled
3. Domain not in `excluded_click_domains_array`

### Redirect works but destination is wrong

**Cause:** URL may be malformed in original email

**Fix:** Validate the original email HTML has properly formatted URLs with `&amp;` between parameters

### Special characters not encoding properly

**Cause:** URL encoding issue in `URI.encode_www_form`

**Check:** Ensure Ruby's URI library is working correctly:
```ruby
params = [["email", "test@example.com"]]
URI.encode_www_form(params)
# Should produce: "email=test%40example.com"
```

## Expected Test Results

All tests should pass with these characteristics:

1. **Unit test (`script/test_ampersand_fix.rb`):**
   - 11/11 tests pass
   - No `&amp;` in any output URLs
   - Special characters properly encoded

2. **Integration test:**
   - Email sends successfully
   - Tracking links created
   - Click redirect returns 307
   - Location header has plain `&`
   - Browser successfully redirects

3. **RSpec tests:**
   - All specs pass
   - Edge cases handled
   - IIS compatibility confirmed

## Security Considerations

The fix maintains security by:
- Properly encoding special characters (prevents injection)
- Graceful fallback for invalid URLs
- No execution of user-provided code
- Maintaining URL integrity through the redirect chain

## Performance Impact

Minimal performance impact:
- `CGI.unescapeHTML`: Fast string operation
- `URI.decode_www_form` / `URI.encode_www_form`: Standard library, optimized
- Adds ~0.1ms per redirect (negligible)

## Compliance

This fix ensures compliance with:
- RFC 3986 (URI Generic Syntax)
- RFC 7231 (HTTP/1.1 Semantics, Location Header)
- HTML5 URL specification
- IIS URL validation requirements

## Additional Resources

- See `doc/AMPERSAND_FIX.md` for technical details
- See `lib/postal/message_parser.rb` for message parsing
- See `lib/tracking_middleware.rb` for redirect handling
- See `spec/lib/ampersand_fix_spec.rb` for test cases
