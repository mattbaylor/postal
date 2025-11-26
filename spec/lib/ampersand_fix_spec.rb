# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ampersand URL Encoding Fix" do
  describe "TrackingMiddleware#encode_redirect_url" do
    let(:middleware) { TrackingMiddleware.new }

    context "when URL contains HTML entity ampersands (&amp;)" do
      it "converts &amp; to plain & in query string" do
        url = "https://example.com/page?foo=bar&amp;baz=qux&amp;id=123"
        result = middleware.send(:encode_redirect_url, url)
        
        expect(result).to include("foo=bar&baz=qux&id=123")
        expect(result).not_to include("&amp;")
      end
    end

    context "when URL contains plain ampersands" do
      it "keeps ampersands as-is" do
        url = "https://example.com/page?foo=bar&baz=qux&id=123"
        result = middleware.send(:encode_redirect_url, url)
        
        expect(result).to eq(url)
        expect(result).not_to include("&amp;")
      end
    end

    context "when URL has mixed ampersand formats" do
      it "normalizes all to plain ampersands" do
        url = "https://example.com/page?a=1&amp;b=2&c=3&amp;d=4"
        result = middleware.send(:encode_redirect_url, url)
        
        expect(result).to include("a=1&b=2&c=3&d=4")
        expect(result).not_to include("&amp;")
      end
    end

    context "when URL has special characters in parameter values" do
      it "percent-encodes special characters" do
        url = "https://example.com/page?email=test@example.com&redirect=/path"
        result = middleware.send(:encode_redirect_url, url)
        
        expect(result).to include("email=test%40example.com")
        expect(result).not_to include("email=test@example.com")
      end
    end

    context "when URL has no query parameters" do
      it "returns URL unchanged" do
        url = "https://example.com/page"
        result = middleware.send(:encode_redirect_url, url)
        
        expect(result).to eq(url)
      end
    end

    context "when URL has a single query parameter" do
      it "processes correctly" do
        url = "https://example.com/page?foo=bar"
        result = middleware.send(:encode_redirect_url, url)
        
        expect(result).to eq(url)
        expect(result).not_to include("&amp;")
      end
    end

    context "when URL has a fragment" do
      it "preserves fragment after processing query string" do
        url = "https://example.com/page?foo=bar&amp;baz=qux#section"
        result = middleware.send(:encode_redirect_url, url)
        
        expect(result).to include("foo=bar&baz=qux#section")
        expect(result).not_to include("&amp;")
      end
    end

    context "when URL has already percent-encoded ampersand in value (%26)" do
      it "preserves the percent-encoded ampersand" do
        url = "https://example.com/page?redirect=http%3A%2F%2Ftest.com%3Fa%3D1%26b%3D2"
        result = middleware.send(:encode_redirect_url, url)
        
        # The %26 in the value should remain as %26, not become &
        expect(result).to include("redirect=http%3A%2F%2Ftest.com%3Fa%3D1%26b%3D2")
      end
    end

    context "when URL is invalid" do
      it "returns original URL as fallback" do
        invalid_url = "not a valid url at all"
        result = middleware.send(:encode_redirect_url, invalid_url)
        
        expect(result).to eq(invalid_url)
      end
    end

    context "when URL has spaces (should be encoded)" do
      it "percent-encodes spaces" do
        url = "https://example.com/page?name=John Doe&city=New York"
        result = middleware.send(:encode_redirect_url, url)
        
        expect(result).to include("name=John+Doe")
        expect(result).to include("city=New+York")
      end
    end
  end

  describe "Postal::MessageParser HTML entity unescaping" do
    context "when parsing HTML href with &amp; entities" do
      it "converts &amp; to & before storing URL" do
        html_url = "https://example.com/page?foo=bar&amp;baz=qux"
        unescaped = CGI.unescapeHTML(html_url)
        
        expect(unescaped).to eq("https://example.com/page?foo=bar&baz=qux")
        expect(unescaped).not_to include("&amp;")
      end
    end

    context "when parsing HTML with multiple HTML entities" do
      it "unescapes all entities correctly" do
        html_url = "https://example.com/page?a=1&amp;b=2&amp;c=3"
        unescaped = CGI.unescapeHTML(html_url)
        
        expect(unescaped).to eq("https://example.com/page?a=1&b=2&c=3")
      end
    end

    context "when parsing HTML with &lt; and &gt;" do
      it "converts to actual < and > characters" do
        html_url = "https://example.com/page?val=&lt;test&gt;"
        unescaped = CGI.unescapeHTML(html_url)
        
        expect(unescaped).to eq("https://example.com/page?val=<test>")
      end
    end
  end

  describe "End-to-end URL flow" do
    it "properly handles URL from HTML email through to HTTP redirect" do
      # Simulate URL as it appears in HTML email
      html_url = "https://example.com/page?foo=bar&amp;baz=qux&amp;id=123"
      
      # Step 1: Message parser unescapes HTML entities
      stored_url = CGI.unescapeHTML(html_url)
      expect(stored_url).to eq("https://example.com/page?foo=bar&baz=qux&id=123")
      
      # Step 2: Tracking middleware encodes for HTTP Location header
      middleware = TrackingMiddleware.new
      redirect_url = middleware.send(:encode_redirect_url, stored_url)
      
      # Final URL should have plain & separators (HTTP standard)
      expect(redirect_url).to eq("https://example.com/page?foo=bar&baz=qux&id=123")
      expect(redirect_url).not_to include("&amp;")
    end

    it "handles edge case of already-escaped URL in database" do
      # Simulate a URL that was incorrectly stored with &amp; (legacy data)
      stored_url = "https://example.com/page?foo=bar&amp;baz=qux"
      
      # Tracking middleware should still normalize it correctly
      middleware = TrackingMiddleware.new
      redirect_url = middleware.send(:encode_redirect_url, stored_url)
      
      expect(redirect_url).to include("foo=bar&baz=qux")
      expect(redirect_url).not_to include("&amp;")
    end
  end

  describe "IIS compatibility" do
    it "generates Location headers that IIS will accept" do
      test_cases = [
        "https://example.com/page?foo=bar&baz=qux",
        "https://shop.com/product?id=123&variant=blue&size=large",
        "https://app.com/redirect?url=http%3A%2F%2Fexample.com&source=email"
      ]
      
      middleware = TrackingMiddleware.new
      
      test_cases.each do |url|
        result = middleware.send(:encode_redirect_url, url)
        
        # Should use & as separator (not &amp;)
        expect(result).not_to include("&amp;")
        
        # Should be parseable as valid URI
        expect { URI.parse(result) }.not_to raise_error
        
        # Should have proper query string format
        uri = URI.parse(result)
        if uri.query
          # Query should parse correctly
          params = URI.decode_www_form(uri.query)
          expect(params).to be_a(Array)
          expect(params.length).to be > 0
        end
      end
    end
  end
end
