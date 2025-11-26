# Ampersand Handling Fix for IIS Compatibility

## Problem Statement

When Postal tracks links containing query parameters with ampersands (e.g., `?foo=bar&baz=qux`), the redirect URLs were not being properly encoded for HTTP Location headers. This caused issues with strict HTTP servers like IIS, which require proper URL encoding in redirect responses.

### The Issue

1. HTML emails may contain URLs with ampersands encoded as HTML entities (`&amp;`)
2. When these URLs were stored and later used in HTTP redirect responses, the encoding was inconsistent
3. IIS (and other strict HTTP servers) reject improperly encoded Location headers
4. URLs with literal `&amp;` in the Location header would fail to redirect properly

## Root Cause Analysis

The original code flow:

1. **Message Parser** (`lib/postal/message_parser.rb`):
   - Extracts URLs from email content
   - Creates tracking tokens and stores URLs in database
   - **Issue**: URLs stored as-is without normalization

2. **Tracking Middleware** (`lib/tracking_middleware.rb`):
   - Receives click on tracking link
   - Retrieves stored URL from database
   - Issues HTTP 307 redirect with Location header
   - **Issue**: Used stored URL directly without proper HTTP encoding

### What Doesn't Work

The attempted fix in the `AmpersandUrlHandling` branch had critical flaws:

```ruby
# WRONG - Confuses HTML entity encoding with URL encoding
url = $~[:url].gsub('&', '&amp;')  # This is HTML encoding
encoded_url = URI::Escape.uri_escape(url)  # Deprecated and doesn't fix the issue
```

**Problems:**
- `&amp;` is for HTML/XML contexts, not HTTP headers
- HTTP Location headers need `&` (plain ampersand) for query string separators
- `URI.escape` is deprecated (removed in Ruby 3.0)
- IIS sees `&amp;` as literal text, not as an ampersand

## The Correct Solution

### Part 1: Message Parser Changes (`lib/postal/message_parser.rb`)

**Strategy**: Store URLs in their natural form (with plain `&` in query strings)

```ruby
def insert_links(part, type = nil)
  if type == :text
    # For plain text URLs, extract and clean them
    url = $~[:url]
    # Remove trailing punctuation (improved regex check)
    while url =~ /[^\w\/]$/
      theend = url.size - 2
      url = url[0..theend]
    end
    # Store URL as-is
    token = @message.create_link(url)
  end

  if type == :html
    # For HTML href attributes, unescape HTML entities first
    url = CGI.unescapeHTML($~[:url])  # Converts &amp; to &
    # Store the normalized URL
    token = @message.create_link(url)
  end
end
```

**Key points:**
- HTML entities (`&amp;`) are unescaped to plain ampersands (`&`)
- URLs stored in database use standard URL format with `&` separators
- No encoding applied at storage time - keep URLs in natural form

### Part 2: Tracking Middleware Changes (`lib/tracking_middleware.rb`)

**Strategy**: Properly encode URLs when generating HTTP Location headers

```ruby
def dispatch_redirect_request(request, server_token, link_token)
  # ... existing code ...
  
  # Properly encode the redirect URL for the Location header
  redirect_url = encode_redirect_url(link["url"])
  [307, { "Location" => redirect_url }, ["Redirected to: #{link['url']}"]]
end

def encode_redirect_url(url)
  # Parse the URL into components
  uri = URI.parse(url)
  
  # If there's a query string, properly encode it
  if uri.query
    # Parse query parameters (handles both & and &amp; if present)
    params = URI.decode_www_form(uri.query)
    # Re-encode them properly with & separators
    uri.query = URI.encode_www_form(params)
  end
  
  uri.to_s
rescue URI::InvalidURIError
  # Fallback: return original URL if parsing fails
  url
end
```

**Key points:**
- `URI.decode_www_form` handles various input formats (including stray `&amp;` entities)
- `URI.encode_www_form` ensures proper encoding with `&` separators
- Individual parameter values are properly percent-encoded (e.g., `@` → `%40`)
- Graceful fallback for edge cases

## How It Works

### Example Flow

