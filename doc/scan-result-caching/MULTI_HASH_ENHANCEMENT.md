# Multi-Hash Cache Enhancement Plan

**Date:** January 8, 2026  
**Status:** Proposal / Design Phase  
**Purpose:** Improve cache hit rates for personalized email content

---

## Executive Summary

The current scan result cache uses a single content hash (full message). This works well for identical messages but fails to cache personalized newsletters where recipients see different greetings/content but share the same attachments or message template.

**Proposed Solution:** Store multiple hash types (full message, attachments-only, body template) in the same cache entry. On lookup, check all hash types - if ANY match, it's a cache hit.

**Expected Impact:**
- Current: 0% cache hit for personalized newsletters (1000 messages = 1000 scans)
- With multi-hash: 90-99% cache hit for personalized newsletters (1000 messages = 1-10 scans)

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

### Concept: Multi-Hash Storage

Store **three hash types** for each scanned message:

1. **Full Message Hash** (existing)
   - SHA-256 of normalized full message
   - Use case: Non-personalized messages
   - Example: Plain newsletters, transactional emails

2. **Attachment Hash** (new)
   - SHA-256 of all attachment contents combined
   - Use case: Personalized text + same attachments
   - Example: "Hi John" vs "Hi Sarah" but same PDF

3. **Body Template Hash** (new)
   - SHA-256 of message with personalization stripped
   - Use case: Personalized greetings/content
   - Example: Remove names, emails, order IDs before hashing

### Lookup Strategy

Check all three hashes on every lookup:
```
IF full_message_hash matches → Cache HIT
ELSE IF attachment_hash matches → Cache HIT
ELSE IF body_template_hash matches → Cache HIT
ELSE → Cache MISS (perform scan)
```

**First match wins** - don't need to check all three if first one hits.

---

## Technical Design

### Database Schema Changes

**Add to existing `scan_result_cache` table:**

```sql
ALTER TABLE scan_result_cache 
  ADD COLUMN attachment_hash VARCHAR(64) DEFAULT NULL,
  ADD COLUMN body_template_hash VARCHAR(64) DEFAULT NULL,
  ADD INDEX idx_attachment_hash (attachment_hash),
  ADD INDEX idx_body_template_hash (body_template_hash);
```

**Complete schema:**
```sql
CREATE TABLE scan_result_cache (
  id BIGINT PRIMARY KEY AUTO_INCREMENT,
  
  -- Hash columns (3 ways to match)
  content_hash VARCHAR(64) NOT NULL,           -- Full message (existing)
  attachment_hash VARCHAR(64) DEFAULT NULL,    -- Attachments only (NEW)
  body_template_hash VARCHAR(64) DEFAULT NULL, -- Template pattern (NEW)
  
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
  
  -- Indexes
  UNIQUE INDEX idx_full_hash (content_hash, message_size),
  INDEX idx_attachment_hash (attachment_hash),
  INDEX idx_body_template_hash (body_template_hash),
  INDEX idx_scanned_at (scanned_at),
  INDEX idx_hit_count (hit_count)
);
```

**Storage Impact:**
- Current: ~500 bytes per row
- New: ~700 bytes per row (3 hashes instead of 1)
- 100K entries: 50MB → 70MB (+40% storage, still negligible)

### Hash Computation Logic

#### 1. Full Message Hash (existing, no changes)

```ruby
def compute_full_hash(raw_message)
  normalized = normalize_message(raw_message)
  Digest::SHA256.hexdigest(normalized)
end

def normalize_message(raw_message)
  # Remove recipient-specific headers (To, Cc, Message-ID, Date)
  # Keep: From, Subject, Body, Attachments
  # Current implementation unchanged
end
```

#### 2. Attachment Hash (new)

