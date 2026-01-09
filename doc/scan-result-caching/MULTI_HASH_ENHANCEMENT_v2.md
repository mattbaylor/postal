# Multi-Hash Cache Enhancement Plan (v2 - REVISED)

**Date:** January 8, 2026  
**Status:** Ready for Implementation  
**Purpose:** Improve cache hit rates for personalized email content  
**Version:** 2.0 - Addresses technical review feedback

---

## Revision History

- **v1.0** (2026-01-08): Initial draft
- **v2.0** (2026-01-08): Fixed critical issues identified in technical review
  - Changed from OR query to sequential lookups (performance)
  - Fixed template regex to avoid over-matching
  - Implemented lazy hash computation
  - Added composite indexes for query performance
  - Fixed attachment ordering consistency
  - Added cache invalidation mechanism
  - Added security mitigations for template hash
  - Answered key design questions

---

## Executive Summary

The current scan result cache uses a single content hash (full message). This works well for identical messages but fails to cache personalized newsletters where recipients see different greetings/content but share the same attachments or message template.

**Proposed Solution:** Store multiple hash types (full message, attachments-only, body template) in the same cache entry. On lookup, check hash types sequentially with lazy computation - first match wins.

**Expected Impact:**
- Current: 0% cache hit for personalized newsletters (1000 messages = 1000 scans)
- With multi-hash: 70-90% cache hit for personalized newsletters (1000 messages = 10-300 scans)
- Performance: Sequential lookups use indexes efficiently, <5ms overhead per lookup

