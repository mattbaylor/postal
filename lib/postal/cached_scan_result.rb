# frozen_string_literal: true

module Postal
  # Wrapper class that makes cached results compatible with MessageInspection interface
  class CachedScanResult
    attr_reader :message, :scope, :spam_checks, :threat, :threat_message, :from_cache

    def initialize(cache_entry, message, scope)
      @cache_entry = cache_entry
      @message = message
      @scope = scope
      @spam_checks = cache_entry.spam_checks
      @threat = cache_entry.threat
      @threat_message = cache_entry.threat_message
      @from_cache = true
    end

    def spam_score
      @cache_entry.spam_score
    end

    # Mark this result as coming from cache
    def cached?
      true
    end

    # Record the cache hit
    def record_hit!
      @cache_entry.record_hit!
    rescue StandardError => e
      # Don't fail message processing if cache hit recording fails
      Postal.logger.error "Failed to record cache hit: #{e.message}"
    end
  end
end
