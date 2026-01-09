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
            line =~ /^Date:/i || # Timestamp changes
            line =~ /^DKIM-Signature:/i # DKIM signature is unique per message (includes timestamp)
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

      # Compute SHA-256 hash of normalized full message
      def compute_hash(raw_message)
        normalized = normalize_message(raw_message)
        Digest::SHA256.hexdigest(normalized)
      end

      # Compute SHA-256 hash of attachments only
      def compute_attachment_hash(raw_message)
        # Quick pre-check before expensive parsing
        return nil unless raw_message.include?('Content-Disposition: attachment') ||
                          raw_message.include?('Content-Type: application/')

        begin
          mail = Mail.new(raw_message)
          return nil if mail.attachments.empty?

          # Sort for consistent ordering
          attachment_data = mail.attachments.map do |att|
            "#{att.filename}|#{att.content_type}|#{att.body.decoded}"
          end.sort.join("||")

          Digest::SHA256.hexdigest(attachment_data)
        rescue StandardError => e
          Postal.logger.warn "Failed to compute attachment hash: #{e.class} #{e.message}"
          nil
        end
      end

      # Compute SHA-256 hash of message with personalization stripped
      def compute_body_template_hash(raw_message)
        parts = raw_message.split(/\r?\n\r?\n/, 2)
        return nil if parts.length != 2

        headers_section = parts[0]
        body_section = parts[1]

        # Extract subject
        subject = headers_section[/^Subject:\s*(.+)$/i, 1] || ""

        # Get text body (simple heuristic)
        text_body = body_section.split(/--[-=_\w]+/).first || body_section

        # Normalize template patterns
        template_subject = normalize_template_text(subject)
        template_body = normalize_template_text(text_body)

        template_content = "#{template_subject}||#{template_body}"
        Digest::SHA256.hexdigest(template_content)
      rescue StandardError => e
        Postal.logger.warn "Failed to compute template hash: #{e.class} #{e.message}"
        nil
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

      # Look up cached scan result with multi-hash support (sequential, lazy)
      def lookup(raw_message, message_size)
        ttl_days = Postal::Config.message_inspection.cache_ttl_days

        # STEP 1: Check full message hash (most precise, most common)
        full_hash = compute_hash(raw_message)
        cache_entry = find_by_hash(full_hash, message_size, ttl_days)
        if cache_entry
          record_cache_hit(cache_entry, :full)
          return cache_entry
        end

        # STEP 2: Check attachment hash (only if enabled and has attachments)
        if attachment_hash_enabled?
          attachment_hash = compute_attachment_hash(raw_message)
          if attachment_hash
            cache_entry = find_by_attachment_hash(attachment_hash, message_size, ttl_days)
            if cache_entry
              record_cache_hit(cache_entry, :attachment)
              return cache_entry
            end
          end
        end

        # STEP 3: Check template hash (only if enabled)
        if template_hash_enabled?
          template_hash = compute_body_template_hash(raw_message)
          if template_hash
            cache_entry = find_by_template_hash(template_hash, message_size, ttl_days)
            if cache_entry
              record_cache_hit(cache_entry, :template)
              return cache_entry
            end
          end
        end

        # No cache hit on any hash type
        Postal.logger.debug "Cache MISS for all hash types"
        nil
      rescue StandardError => e
        Postal.logger.error "Cache lookup failed: #{e.class} #{e.message}"
        nil
      end

      # Store scan result in cache with all hash types
      def store(raw_message, message_size, inspection_result)
        # Security policies
        return if inspection_result.threat
        # More conservative threshold for template hash security
        return if inspection_result.spam_score > 2.0

        # Compute all hashes upfront (for storage)
        full_hash = compute_hash(raw_message)
        attachment_hash = compute_attachment_hash(raw_message)
        template_hash = compute_body_template_hash(raw_message)

        ::ScanResultCache.create!(
          content_hash: full_hash,
          attachment_hash: attachment_hash,
          body_template_hash: template_hash,
          message_size: message_size,
          spam_score: inspection_result.spam_score,
          threat: inspection_result.threat,
          threat_message: inspection_result.threat_message,
          spam_checks: inspection_result.spam_checks
        )

        Postal.logger.info "Stored scan result [full=#{full_hash[0..7]} att=#{attachment_hash&.[](0..7) || 'nil'} tmpl=#{template_hash&.[](0..7) || 'nil'}]"
      rescue ActiveRecord::RecordNotUnique
        # Race condition: another thread cached this first, that's fine
        Postal.logger.debug "Cache entry already exists"
      rescue StandardError => e
        # Never fail message processing due to cache errors
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

      # Cache invalidation (for signature updates)
      def invalidate_all!
        count = ::ScanResultCache.count
        ::ScanResultCache.delete_all
        Postal.logger.warn "Invalidated entire cache (#{count} entries deleted)"
      end

      def invalidate_older_than(timestamp)
        count = ::ScanResultCache.where("scanned_at < ?", timestamp).delete_all
        Postal.logger.info "Invalidated #{count} cache entries older than #{timestamp}"
      end

      private

      # Find by full message hash (uses existing unique index)
      def find_by_hash(content_hash, message_size, ttl_days)
        ::ScanResultCache
          .where(content_hash: content_hash, message_size: message_size)
          .where("scanned_at > ?", ttl_days.days.ago)
          .first
      end

      # Find by attachment hash (uses new composite index)
      def find_by_attachment_hash(attachment_hash, message_size, ttl_days)
        ::ScanResultCache
          .where(attachment_hash: attachment_hash, message_size: message_size)
          .where("scanned_at > ?", ttl_days.days.ago)
          .first
      end

      # Find by template hash (uses new composite index)
      def find_by_template_hash(template_hash, message_size, ttl_days)
        ::ScanResultCache
          .where(body_template_hash: template_hash, message_size: message_size)
          .where("scanned_at > ?", ttl_days.days.ago)
          .first
      end

      # Record cache hit with type tracking
      def record_cache_hit(cache_entry, match_type)
        cache_entry.update(matched_via: match_type.to_s, last_hit_at: Time.current)
        cache_entry.increment!(:hit_count)
        Postal.logger.info "Cache HIT (#{match_type}) for hash #{cache_entry.content_hash[0..7]}"
      end

      # Normalize text for template matching (conservative patterns)
      def normalize_template_text(text)
        text.dup
          # Only in greeting patterns
          .gsub(/\b(Hi|Hello|Dear|Hey|Greetings)\s+([A-Z][a-z]+)\b/i, '\1 {{NAME}}')
          .gsub(/\b(Hi|Hello|Dear)\s+([A-Z][a-z]+\s+[A-Z][a-z]+)\b/i, '\1 {{NAME}}')
          # Email addresses
          .gsub(/\b[\w.+-]+@[\w.-]+\.\w{2,}\b/, '{{EMAIL}}')
          # Phone numbers
          .gsub(/\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/, '{{PHONE}}')
          .gsub(/\b\+\d{1,3}\s?\d{1,4}\s?\d{1,4}\s?\d{1,9}\b/, '{{PHONE}}')
          # IDs in context
          .gsub(/\b(order|tracking|invoice|ticket|case|id|#)\s*[:#]?\s*(\d{5,})\b/i, '\1 {{ID}}')
          # Normalize whitespace
          .gsub(/\s+/, ' ')
          .strip
      end

      # Check if attachment hash is enabled
      def attachment_hash_enabled?
        Postal::Config.message_inspection.cache_attachment_hash_enabled
      rescue StandardError
        true # Default to enabled
      end

      # Check if template hash is enabled
      def template_hash_enabled?
        Postal::Config.message_inspection.cache_template_hash_enabled
      rescue StandardError
        true # Default to enabled
      end

      # Don't cache messages with spam scores > 2.0 (conservative for security)
      def cache_threshold
        2.0
      end
    end
  end
end