```ruby
def compute_attachment_hash(raw_message)
  mail = Mail.new(raw_message)
  
  # No attachments? Return nil (can't use this hash for matching)
  return nil if mail.attachments.empty?
  
  # Compute combined hash of all attachment contents
  attachment_data = mail.attachments.map do |att|
    "#{att.filename}:#{att.content_type}:#{att.body.decoded}"
  end.join("||")
  
  Digest::SHA256.hexdigest(attachment_data)
rescue => e
  Postal.logger.error "Failed to compute attachment hash: #{e.message}"
  nil
end
```

**Design decisions:**
- Include filename and content-type in hash (detect renamed files)
- Concatenate all attachments with separator (order matters)
- Return `nil` if no attachments (skip this hash type during lookup)
- Graceful failure: log error, return nil, proceed with other hashes

#### 3. Body Template Hash (new)

```ruby
def compute_body_template_hash(raw_message)
  mail = Mail.new(raw_message)
  body = mail.body.decoded rescue raw_message
  
  # Strip likely personalization patterns
  template_body = body.dup
    .gsub(/\b[A-Z][a-z]+\b/, '{{NAME}}')              # Capitalize words → placeholder
    .gsub(/\b[\w.+-]+@[\w.-]+\.\w+\b/, '{{EMAIL}}')   # Email addresses
    .gsub(/\b\d{3}-\d{3}-\d{4}\b/, '{{PHONE}}')       # Phone numbers
    .gsub(/\b\d{5,}\b/, '{{NUMBER}}')                 # Order IDs, zip codes, etc.
    .gsub(/\s+/, ' ')                                  # Normalize whitespace
    .strip
  
  # Hash the template
  Digest::SHA256.hexdigest(template_body)
rescue => e
  Postal.logger.error "Failed to compute template hash: #{e.message}"
  nil
end
```

**Design decisions:**
- Aggressive normalization (may have false positives)
- Start conservative, tune based on real data
- Return `nil` on failure (graceful degradation)
- Keep full message hash as fallback for precision

**Known limitations:**
- May normalize legitimate content (e.g., company name "John Deere")
- Won't catch all personalization styles
- Trade-off: some false matches vs higher cache hit rate

### Code Changes

#### File: `lib/postal/scan_cache_manager.rb`

```ruby
module Postal
  class ScanCacheManager
    class << self
      
      # Lookup with multi-hash checking
      def lookup(raw_message, message_size)
        # Compute all possible hashes
        full_hash = compute_full_hash(raw_message)
        attachment_hash = compute_attachment_hash(raw_message)
        template_hash = compute_body_template_hash(raw_message)
        
        # Build WHERE clause to check all non-nil hashes
        conditions = []
        values = []
        
        if full_hash
          conditions << "content_hash = ?"
          values << full_hash
        end
        
        if attachment_hash
          conditions << "attachment_hash = ?"
          values << attachment_hash
        end
        
        if template_hash
          conditions << "body_template_hash = ?"
          values << template_hash
        end
        
        return nil if conditions.empty?
        
        # Find cache entry matching ANY hash
        where_clause = "(#{conditions.join(' OR ')}) AND message_size = ?"
        values << message_size
        
        cache_entry = ::ScanResultCache.where(where_clause, *values).first
        return nil unless cache_entry
        
        # Check TTL
        ttl_days = Postal::Config.message_inspection.cache_ttl_days
        return nil unless cache_entry.valid_cache_entry?(ttl_days)
        
        # Log which hash type matched (for metrics)
        matched_type = if cache_entry.content_hash == full_hash
          "full"
        elsif cache_entry.attachment_hash == attachment_hash
          "attachment"
        elsif cache_entry.body_template_hash == template_hash
          "template"
        else
          "unknown"
        end
        
        Postal.logger.info "Cache HIT (#{matched_type}) for hash #{cache_entry.content_hash[0..7]}"
        
        cache_entry
      rescue StandardError => e
        Postal.logger.error "Cache lookup failed: #{e.class} #{e.message}"
        nil
      end
      
      # Store with all three hashes
      def store(raw_message, message_size, inspection_result)
        # Security policies (unchanged)
        return if inspection_result.threat
        return if inspection_result.spam_score > cache_threshold
        
        # Compute all hashes
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
        
        Postal.logger.info "Stored scan result with 3 hashes [full=#{full_hash[0..7]}]"
      rescue ActiveRecord::RecordNotUnique
        # Race condition: another thread cached this first
        Postal.logger.debug "Cache entry already exists"
      rescue StandardError => e
        # Never fail message processing due to cache errors
        Postal.logger.error "Failed to store in cache: #{e.class} #{e.message}"
      end
      
      # New hash computation methods
      def compute_attachment_hash(raw_message)
        # Implementation from above
      end
      
      def compute_body_template_hash(raw_message)
        # Implementation from above
      end
      
      # Existing methods unchanged
      def compute_full_hash(raw_message)
        # ... existing implementation ...
      end
      
      def normalize_message(raw_message)
        # ... existing implementation ...
      end
      
    end
  end
end
```