**Key Improvements from v1:**
- Sequential lookups instead of OR query (index-friendly)
- Lazy hash computation (compute only what's needed)
- Conservative template matching (security-first)
- Composite indexes for optimal query performance

---

## Problem Statement

### Current Behavior

**Cache Hit Scenario (works today):**
```
Message 1: "Hi there, Check out our sale!"
Message 2: "Hi there, Check out our sale!"
Result: Cache HIT ✅
```

**Cache Miss Scenario (fails today):**
```
Message 1: "Hi John, Check out our sale!"
Message 2: "Hi Sarah, Check out our sale!"
Result: Cache MISS ❌ (different text = different hash)
```

### Customer Impact

Many customers use personalization:
- Newsletter greetings: "Hi {{FirstName}}"
- Body content: "Your order #{{OrderID}} shipped"
- Signatures: "Thanks, {{SenderName}}"

These messages are functionally identical for spam/virus scanning but get different hashes, causing:
- 0% cache hit rate
- Full SpamAssassin + ClamAV scan for every recipient
- Thread pool exhaustion during bulk sends (the original problem returns)

---

## Proposed Solution

### Concept: Multi-Hash Storage with Lazy Lookup

Store **three hash types** for each scanned message:

1. **Full Message Hash** (existing)
   - SHA-256 of normalized full message
   - Use case: Non-personalized messages
   - Example: Plain newsletters, transactional emails
   - **Priority:** Check first (most precise, most common)

2. **Attachment Hash** (new)
   - SHA-256 of all attachment contents combined (sorted)
   - Use case: Personalized text + same attachments
   - Example: "Hi John" vs "Hi Sarah" but same PDF
   - **Priority:** Check second (precise for attachment-based caching)

3. **Body Template Hash** (new)
   - SHA-256 of message with personalization stripped (conservative)
   - Use case: Personalized greetings in known patterns
   - Example: "Hi John" → "Hi {{NAME}}"
   - **Priority:** Check last (least precise, best-effort)

### Lookup Strategy (Sequential with Lazy Computation)

```ruby
# Compute and check full hash first (most common case)
full_hash = compute_full_hash(raw_message)
IF full_hash matches in DB → Cache HIT (return immediately)

# Only if full hash missed, compute and check attachment hash
attachment_hash = compute_attachment_hash(raw_message)
IF attachment_hash matches in DB → Cache HIT (return immediately)

# Only if both missed, compute and check template hash
template_hash = compute_template_hash(raw_message)
IF template_hash matches in DB → Cache HIT (return immediately)

# All hashes missed → Cache MISS (perform full scan)
```

**Key improvement:** For identical messages (majority case), only one hash is computed and one DB query executed.

---

## Technical Design

### Database Schema Changes

**Add to existing `scan_result_cache` table:**

```sql
ALTER TABLE scan_result_cache 
  ADD COLUMN attachment_hash VARCHAR(64) DEFAULT NULL,
  ADD COLUMN body_template_hash VARCHAR(64) DEFAULT NULL,
  ADD COLUMN matched_via VARCHAR(20) DEFAULT NULL,
  
  -- Composite indexes for efficient lookup with message_size
  ADD INDEX idx_attachment_hash_size (attachment_hash, message_size),
  ADD INDEX idx_template_hash_size (body_template_hash, message_size);
```

**Rationale for changes:**
- `attachment_hash`, `body_template_hash`: Store additional hash types
- `matched_via`: Track which hash type was used for hit (metrics/debugging)
- Composite indexes: Enable efficient queries that filter by both hash AND message_size
- No unique constraints on new hashes: Multiple messages can have same attachment/template

**Complete schema:**
```sql
CREATE TABLE scan_result_cache (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  
  -- Hash columns (3 ways to match)
  content_hash VARCHAR(64) NOT NULL,           -- Full message (existing)
  attachment_hash VARCHAR(64) DEFAULT NULL,    -- Attachments only (NEW)
  body_template_hash VARCHAR(64) DEFAULT NULL, -- Template pattern (NEW)
  matched_via VARCHAR(20) DEFAULT NULL,        -- Hit tracking (NEW)
  
  -- Message metadata
  message_size INT NOT NULL,
  
  -- Scan results
  spam_score DECIMAL(10,2) NOT NULL,
  threat BOOLEAN NOT NULL DEFAULT 0,
  threat_message TEXT,
  spam_checks_json TEXT,
  
  -- Cache metadata
  scanned_at DATETIME NOT NULL,
  last_hit_at DATETIME,
  hit_count INT NOT NULL DEFAULT 0,
  
  -- Indexes (UPDATED)
  UNIQUE INDEX idx_full_hash_size (content_hash, message_size),
  INDEX idx_attachment_hash_size (attachment_hash, message_size),  -- Composite
  INDEX idx_template_hash_size (body_template_hash, message_size), -- Composite
  INDEX idx_scanned_at (scanned_at),
  INDEX idx_hit_count (hit_count)
);
```

**Storage Impact:**
- Current: ~500 bytes per row
- New: ~750 bytes per row (3 hashes + matched_via)
- 100K entries: 50MB → 75MB (+50% storage, still negligible)

### Hash Computation Logic

#### Design Principle: Parse Once, Use Everywhere

To avoid parsing the email multiple times with `Mail.new`, we'll use regex-based extraction similar to the existing `normalize_message` method.

#### 1. Full Message Hash (existing, no changes)

```ruby
def compute_full_hash(raw_message)
  normalized = normalize_message(raw_message)
  Digest::SHA256.hexdigest(normalized)
end

def normalize_message(raw_message)
  # Remove recipient-specific headers (To, Cc, Message-ID, Date)
  # Keep: From, Subject, Body, Attachments
  # Existing implementation unchanged
end
```

#### 2. Attachment Hash (new - FIXED)

```ruby
def compute_attachment_hash(raw_message)
  # Quick check: does message even have attachments?
  return nil unless raw_message.include?('Content-Disposition: attachment') ||
                    raw_message.include?('Content-Type: application/')
  
  begin
    # Parse email to extract attachments
    mail = Mail.new(raw_message)
    
    return nil if mail.attachments.empty?
    
    # Extract attachment data and SORT for consistent ordering
    attachment_data = mail.attachments.map do |att|
      # Include filename, content-type, and content for uniqueness
      "#{att.filename}|#{att.content_type}|#{att.body.decoded}"
    end.sort.join("||")  # Sort to ensure consistent ordering
    
    Digest::SHA256.hexdigest(attachment_data)
  rescue => e
    # Graceful degradation: log error, return nil, proceed with other hashes
    Postal.logger.warn "Failed to compute attachment hash: #{e.class} #{e.message}"
    nil
  end
end
```

**Design decisions:**
- Quick pre-check with string search before expensive `Mail.new` parse
- Include filename, content-type, AND content (detect renamed files)
- **SORT** attachment array to ensure consistent ordering
- Return `nil` if no attachments or parse fails
- Graceful failure: never break message processing

**Security considerations:**
- Attachments with same content but different filenames will NOT match (safer)
- Multiple attachments in different order WILL match (after sorting)

#### 3. Body Template Hash (new - FIXED)

```ruby
def compute_body_template_hash(raw_message)
  # Split headers and body (same approach as normalize_message)
  parts = raw_message.split(/\r?\n\r?\n/, 2)
  return nil if parts.length != 2
  
  headers_section = parts[0]
  body_section = parts[1]
  
  # Extract subject from headers (important for template matching)
  subject = headers_section[/^Subject:\s*(.+)$/i, 1] || ""
  
  # Remove Base64/quoted-printable encoded parts to get text body
  # Simple heuristic: skip attachment boundaries
  text_body = body_section.split(/--[-=_\w]+/).first || body_section
  
  # Strip common personalization patterns CONSERVATIVELY
  template_subject = normalize_template_text(subject)
  template_body = normalize_template_text(text_body)
  
  # Combine subject + body for template hash
  template_content = "#{template_subject}||#{template_body}"
  
  Digest::SHA256.hexdigest(template_content)
rescue => e
  Postal.logger.warn "Failed to compute template hash: #{e.class} #{e.message}"
  nil
end

def normalize_template_text(text)
  text.dup
    # Only match names in GREETING patterns (not all capitalized words)
    .gsub(/\b(Hi|Hello|Dear|Hey|Greetings)\s+([A-Z][a-z]+)\b/i, '\1 {{NAME}}')
    # Match "Hi John Smith" (full names in greetings)
    .gsub(/\b(Hi|Hello|Dear)\s+([A-Z][a-z]+\s+[A-Z][a-z]+)\b/i, '\1 {{NAME}}')
    # Email addresses
    .gsub(/\b[\w.+-]+@[\w.-]+\.\w{2,}\b/, '{{EMAIL}}')
    # Phone numbers (multiple formats)
    .gsub(/\b\d{3}[-.\s]?\d{3}[-.\s]?\d{4}\b/, '{{PHONE}}')
    .gsub(/\b\+\d{1,3}\s?\d{1,4}\s?\d{1,4}\s?\d{1,9}\b/, '{{PHONE}}')
    # Order/tracking IDs in CONTEXT only
    .gsub(/\b(order|tracking|invoice|ticket|case|id|#)\s*[:#]?\s*(\d{5,})\b/i, '\1 {{ID}}')
    # Normalize whitespace
    .gsub(/\s+/, ' ')
    .strip
end
```

**Key improvements from v1:**
- ✅ **CONSERVATIVE regex:** Only matches names in greeting patterns (Hi/Hello/Dear), not all capitalized words
- ✅ Includes subject line (spam with same body but different subject won't match)
- ✅ Avoids `Mail.new` parsing by using regex extraction
- ✅ Matches common personalization patterns (greetings, IDs, phones, emails)
- ✅ Graceful failure handling

**Examples:**
```
"Hi John, thanks for ordering!" → "Hi {{NAME}}, thanks for ordering!"
"Dear Sarah Smith, your order #12345..." → "Dear {{NAME}}, your order {{ID}}..."
"Monday Sale!" → "Monday Sale!" (NOT changed - "Monday" not in greeting)
```

**Security mitigations (addressed from review):**
- Never cache messages with spam_score > 2.0 (more conservative than v1's 0.8 * threshold)
- Template hash is last resort (check full and attachment first)
- Log all template hash matches for first 30 days (monitoring)
- Feature flag to disable template hashing if issues arise

### Code Changes

#### File: `lib/postal/scan_cache_manager.rb` (REVISED)

```ruby
module Postal
  class ScanCacheManager
    class << self
      
      # Lookup with sequential checking and lazy hash computation
      def lookup(raw_message, message_size)
        ttl_days = Postal::Config.message_inspection.cache_ttl_days
        
        # STEP 1: Check full message hash (most precise, most common)
        full_hash = compute_full_hash(raw_message)
        cache_entry = find_by_hash(full_hash, message_size, ttl_days)
        if cache_entry
          record_cache_hit(cache_entry, :full)
          return cache_entry
        end
        
        # STEP 2: Check attachment hash (only if enabled and has attachments)
        if Postal::Config.message_inspection.cache_attachment_hash_enabled
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
        if Postal::Config.message_inspection.cache_template_hash_enabled
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
      
      # Store with all three hashes computed upfront
      def store(raw_message, message_size, inspection_result)
        # Security policies
        return if inspection_result.threat
        # More conservative threshold for template hash security
        return if inspection_result.spam_score > 2.0
        
        # Compute all hashes upfront (for storage)
        full_hash = compute_full_hash(raw_message)
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
      
      # Cache invalidation (NEW)
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
      
      # Hash computation methods
      
      def compute_full_hash(raw_message)
        normalized = normalize_message(raw_message)
        Digest::SHA256.hexdigest(normalized)
      end
      
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
        rescue => e
          Postal.logger.warn "Failed to compute attachment hash: #{e.class} #{e.message}"
          nil
        end
      end
      
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
      rescue => e
        Postal.logger.warn "Failed to compute template hash: #{e.class} #{e.message}"
        nil
      end
      
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
      
      # Existing methods unchanged
      
      def normalize_message(raw_message)
        # ... existing implementation from current code ...
      end
      
      def cache_threshold
        # More conservative: 2.0 instead of 0.8 * threshold
        2.0
      end
      
    end
  end
end
```

**Key changes from v1:**
1. ✅ Sequential lookups instead of OR query (uses indexes efficiently)
2. ✅ Lazy hash computation (only compute what's needed)
3. ✅ Conservative template regex (won't over-match)
4. ✅ Sorted attachments (consistent ordering)
5. ✅ More conservative spam threshold (2.0 vs ~4.0)
6. ✅ Cache invalidation methods added
7. ✅ Feature flags for each hash type
8. ✅ Better logging with hash type tracking

#### File: `app/models/scan_result_cache.rb`

Add method to support matched_via tracking:

```ruby
class ScanResultCache < ApplicationRecord
  # ... existing code ...
  
  # Track which hash type was matched (for metrics)
  enum matched_via: {
    full: 'full',
    attachment: 'attachment',
    template: 'template'
  }, _prefix: true
  
  # ... rest of existing code unchanged ...
end
```

#### File: `lib/postal/message_db/message.rb`

No changes needed - integration point unchanged.

---

## Migration Strategy

### Migration File

**File:** `db/migrate/20260108000000_add_multi_hash_to_scan_result_cache.rb`

```ruby
class AddMultiHashToScanResultCache < ActiveRecord::Migration[7.0]
  def up
    # Add new columns
    add_column :scan_result_cache, :attachment_hash, :string, limit: 64
    add_column :scan_result_cache, :body_template_hash, :string, limit: 64
    add_column :scan_result_cache, :matched_via, :string, limit: 20
    
    # Add composite indexes for efficient lookup
    add_index :scan_result_cache, [:attachment_hash, :message_size], 
      name: 'idx_scan_cache_attachment_hash_size'
    add_index :scan_result_cache, [:body_template_hash, :message_size], 
      name: 'idx_scan_cache_template_hash_size'
  end
  
  def down
    remove_index :scan_result_cache, name: 'idx_scan_cache_template_hash_size'
    remove_index :scan_result_cache, name: 'idx_scan_cache_attachment_hash_size'
    remove_column :scan_result_cache, :matched_via
    remove_column :scan_result_cache, :body_template_hash
    remove_column :scan_result_cache, :attachment_hash
  end
end
```

### Execution Plan

**Step 1: Run migration**
```bash
docker exec install-worker-1 rails db:migrate
```

**Expected:** ~5 seconds, no downtime (columns are nullable).

**Step 2: Deploy code**
```bash
cd /opt/postal/install
git pull  # or deploy your changes
docker-compose restart worker
```

**Step 3: Verify**
```bash
# Check config
docker exec install-worker-1 rails runner "
  puts 'Cache enabled: ' + Postal::ScanCacheManager.caching_enabled?.to_s
"

# Watch logs
docker logs -f install-worker-1 | grep -i cache
```

---

## Configuration Options (UPDATED)

### New Config Settings

Add to `lib/postal/config_schema.rb`:

```ruby
group :message_inspection do
  boolean :cache_enabled do
    description "Enable caching of spam/virus scan results"
    default false
  end
  
  integer :cache_ttl_days do
    description "Number of days to keep scan results in cache"
    default 7
  end
  
  integer :cache_max_entries do
    description "Maximum number of cache entries (LRU eviction)"
    default 100_000
  end
  
  # NEW: Feature flags for hash types
  boolean :cache_attachment_hash_enabled do
    description "Enable attachment-based cache matching"
    default true
  end
  
  boolean :cache_template_hash_enabled do
    description "Enable template-based cache matching (personalization detection)"
    default true  # Can disable if false positives occur
  end
end
```

### Configuration in postal.yml (v2 format)

```yaml
message_inspection:
  cache_enabled: true
  cache_ttl_days: 7
  cache_max_entries: 100000
  cache_attachment_hash_enabled: true
  cache_template_hash_enabled: true  # Disable if issues arise
```

---

## Edge Cases & Risk Analysis (UPDATED)

### Edge Case 1: Template Hash False Positives (MITIGATED)

**Scenario:** Two different messages incorrectly match via template hash.

**v1 Risk:** HIGH - regex matched all capitalized words  
**v2 Mitigation:** 
- ✅ Conservative regex (only in greeting patterns)
- ✅ Include subject line in template hash
- ✅ Lower spam score threshold (2.0 vs 4.0)
- ✅ Full hash checked first (precision)
- ✅ Feature flag to disable if needed

**Severity:** Low (was Medium in v1)

### Edge Case 2: Query Performance (FIXED)

**Scenario:** Slow cache lookups degrade overall performance.

**v1 Risk:** HIGH - OR query causes table scan  
**v2 Mitigation:**
- ✅ Sequential lookups use indexes efficiently
- ✅ Lazy computation (stop on first hit)
- ✅ Composite indexes include message_size
- ✅ Each query is index-only (no table scan)

**Severity:** Low (was Critical in v1)

### Edge Case 3: Attachment Order Inconsistency (FIXED)

**Scenario:** Same attachments in different order produce different hashes.

**v1 Risk:** MEDIUM - attachments not sorted  
**v2 Mitigation:**
- ✅ Attachments sorted before hashing
- ✅ Consistent ordering guaranteed

**Severity:** Resolved

### Edge Case 4: Cache Invalidation After Signature Updates (ADDRESSED)

**Scenario:** ClamAV signatures update, old "clean" entries become stale.

**v1 Risk:** HIGH - no invalidation mechanism  
**v2 Mitigation:**
- ✅ Added `invalidate_older_than(timestamp)` method
- ✅ Can be called after signature updates
- ✅ Selective invalidation (don't clear entire cache)

**Severity:** Low (was High in v1)

### Edge Case 5: Multi-Node Cache Stampede (ACKNOWLEDGED)

**Scenario:** 100 workers miss cache simultaneously, all scan same message.

**v2 Status:** Acknowledged, not fixed in this phase  
**Mitigation plan:**
- Use `INSERT ... ON DUPLICATE KEY UPDATE` (MySQL upsert)
- First write wins, others get duplicate key error (harmless)
- Future: Add distributed locking if needed

**Severity:** Low (acceptable for v1 implementation)

---

## Design Questions Answered

### Q1: Is message_size needed for attachment/template hashes?

**Answer:** YES, keep it.

**Rationale:** 
- Attachment hash: Message with same PDF but different body text will have different size
- Template hash: Size serves as quick pre-filter (same template, different recipient count = similar size)
- Performance: Composite index (hash, size) is more selective than hash alone
- Backward compatibility: Existing code expects size parameter

### Q2: If Server A disables caching, can its scans populate the global cache?

**Answer:** NO, scans from opt-out servers do NOT populate cache.

**Rationale:**
- `caching_enabled?(server_id)` checks both global flag AND per-server flag
- If server opts out, lookup returns nil immediately
- Store is only called if `caching_enabled?` was true
- This prevents compliance/regulatory issues

**Code location:** `scan_cache_manager.rb:52-53` and `message.rb:524,540`

### Q3: Should attachment hash match if attachment count differs?

**Answer:** NO, different attachment count = different hash.

**Rationale:**
- Hash includes ALL attachment data concatenated
- Message with 1 attachment vs 2 attachments = different concatenated string = different hash
- This is correct behavior (more attachments = potentially more risk)

---

## Testing Strategy (UPDATED)

### Unit Tests

**File:** `spec/lib/postal/scan_cache_manager_spec.rb`

```ruby
describe "Multi-hash caching (v2)" do
  describe ".compute_attachment_hash" do
    it "returns nil for messages without attachments"
    it "computes same hash for identical attachments"
    it "computes different hash when attachment content changes"
    it "includes filename in hash"
    it "handles multiple attachments in different order (sorted)" # NEW
    it "handles malformed attachments gracefully"
  end
  
  describe ".compute_body_template_hash" do
    it "normalizes names only in greeting patterns" # UPDATED
    it "does NOT normalize capitalized words outside greetings" # NEW
    it "includes subject line in template hash" # NEW
    it "normalizes email addresses"
    it "normalizes phone numbers (multiple formats)" # UPDATED
    it "normalizes IDs only in context (order, tracking, etc)" # UPDATED
    it "produces same hash for messages with different names in greetings"
    it "produces different hash for messages with different subjects"
  end
  
  describe ".lookup" do
    it "checks full hash first (priority 1)" # UPDATED
    it "checks attachment hash second (priority 2)" # UPDATED
    it "checks template hash last (priority 3)" # UPDATED
    it "stops on first match (lazy computation)" # NEW
    it "uses correct indexes for each query" # NEW
    it "returns nil when all hashes miss"
    it "respects TTL for all hash types"
    it "logs which hash type matched"
    it "respects feature flags for each hash type" # NEW
  end
  
  describe ".store" do
    it "stores all three hashes"
    it "stores nil for attachment hash when no attachments"
    it "does not cache messages with spam_score > 2.0" # UPDATED
    it "handles template hash computation failures gracefully"
  end
  
  describe "cache invalidation" do # NEW
    it "invalidate_all! deletes entire cache"
    it "invalidate_older_than deletes only old entries"
    it "logs invalidation count"
  end
end
```

### Integration Tests

**Scenario 1: Lazy computation optimization**
```ruby
it "only computes full hash when full hash hits" do
  msg1 = create_message(body: "Hi there, check our sale!")
  msg2 = create_message(body: "Hi there, check our sale!")
  
  msg1.inspect_message  # Stores in cache
  
  # Mock to verify attachment/template hashes NOT computed
  expect(ScanCacheManager).to receive(:compute_attachment_hash).never
  expect(ScanCacheManager).to receive(:compute_body_template_hash).never
  
  msg2.inspect_message  # Should hit on full hash only
end
```

**Scenario 2: Sequential lookup priority**
```ruby
it "checks hashes in priority order: full, attachment, template" do
  msg = create_message(body: "Hi John", attachments: [pdf])
  
  call_order = []
  allow(ScanCacheManager).to receive(:find_by_hash) do |hash|
    call_order << :full
    nil  # Force miss
  end
  allow(ScanCacheManager).to receive(:find_by_attachment_hash) do
    call_order << :attachment
    nil  # Force miss
  end
  allow(ScanCacheManager).to receive(:find_by_template_hash) do
    call_order << :template
    nil
  end
  
  msg.inspect_message
  expect(call_order).to eq([:full, :attachment, :template])
end
```

**Scenario 3: Template hash with conservative matching**
```ruby
it "does not normalize non-greeting capitalized words" do
  msg1 = create_message(body: "Monday Sale! Buy now!")
  msg2 = create_message(body: "Tuesday Sale! Buy now!")
  
  hash1 = ScanCacheManager.compute_body_template_hash(msg1.raw_message)
  hash2 = ScanCacheManager.compute_body_template_hash(msg2.raw_message)
  
  # Should NOT match (Monday != Tuesday, not in greeting pattern)
  expect(hash1).not_to eq(hash2)
end

it "normalizes names only in greetings" do
  msg1 = create_message(body: "Hi John, our Monday sale is great!")
  msg2 = create_message(body: "Hi Sarah, our Monday sale is great!")
  
  hash1 = ScanCacheManager.compute_body_template_hash(msg1.raw_message)
  hash2 = ScanCacheManager.compute_body_template_hash(msg2.raw_message)
  
  # Should match ("John" and "Sarah" both normalized, "Monday" NOT normalized)
  expect(hash1).to eq(hash2)
end
```

### Performance Tests

```ruby
describe "Performance" do
  it "full hash computation is < 5ms" do
    message = create_large_message(size: 5.megabytes)
    elapsed = Benchmark.realtime { ScanCacheManager.compute_full_hash(message) }
    expect(elapsed).to be < 0.005
  end
  
  it "cache hit (full) with lazy computation is < 5ms" do
    message = create_message
    ScanCacheManager.store(message, 1000, clean_result)
    
    elapsed = Benchmark.realtime { ScanCacheManager.lookup(message, 1000) }
    expect(elapsed).to be < 0.005  # Only one hash + one query
  end
  
  it "cache miss (all hashes) is < 15ms" do
    message = create_message_with_attachments
    
    elapsed = Benchmark.realtime { ScanCacheManager.lookup(message, 1000) }
    expect(elapsed).to be < 0.015  # Three hashes + three queries
  end
end
```

---

## Monitoring & Metrics (UPDATED)

### Key Metrics to Track

**1. Cache hit rate by hash type:**
```sql
-- Last 24 hours hit breakdown
SELECT 
  matched_via,
  COUNT(*) as hits,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) as percentage
FROM scan_result_cache
WHERE last_hit_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)
GROUP BY matched_via;

-- Expected output:
-- matched_via | hits  | percentage
-- full        | 15000 | 75.0%
-- attachment  | 3000  | 15.0%
-- template    | 2000  | 10.0%
```

**2. Template hash false positive detection:**
```sql
-- Find template matches with significantly different spam scores
SELECT 
  body_template_hash,
  COUNT(*) as match_count,
  MIN(spam_score) as min_score,
  MAX(spam_score) as max_score,
  MAX(spam_score) - MIN(spam_score) as score_variance
FROM scan_result_cache
WHERE body_template_hash IS NOT NULL
GROUP BY body_template_hash
HAVING score_variance > 2.0  -- Flag if variance > 2.0
ORDER BY score_variance DESC
LIMIT 20;
```

**3. Cache performance:**
```sql
-- Average hit count by hash type
SELECT 
  CASE 
    WHEN attachment_hash IS NULL AND body_template_hash IS NULL THEN 'full_only'
    WHEN attachment_hash IS NOT NULL THEN 'with_attachment'
    WHEN body_template_hash IS NOT NULL THEN 'with_template'
  END as entry_type,
  COUNT(*) as entries,
  AVG(hit_count) as avg_hits,
  MAX(hit_count) as max_hits
FROM scan_result_cache
GROUP BY entry_type;
```

### Prometheus Metrics

```ruby
# In scan_cache_manager.rb
def record_cache_hit(cache_entry, match_type)
  # ... existing code ...
  
  # Prometheus metrics
  Postal.prometheus&.increment('scan_cache_hits_total', labels: { type: match_type })
end

def lookup(raw_message, message_size)
  # ... existing code ...
  
  if cache_miss
    Postal.prometheus&.increment('scan_cache_misses_total')
  end
end
```

### Alerts

**Alert 1: High template hash variance (false positives)**
```
IF template_hash_score_variance > 2.0 for >5% of template matches
THEN alert: "Template hash may have false positives, review patterns"
```

**Alert 2: Low cache hit rate**
```
IF (cache_hits / (cache_hits + cache_misses)) < 0.4 for >1 hour
THEN alert: "Cache hit rate below 40%, investigate message patterns"
```

**Alert 3: Template hash disabled**
```
IF cache_template_hash_enabled = false
THEN info: "Template hash disabled, personalized emails not cached"
```

---

## Rollback Plan

### Immediate Rollback (< 5 minutes)

**Disable problematic hash types via config:**

```bash
# Edit postal.yml or set env vars
docker exec install-worker-1 rails runner "
  # Disable just template hash if it's causing issues
  ENV['MESSAGE_INSPECTION__CACHE_TEMPLATE_HASH_ENABLED'] = 'false'
"

# Restart
docker-compose restart worker

# Or disable all caching
docker exec install-worker-1 rails runner "
  ENV['MESSAGE_INSPECTION__CACHE_ENABLED'] = 'false'
"
docker-compose restart worker
```

**No code revert needed** - feature flags handle disablement.

### Full Rollback (< 30 minutes)

**Revert code and migration:**

```bash
# Rollback migration
docker exec install-worker-1 rails db:rollback

# Revert code commit
cd /opt/postal/install
git revert <commit-hash>
docker-compose restart worker

# Verify
docker logs install-worker-1 --tail 50 | grep -i cache
```

**Data considerations:**
- Old cache entries still valid (only content_hash used by old code)
- No data loss
- New columns remain in DB but unused (safe)

---

## Success Criteria

### Phase 1: Implementation & Testing (Week 1)

- [ ] Migration runs successfully
- [ ] All unit tests pass (including new v2 tests)
- [ ] Performance tests show <15ms worst-case lookup
- [ ] Template regex does NOT match non-greeting capitalized words
- [ ] Sequential lookups use indexes (verified with EXPLAIN)
- [ ] Code review approved

### Phase 2: Staging Validation (Week 2)

- [ ] Deploy to staging
- [ ] Cache hit rate improvement:
  - Baseline (full hash only): 10-20%
  - Target (multi-hash): 60-80%
- [ ] Template hash false positive rate <2%
- [ ] No performance degradation (P99 latency <15ms)
- [ ] Monitor matched_via distribution

### Phase 3: Production Rollout (Week 3)

- [ ] Deploy to single production server
- [ ] Monitor for 48 hours:
  - Cache hit rate >60%
  - Template hash false positives <2%
  - No errors in logs
  - Query performance stable
- [ ] Deploy to all servers if successful
- [ ] Monitor for 7 days system-wide

### Phase 4: Optimization (Week 4+)

- [ ] Analyze matched_via distribution
- [ ] Tune template regex if needed
- [ ] Adjust spam_score threshold if needed
- [ ] Document patterns and findings

---

## Open Questions (RESOLVED)

### ✅ Q1: What order to check hashes?
**Answer:** Full → Attachment → Template (precision order)

### ✅ Q2: Is message_size needed for all hash types?
**Answer:** Yes (performance + selectivity)

### ✅ Q3: How aggressive should template normalization be?
**Answer:** Conservative (only greeting patterns, not all capitalized words)

### ✅ Q4: Should we cache threats?
**Answer:** No (keep existing security policy)

### ✅ Q5: What about multi-node cache stampede?
**Answer:** Acknowledged, use upsert, address in future if needed

---

## Timeline

### Week 1: Development & Testing
- Day 1-2: Implement revised hash computation methods
- Day 3-4: Update lookup/store logic with sequential checking
- Day 5: Write comprehensive tests, code review

### Week 2: Staging Validation
- Day 1: Deploy to staging
- Day 2-7: Monitor, collect metrics, validate no false positives

### Week 3: Production Rollout
- Day 1: Deploy to single production server
- Day 2-3: Monitor closely (hit rate, false positives, performance)
- Day 4: Deploy to all servers if metrics meet success criteria
- Day 5-7: Monitor system-wide

### Week 4+: Optimization & Documentation
- Analyze matched_via patterns
- Tune template regex if needed
- Adjust thresholds based on real data
- Document findings and best practices

---

## Summary

**What changed from v1:**
- ✅ Fixed OR query performance issue (sequential lookups)
- ✅ Fixed template regex over-matching (conservative patterns)
- ✅ Implemented lazy hash computation (performance)
- ✅ Added composite indexes (query optimization)
- ✅ Fixed attachment ordering (consistency)
- ✅ Added cache invalidation (operational safety)
- ✅ Added security mitigations (spam threshold, logging)
- ✅ Answered all design questions

**What we're building:**
Store 3 hash types per scan, check sequentially with lazy computation, first match wins.

**Why:**
Improve cache hit rate for personalized emails from ~0% to 60-80%.

**Risk level:**
Low - sequential lookups use indexes, conservative template matching, feature flags for safety.

**Effort:**
~2 weeks development + testing + rollout.

**Expected outcome:**
Personalized newsletters become cacheable without false positives.

---

## Next Steps

1. ✅ Technical review complete (issues addressed)
2. Get final approval from technical lead + security
3. Create implementation branch
4. Begin development following this v2 plan
5. Run comprehensive tests
6. Deploy to staging
7. Production rollout

**Status:** Ready for implementation ✅