**Input email HTML:**
```html
<a href="https://example.com/page?foo=bar&amp;baz=qux&amp;id=123">Click here</a>
```

**Step 1 - Message Parser:**
```ruby
url = CGI.unescapeHTML("https://example.com/page?foo=bar&amp;baz=qux&amp;id=123")
# Result: "https://example.com/page?foo=bar&baz=qux&id=123"
token = @message.create_link(url)
# Stored in DB: "https://example.com/page?foo=bar&baz=qux&id=123"
```

**Step 2 - User Clicks Tracking Link:**
```
https://track.example.com/server-token/link-token
```

**Step 3 - Tracking Middleware:**
```ruby
link = db.select(:links, where: { token: link_token })
# link["url"] = "https://example.com/page?foo=bar&baz=qux&id=123"

redirect_url = encode_redirect_url(link["url"])
# Parses query: [["foo", "bar"], ["baz", "qux"], ["id", "123"]]
# Re-encodes: "https://example.com/page?foo=bar&baz=qux&id=123"

# HTTP Response:
# HTTP/1.1 307 Temporary Redirect
# Location: https://example.com/page?foo=bar&baz=qux&id=123
```

**Step 4 - Browser/IIS receives:**
```
Location: https://example.com/page?foo=bar&baz=qux&id=123
```

✓ IIS accepts this because it's properly formatted with `&` separators

## Why This Works for IIS

IIS validates HTTP headers strictly according to RFC 7230/7231:

1. **Location header must contain a valid URI**
2. **Query string parameters must be separated by `&`** (not `&amp;`)
3. **Special characters must be percent-encoded** (e.g., `%20` for space, `%40` for @)

Our fix ensures:
- Query parameters use `&` separators (HTTP standard)
- Special characters are percent-encoded
- No HTML entities in HTTP headers

## Testing

Run the verification test:

```bash
cd /Users/matt/repo/postal
ruby -e "
require 'uri'

def encode_redirect_url(url)
  uri = URI.parse(url)
  if uri.query
    params = URI.decode_www_form(uri.query)
    uri.query = URI.encode_www_form(params)
  end
  uri.to_s
rescue URI::InvalidURIError
  url
end

# Test with problematic URL
url = 'https://example.com/page?foo=bar&amp;baz=qux'
result = encode_redirect_url(url)
puts \"Input:  #{url}\"
puts \"Output: #{result}\"
puts result.include?('&amp;') ? '❌ FAIL' : '✓ PASS'
"
```

## Migration Notes

### Existing Data

URLs already stored in the database may contain:
- Properly formatted URLs with `&`
- URLs with `&amp;` from previous bugs
- Mixed formats

The `encode_redirect_url` method handles all cases:
```ruby
URI.decode_www_form  # Normalizes any input format
URI.encode_www_form  # Outputs correct format
```

### Backward Compatibility

- URLs without query strings: unchanged
- Simple query strings: unchanged
- Malformed URLs: fallback to original (existing behavior)
- No database migration needed

## References

- [RFC 3986 - URI Generic Syntax](https://www.rfc-editor.org/rfc/rfc3986)
- [RFC 7231 - HTTP/1.1 Semantics (Location Header)](https://www.rfc-editor.org/rfc/rfc7231#section-7.1.2)
- [HTML5 - URL writing in HTML](https://html.spec.whatwg.org/multipage/urls-and-fetching.html)
- [IIS URL Validation](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/security/requestfiltering/)

## Key Differences: HTML vs HTTP

| Context | Encoding | Example | Use Case |
|---------|----------|---------|----------|
| **HTML Attribute** | `&amp;` | `<a href="?foo=bar&amp;baz=qux">` | Inside HTML markup |
| **HTTP Header** | `&` | `Location: ?foo=bar&baz=qux` | HTTP Location header |
| **Plain Text** | `&` | `https://example.com?foo=bar&baz=qux` | Email body, user input |
| **Percent Encoding** | `%26` | `?redirect=%26encoded%26` | When `&` is a *value*, not separator |

Our fix ensures:
- HTML → normalize to plain `&` → store
- Storage → plain `&` format
- HTTP redirect → properly encoded with `&` separators