**Changes summary:**
- `lookup`: Check 3 hash columns instead of 1
- `store`: Compute and store 3 hashes instead of 1
- Add: `compute_attachment_hash` method
- Add: `compute_body_template_hash` method
- Unchanged: existing `compute_full_hash` and `normalize_message`

#### File: `app/models/scan_result_cache.rb`

No changes needed - model is generic enough to handle new columns.

#### File: `lib/postal/message_db/message.rb`

No changes needed - integration point unchanged.

---

## Migration Strategy

### Step 1: Database Migration

**File:** `db/migrate/20260108000000_add_multi_hash_to_scan_result_cache.rb`

```ruby
class AddMultiHashToScanResultCache < ActiveRecord::Migration[7.0]
  def up
    add_column :scan_result_cache, :attachment_hash, :string, limit: 64
    add_column :scan_result_cache, :body_template_hash, :string, limit: 64
    
    add_index :scan_result_cache, :attachment_hash, 
      name: 'idx_scan_cache_attachment_hash'
    add_index :scan_result_cache, :body_template_hash, 
      name: 'idx_scan_cache_template_hash'
  end
  
  def down
    remove_index :scan_result_cache, name: 'idx_scan_cache_template_hash'
    remove_index :scan_result_cache, name: 'idx_scan_cache_attachment_hash'
    remove_column :scan_result_cache, :body_template_hash
    remove_column :scan_result_cache, :attachment_hash
  end
end
```

**Execution:**
```bash
docker exec install-worker-1 rails db:migrate
```

**Expected impact:**
- Downtime: None (columns are nullable, add with default NULL)
- Existing cache entries: Still work (only content_hash is used)
- New code: Backwards compatible (checks all hash columns)

### Step 2: Code Deployment

**Deploy order:**
1. Run migration first (add columns)
2. Deploy new code second (use new columns)
3. Restart worker processes

**Backwards compatibility:**
- Old cache entries (no attachment/template hash): Still match on content_hash
- New cache entries: Can match on any of 3 hashes
- No data loss or cache invalidation needed

### Step 3: Backfill (Optional)

**Question:** Should we backfill existing cache entries with new hash types?

**Option A: No backfill (recommended)**
- Existing entries will age out naturally (7-day TTL)
- New scans will create entries with all 3 hashes
- Simpler, no risk

**Option B: Backfill in background**
```ruby
# Run once after deployment
ScanResultCache.where(attachment_hash: nil).find_each do |entry|
  # Would need to store original raw_message (we don't currently)
  # This is why Option A is recommended
end
```

**Recommendation:** Option A - let old entries expire naturally.

---

## Edge Cases & Risk Analysis

### Edge Case 1: Attachment Hash Collisions

**Scenario:** Two different messages with same attachments but very different text.

```
Message 1: "URGENT VIRUS ALERT [legit warning from IT]" + virus_scan.pdf
Message 2: "Click here to claim your prize!!!" [spam] + virus_scan.pdf
```

