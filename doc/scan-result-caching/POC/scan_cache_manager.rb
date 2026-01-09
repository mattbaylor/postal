# frozen_string_literal: true

require "digest"

module Postal
  # Manages caching of message scan results to avoid redundant spam/virus scanning
  class ScanCacheManager
    class << self
      # Normalize message content for hashing
      # Removes headers that change per-recipient but don't affect scan results
      def normalize_message(raw_message)
        # Split headers and body
        parts = raw_message.split(/\r?\n\r?\n/, 2)
        return raw_message if parts.length != 2

        headers = parts[0]
        body = parts[1]

        # Remove/normalize headers that vary per message but don't affect scanning
        normalized_headers = headers.split(/\r?\n/).reject do |line|
          # Remove message-ID style headers (unique per message)
          line =~ /^X-Postal-MsgID:/i ||
            line =~ /^Message-ID:/i ||
            line =~ /^Received:/i || # Routing path changes per delivery
            line =~ /^Date:/i # Timestamp changes
        end.map do |line|
          # Normalize recipient headers (To, Cc) since they don't affect spam scores significantly
          # But keep From, Subject, etc as they do affect scoring
          if line =~ /^(To|Cc):/i
            "#{::Regexp.last_match(1)}: <normalized>"
          else
            line
          end
        end.join("\n")

        "#{normalized_headers}\n\n#{body}"
      end

      # Compute SHA-256 hash of normalized message
      def compute_hash(raw_message)
        normalized = normalize_message(raw_message)
        Digest::SHA256.hexdigest(normalized)
      end

      # Check if caching is enabled globally and for this server
      def caching_enabled?(server_id = nil)
        # Global check
        return false unless Postal::Config.message_inspection.cache_enabled?

        # Per-server check (if server_id provided)
        if server_id
          server = ::Server.find_by(id: server_id)
          return false if server&.disable_scan_caching
        end

        true
      rescue StandardError => e
        Postal.logger.error "Error checking cache config: #{e.message}"
        false
      end

      # Look up cached scan result
      def lookup(raw_message, message_size)
        content_hash = compute_hash(raw_message)

        cache_entry = ::ScanResultCache.find_by(
          content_hash: content_hash,
          message_size: message_size
        )

        return nil unless cache_entry

        # Check if entry has expired
        ttl_days = Postal::Config.message_inspection.cache_ttl_days
        return nil unless cache_entry.valid_cache_entry?(ttl_days)

        cache_entry
      rescue StandardError => e
        Postal.logger.error "Cache lookup failed: #{e.class} #{e.message}"
        nil
      end

      # Store scan result in cache
      def store(raw_message, message_size, inspection_result)
        # Don't cache threats or high spam scores (security policy)
        return if inspection_result.threat
        return if inspection_result.spam_score > cache_threshold

        content_hash = compute_hash(raw_message)

        ::ScanResultCache.create!(
          content_hash: content_hash,
          message_size: message_size,
          spam_score: inspection_result.spam_score,
          threat: inspection_result.threat,
          threat_message: inspection_result.threat_message,
          spam_checks: inspection_result.spam_checks
        )

        Postal.logger.info "Stored scan result in cache [hash=#{content_hash[0..7]}]"
      rescue ActiveRecord::RecordNotUnique
        # Race condition: another thread cached this first, that's fine
        Postal.logger.debug "Cache entry already exists [hash=#{content_hash[0..7]}]"
      rescue StandardError => e
        # Never fail message processing due to cache storage errors
        Postal.logger.error "Failed to store in cache: #{e.class} #{e.message}"
      end

      # Perform cache maintenance (evict old/LRU entries)
      def perform_maintenance
        ttl_days = Postal::Config.message_inspection.cache_ttl_days
        max_entries = Postal::Config.message_inspection.cache_max_entries

        # Delete expired entries
        deleted_count = ::ScanResultCache.where("scanned_at < ?", ttl_days.days.ago).delete_all
        Postal.logger.info "Deleted #{deleted_count} expired cache entries" if deleted_count > 0

        # If over max entries, delete least-hit entries
        total_entries = ::ScanResultCache.count
        if total_entries > max_entries
          excess = total_entries - max_entries
          ::ScanResultCache.order(hit_count: :asc, scanned_at: :asc).limit(excess).delete_all
          Postal.logger.info "Deleted #{excess} LRU cache entries (over max)"
        end
      rescue StandardError => e
        Postal.logger.error "Cache maintenance failed: #{e.class} #{e.message}"
      end

      private

      # Don't cache messages with spam scores near threshold (80% of threshold)
      def cache_threshold
        threshold = Postal::Config.postal.default_spam_threshold || 5.0
        threshold * 0.8
      end
    end
  end
end