**Risk:** Message 2 matches Message 1's attachment hash → inherits spam score.

**Mitigation:**
- Attachment hash only used if no full hash match
- Spam scoring still considers subject/body differences
- Worst case: Slightly inaccurate spam score (better than no cache)
- Security policy: High spam scores not cached anyway

**Severity:** Low - unlikely scenario, minimal impact

### Edge Case 2: Template Hash False Positives

**Scenario:** Legitimate content gets normalized away.

```
Message 1: "John Deere tractors are on sale!"
Message 2: "{{NAME}} tractors are on sale!"
```

**Risk:** Different messages incorrectly match via template hash.

**Mitigation:**
- Template normalization is conservative (only obvious patterns)
- Full hash checked first (precision)
- Template hash is last resort (recall)
- Can tune regex patterns based on false positive rate

**Severity:** Low - template matching is best-effort, not required

### Edge Case 3: No Attachments + Heavy Personalization

**Scenario:** Plain text email with lots of personalization.

```
"Hi John, your order #12345 shipped to 123 Main St, Austin TX 78701"
"Hi Sarah, your order #67890 shipped to 456 Oak Ave, Boston MA 02101"
```

**Risk:** Template hash removes all unique content, false match.

**Mitigation:**
- Test with real customer data to tune normalization
- Can add config flag to disable template hashing if too aggressive
- Full hash still available for exact matches

**Severity:** Medium - needs monitoring and tuning

### Edge Case 4: Migration Failure

**Scenario:** Migration fails mid-execution on production database.

**Risk:** Table in inconsistent state, cache unusable.

**Mitigation:**
- Migration is additive only (no data changes)
- Columns are nullable (no NOT NULL constraints)
- If migration fails: rollback, fix issue, retry
- If columns partially added: code checks for column existence

**Rollback plan:**
```ruby
# Emergency rollback
docker exec install-worker-1 rails db:rollback
```

**Severity:** Low - standard migration risk, well-understood

### Edge Case 5: Performance Impact

**Scenario:** Computing 3 hashes takes too long, slows down message processing.

**Risk:** Cache becomes bottleneck instead of optimization.

**Mitigation:**
- Hash computation is fast: ~1-2ms for full message
- 3 hashes: ~3-6ms total (negligible vs 20-43s scan time)
- Benchmark before production deployment
- Can make template hash optional via config

**Performance test:**
```ruby
Benchmark.measure do
  1000.times { compute_all_hashes(sample_message) }
end
# Expected: < 5 seconds for 1000 messages = 5ms per message
```

**Severity:** Low - hashing is fast, much faster than scanning

---

## Testing Strategy

### Unit Tests

**File:** `spec/lib/postal/scan_cache_manager_spec.rb`

```ruby
describe "Multi-hash caching" do
  describe ".compute_attachment_hash" do
    it "returns nil for messages without attachments"
    it "computes same hash for identical attachments"
    it "computes different hash when attachment content changes"
    it "includes filename in hash"
    it "handles multiple attachments"
    it "handles malformed attachments gracefully"
  end
  
  describe ".compute_body_template_hash" do
    it "normalizes capitalized names"
    it "normalizes email addresses"
    it "normalizes phone numbers"
    it "normalizes numeric IDs"
    it "produces same hash for messages with different names"
    it "produces different hash for messages with different subjects"
  end
  
  describe ".lookup" do
    it "matches on full hash (highest priority)"
    it "matches on attachment hash when full hash misses"
    it "matches on template hash when attachment hash misses"
    it "returns nil when all hashes miss"
    it "respects TTL for all hash types"
    it "logs which hash type matched"
  end
  
  describe ".store" do
    it "stores all three hashes"
    it "stores nil for attachment hash when no attachments"
    it "handles template hash computation failures gracefully"
  end
end
```

### Integration Tests

**Scenario 1: Personalized newsletter**
```ruby
it "caches personalized newsletters via template hash" do
  # Send newsletter with personalization
  msg1 = create_message(body: "Hi John, check our sale!")
  msg2 = create_message(body: "Hi Sarah, check our sale!")
  
  # First scan
  result1 = msg1.inspect_message
  expect(ScanResultCache.count).to eq(1)
  
  # Second scan should hit template hash
  result2 = msg2.inspect_message
  expect(ScanResultCache.count).to eq(1)  # No new entry
  expect(result2).to be_cached
end
```

**Scenario 2: Newsletter with attachment**
```ruby
it "caches newsletters with attachments" do
  msg1 = create_message(
    body: "Hi John, see attachment",
    attachments: [pdf_file]
  )
  msg2 = create_message(
    body: "Hi Sarah, see attachment",
    attachments: [pdf_file]
  )
  
  result1 = msg1.inspect_message
  result2 = msg2.inspect_message
  
  expect(result2).to be_cached
  expect(result2.cached_via).to eq('attachment')
end
```

### Performance Tests

```ruby
describe "Performance" do
  it "computes hashes in < 10ms" do
    message = create_large_message(size: 5.megabytes)
    
    elapsed = Benchmark.realtime do
      ScanCacheManager.compute_full_hash(message)
      ScanCacheManager.compute_attachment_hash(message)
      ScanCacheManager.compute_body_template_hash(message)
    end
    
    expect(elapsed).to be < 0.01  # 10ms
  end
end
```

### Manual Testing Checklist

- [ ] Send plain newsletter (no personalization) → full hash match
- [ ] Send personalized newsletter (name in greeting) → template hash match
- [ ] Send newsletter with attachment + personalization → attachment hash match
- [ ] Send completely unique messages → no cache match, full scan
- [ ] Check logs show correct hash type matched
- [ ] Verify cache hit count increments
- [ ] Test with real customer data (anonymized)

---

## Monitoring & Metrics

### New Metrics to Track

**Cache hit breakdown by hash type:**
```ruby
# Prometheus metrics
postal_cache_hits_total{hash_type="full"}
postal_cache_hits_total{hash_type="attachment"}
postal_cache_hits_total{hash_type="template"}
postal_cache_misses_total
```

**Dashboard queries:**
```sql
-- Cache hit rate by hash type (last 24 hours)
SELECT 
  DATE_FORMAT(last_hit_at, '%Y-%m-%d %H:00') as hour,
  COUNT(CASE WHEN content_hash IS NOT NULL THEN 1 END) as full_hits,
  COUNT(CASE WHEN attachment_hash IS NOT NULL THEN 1 END) as attachment_hits,
  COUNT(CASE WHEN body_template_hash IS NOT NULL THEN 1 END) as template_hits
FROM scan_result_cache
WHERE last_hit_at > DATE_SUB(NOW(), INTERVAL 24 HOUR)
GROUP BY hour;

-- Most reused cache entries
SELECT 
  SUBSTRING(content_hash, 1, 8) as hash,
  hit_count,
  spam_score,
  CASE 
    WHEN attachment_hash IS NOT NULL THEN 'has_attachments'
    ELSE 'text_only'
  END as type,
  scanned_at
FROM scan_result_cache
ORDER BY hit_count DESC
LIMIT 20;
```

### Alerts

**Alert 1: Template hash false positive rate**
- Trigger: If template hash matches but spam scores differ by >2.0
- Action: Review template normalization patterns
- Threshold: >5% of template matches have score difference >2.0

**Alert 2: Low cache hit rate**
- Trigger: Overall cache hit rate <50% for >1 hour
- Action: Investigate message variability, check hash computation
- Threshold: (hits / (hits + misses)) < 0.5

---

## Rollback Plan

### Immediate Rollback (< 5 minutes)

If issues detected in production:

**Step 1: Revert code changes**
```bash
cd /opt/postal/install
git revert <commit-hash>
docker-compose restart worker
```

**Step 2: Verify**
```bash
docker logs install-worker-1 --tail 50 | grep -i cache
```

**Database:** No rollback needed - new columns remain but aren't used by old code.

### Full Rollback (< 30 minutes)

If database migration needs reversal:

```bash
# Rollback migration
docker exec install-worker-1 rails db:rollback

# Verify columns removed
docker exec install-worker-1 rails runner "
  puts ScanResultCache.column_names.inspect
"

# Restart services
cd /opt/postal/install
docker-compose restart
```

### Data Considerations

**Existing cache entries:**
- Old code: Only uses content_hash (no issue)
- New code: Uses all 3 hashes (backwards compatible)
- Rollback: Old entries still valid, new columns ignored

**No data loss:** Cache is performance optimization only, not critical data.

---

## Configuration Options

### New Config Settings (Optional)

Add to `config_schema.rb`:

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
  
  # NEW OPTIONS
  boolean :cache_attachment_hash_enabled do
    description "Enable attachment-based cache matching"
    default true
  end
  
  boolean :cache_template_hash_enabled do
    description "Enable template-based cache matching for personalized content"
    default true
  end
  
  float :template_hash_confidence_threshold do
    description "Minimum confidence for template hash matching (0.0-1.0)"
    default 0.95
  end
end
```

**Usage:**
```ruby
# Allow disabling specific hash types if they cause issues
def lookup(raw_message, size)
  hashes = [compute_full_hash(raw_message)]
  
  if Postal::Config.message_inspection.cache_attachment_hash_enabled
    hashes << compute_attachment_hash(raw_message)
  end
  
  if Postal::Config.message_inspection.cache_template_hash_enabled
    hashes << compute_body_template_hash(raw_message)
  end
  
  # ... lookup logic ...
end
```

---

## Success Criteria

### Phase 1: Implementation (Week 1)

- [ ] Migration runs successfully on test database
- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] Performance tests show <10ms overhead
- [ ] Code review approved

### Phase 2: Staging Validation (Week 2)

- [ ] Deploy to staging environment
- [ ] Run with real (anonymized) customer data
- [ ] Measure cache hit rate improvement:
  - Baseline (full hash only): 10-20%
  - Target (multi-hash): 70-90%
- [ ] No increase in false positives
- [ ] No performance degradation

### Phase 3: Production Rollout (Week 3)

- [ ] Deploy to single production server
- [ ] Monitor for 48 hours
- [ ] Cache hit rate >70%
- [ ] No errors in logs
- [ ] Deploy to all servers
- [ ] Monitor for 7 days

### Phase 4: Long-term Monitoring (Week 4+)

- [ ] Sustained cache hit rate >70%
- [ ] No increase in delivery incidents
- [ ] Template hash false positive rate <5%
- [ ] Customer satisfaction maintained/improved

---

## Open Questions

### Question 1: Template Normalization Aggressiveness

**Question:** How aggressive should template normalization be?

**Options:**
- **Conservative:** Only obvious patterns (names, emails) → lower false positives, lower cache hit rate
- **Aggressive:** Normalize more patterns (addresses, numbers) → higher cache hit rate, higher false positives

**Recommendation:** Start conservative, tune based on data. Add config option to adjust.

### Question 2: Hash Priority Order

**Question:** What order should we check hashes?

**Current proposal:** Full → Attachment → Template

**Alternative:** Full → Template → Attachment (template more common than attachments?)

**Recommendation:** Keep proposed order. Full hash is most precise, check first. Monitor which type hits most, adjust if needed.

### Question 3: Backfill Existing Entries?

**Question:** Should we compute new hashes for existing cache entries?

**Challenge:** We don't store raw_message, only the scan results.

**Options:**
- A: No backfill, let old entries expire (7 days)
- B: Store raw_message in future entries (increases storage 100x)
- C: Accept that old entries only match on full hash

**Recommendation:** Option A - clean slate approach, simpler.

### Question 4: Should we cache threats?

**Current behavior:** Threats (viruses) are NOT cached (security policy).

**Question with multi-hash:** If attachment has virus, should we cache that attachment hash?

**Pros:** 
- If virus in attachment, block all messages with that attachment fast
- Reduces load on ClamAV

**Cons:**
- Virus signatures update frequently
- False negatives more dangerous than false positives
- Current 7-day TTL too long for threats

**Recommendation:** 
- Keep current policy: don't cache threats
- Consider separate "threat cache" with shorter TTL (1 hour) in future

---

## Timeline

### Week 1: Development & Testing
- Day 1-2: Implement hash computation methods
- Day 3-4: Update lookup/store logic
- Day 5: Write tests, code review

### Week 2: Staging Validation
- Day 1: Deploy to staging
- Day 2-7: Monitor, collect metrics, tune if needed

### Week 3: Production Rollout
- Day 1: Deploy to single production server
- Day 2-3: Monitor closely
- Day 4: Deploy to all servers if successful
- Day 5-7: Monitor system-wide

### Week 4+: Optimization
- Analyze cache hit patterns
- Tune template normalization
- Adjust configuration based on real usage
- Document findings

---

## Appendix: Example Test Cases

### Test Case 1: Plain Newsletter

**Input:**
```
From: news@company.com
To: user@example.com
Subject: Weekly Update

Check out our new features!
```

**Expected:**
- Full hash: abc123...
- Attachment hash: nil
- Template hash: def456...

**Cache behavior:**
- Message 1: MISS → scan and store
- Message 2 (identical): HIT via full hash
- Message 3 (different recipient): HIT via full hash

### Test Case 2: Personalized Newsletter

**Input:**
```
From: news@company.com
To: john@example.com
Subject: Weekly Update

Hi John,
Check out our new features!
```

**Expected:**
- Full hash: abc123... (unique due to "John")
- Attachment hash: nil
- Template hash: def456... (same as Test Case 1 after normalization)

**Cache behavior:**
- Message 1: MISS → scan and store
- Message 2 (same, different name): MISS on full hash → HIT on template hash
- Message 3 (different name): HIT on template hash

### Test Case 3: Newsletter with PDF

**Input:**
```
From: news@company.com
To: john@example.com
Subject: Weekly Update

Hi John,
See attached whitepaper.

Attachment: whitepaper.pdf (2MB)
```

**Expected:**
- Full hash: abc123... (unique due to "John")
- Attachment hash: xyz789... (based on PDF content)
- Template hash: def456...

**Cache behavior:**
- Message 1: MISS → scan and store
- Message 2 (same PDF, different name): MISS on full → HIT on attachment hash
- Message 3 (same text, different PDF): MISS on full → MISS on attachment → HIT on template

### Test Case 4: High Spam Score

**Input:**
```
From: spam@spam.com
Subject: URGENT CLAIM YOUR PRIZE NOW!!!

CLICK HERE TO CLAIM $1,000,000
```

**Expected:**
- Spam score: 15.0 (above threshold of 4.0)
- Result: NOT CACHED (security policy)

**Cache behavior:**
- Every message scanned fresh (no caching of high spam)

---

## Summary

**What we're building:**
Store 3 hash types per scan, check all 3 on lookup, first match wins.

**Why:**
Improve cache hit rate for personalized emails from ~0% to 70-90%.

**Risk level:**
Low - additive change, backwards compatible, easy rollback.

**Effort:**
~2 weeks development + testing + rollout.

**Expected outcome:**
Personalized newsletters become cacheable, preventing thread pool exhaustion.

---

**Next Steps:**
1. Review this plan with team
2. Get approval from technical lead + security
3. Create implementation tasks
4. Begin development

**Questions/Feedback:**
[Add comments here]

