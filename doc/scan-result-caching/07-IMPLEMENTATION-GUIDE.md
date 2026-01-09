# 07 - IMPLEMENTATION GUIDE

**Project:** Hash-Based Scan Result Caching  
**Document Version:** 1.0  
**Last Updated:** December 31, 2025

---

## Implementation Checklist

### Phase 1: Database Setup

- [ ] Create migration file: `db/migrate/YYYYMMDDHHMMSS_create_scan_result_cache.rb`
- [ ] Run migration in development: `rake db:migrate`
- [ ] Run migration in staging: `rake db:migrate RAILS_ENV=staging`
- [ ] Verify table created: `SHOW CREATE TABLE scan_result_cache;`
- [ ] Verify indexes created: `SHOW INDEXES FROM scan_result_cache;`

### Phase 2: Core Implementation

- [ ] Create `lib/postal/scan_result_cache.rb`
- [ ] Create `lib/postal/cached_scan_result.rb`
- [ ] Modify `lib/postal/message_db/message.rb`
- [ ] Update `lib/postal/config_schema.rb`
- [ ] Add configuration to `config/postal.yml.example`

### Phase 3: Testing

- [ ] Unit tests for hash computation (>80% coverage)
- [ ] Unit tests for cache lookup/store
- [ ] Integration tests for cache hit/miss flows
- [ ] Security tests (threat caching prevention)
- [ ] Performance benchmarks

### Phase 4: Documentation

- [ ] Inline code documentation (YARD format)
- [ ] Update CHANGELOG.md
- [ ] Update README.md (mention cache feature)
- [ ] Operational runbooks

### Phase 5: Deployment

- [ ] Code review approved
- [ ] Security review approved
- [ ] Merge to main branch
- [ ] Deploy to staging
- [ ] Validate in staging
- [ ] Deploy to production (phased rollout)

---

## Code Implementation

### File 1: Database Migration

**Path:** `db/migrate/20250101120000_create_scan_result_cache.rb`

```ruby
class CreateScanResultCache < ActiveRecord::Migration[7.1]
  def up
    create_table :scan_result_cache do |t|
      # Cache key
      t.string :content_hash, limit: 64, null: false
      
      # Scan results
      t.decimal :spam_score, precision: 8, scale: 2, null: false, default: 0.00
      t.boolean :threat, null: false, default: false
      t.string :threat_details, limit: 255
      t.json :spam_checks, null: false
      
      # Metadata
      t.integer :message_size, null: false
      t.decimal :scan_timestamp, precision: 18, scale: 6, null: false
      t.string :scanner_version, limit: 50
      
      # Usage tracking
      t.integer :hit_count, null: false, default: 1
      t.decimal :last_hit_timestamp, precision: 18, scale: 6
      
      # Timestamps
      t.timestamps
    end
    
    # Indexes
    add_index :scan_result_cache, :content_hash, unique: true, name: 'idx_content_hash'
    add_index :scan_result_cache, :scan_timestamp, name: 'idx_scan_timestamp'
    add_index :scan_result_cache, :hit_count, name: 'idx_hit_count'
    add_index :scan_result_cache, :message_size, name: 'idx_message_size'
    
    # Composite index for LRU eviction
    execute <<-SQL
      CREATE INDEX idx_last_hit ON scan_result_cache 
      (COALESCE(last_hit_timestamp, scan_timestamp))
    SQL
  end
  
  def down
    drop_table :scan_result_cache
  end
end
```

### File 2: ScanResultCache Class

**Path:** `lib/postal/scan_result_cache.rb`

```ruby
module Postal
  class ScanResultCache
    class << self
      # Lookup cached scan result by content hash
      #
      # @param content_hash [String] SHA-256 hex digest
      # @param message_size [Integer, nil] Optional size verification
      # @return [CachedScanResult, nil]
      def lookup(content_hash, message_size = nil)
        query = "SELECT * FROM scan_result_cache WHERE content_hash = ? LIMIT 1"
        row = database.select_one(query, content_hash)
        
        return nil unless row
        
        # Defensive: Verify size matches (collision detection)
        if message_size && row['message_size'].to_i != message_size
          Rails.logger.critical(
            "[Cache] COLLISION DETECTED: hash=#{content_hash} " \
            "sizes=(#{message_size} vs #{row['message_size']})"
          )
          return nil
        end
        
        cached = CachedScanResult.new(row)
        
        # Check freshness (TTL and signature version)
        return nil unless cached.fresh?
        
        cached
      end
      
      # Store scan result in cache
      #
      # @param content_hash [String] SHA-256 hex digest
      # @param inspection_result [MessageInspectionResult]
      # @param message_size [Integer]
      # @return [Boolean] Success
      def store(content_hash, inspection_result, message_size)
        # Serialize spam checks to JSON
        spam_checks_json = inspection_result.spam_checks.map do |check|
          {
            code: check.code,
            score: check.score,
            description: check.description
          }
        end.to_json
        
        # Check cache size and evict if needed
        evict_lru if should_evict?
        
        # Insert or update (ON DUPLICATE KEY UPDATE for hit_count)
        query = <<-SQL
          INSERT INTO scan_result_cache
            (content_hash, spam_score, threat, threat_details, spam_checks,
             message_size, scan_timestamp, scanner_version, hit_count, last_hit_timestamp)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, NULL)
          ON DUPLICATE KEY UPDATE
            hit_count = hit_count + 1,
            last_hit_timestamp = VALUES(scan_timestamp)
        SQL
        
        database.query(
          query,
          content_hash,
          inspection_result.spam_score,
          inspection_result.threat,
          inspection_result.threat_message,
          spam_checks_json,
          message_size,
          Time.now.to_f,
          scanner_version
        )
        
        true
      rescue => e
        Rails.logger.error "[Cache] Store failed: #{e.message}"
        false
      end
      
      # Remove expired cache entries (run daily)
      #
      # @return [Integer] Number of entries deleted
      def cleanup_expired
        ttl = Postal::Config.scan_cache.ttl.to_f
        cutoff = Time.now.to_f - ttl
        
        deleted = database.query(
          "DELETE FROM scan_result_cache WHERE scan_timestamp < ?",
          cutoff
        )
        
        Rails.logger.info "[Cache] Cleaned up #{deleted} expired entries"
        deleted
      end
      
      # Invalidate entire cache (signature update hook)
      #
      # @return [Integer] Number of entries deleted
      def invalidate_all
        deleted = database.query("TRUNCATE TABLE scan_result_cache")
        Rails.logger.warn "[Cache] Invalidated all entries (#{deleted} total)"
        deleted
      end
      
      # Evict least recently used entries
      #
      # @return [Integer] Number of entries evicted
      def evict_lru
        max_entries = Postal::Config.scan_cache.max_cache_entries
        current_count = database.select_value("SELECT COUNT(*) FROM scan_result_cache").to_i
        
        return 0 if current_count < max_entries
        
        # Evict oldest 10%
        evict_count = (max_entries * 0.1).to_i
        
        # Find cutoff timestamp
        cutoff_query = <<-SQL
          SELECT COALESCE(last_hit_timestamp, scan_timestamp) AS access_time
          FROM scan_result_cache
          ORDER BY access_time ASC
          LIMIT 1 OFFSET ?
        SQL
        cutoff = database.select_value(cutoff_query, evict_count)
        
        # Delete oldest entries
        deleted = database.query(
          "DELETE FROM scan_result_cache WHERE COALESCE(last_hit_timestamp, scan_timestamp) <= ?",
          cutoff
        )
        
        Rails.logger.info "[Cache] Evicted #{deleted} LRU entries"
        deleted
      end
      
      # Cache statistics for monitoring
      #
      # @return [Hash] Statistics
      def statistics
        stats_query = <<-SQL
          SELECT
            COUNT(*) as total_entries,
            SUM(hit_count) as total_hits,
            AVG(message_size) as avg_message_size,
            SUM(LENGTH(spam_checks)) as total_json_bytes
          FROM scan_result_cache
        SQL
        
        stats = database.select_one(stats_query)
        
        {
          total_entries: stats['total_entries'].to_i,
          total_hits: stats['total_hits'].to_i,
          avg_message_size: stats['avg_message_size'].to_f.round(2),
          cache_size_bytes: stats['total_json_bytes'].to_i
        }
      end
      
      private
      
      def database
        Postal::DB.main_db
      end
      
      def should_evict?
        count = database.select_value("SELECT COUNT(*) FROM scan_result_cache").to_i
        count >= Postal::Config.scan_cache.max_cache_entries
      end
      
      def scanner_version
        # Future: Track SpamAssassin/ClamAV version for invalidation
        nil
      end
    end
  end
end
```

### File 3: CachedScanResult Class

**Path:** `lib/postal/cached_scan_result.rb`

```ruby
module Postal
  class CachedScanResult
    attr_reader :spam_score, :threat, :threat_details, :spam_checks, 
                :scan_timestamp, :hit_count, :content_hash
    
    def initialize(db_row)
      @content_hash = db_row['content_hash']
      @spam_score = db_row['spam_score'].to_f
      @threat = db_row['threat'] == 1 || db_row['threat'] == true
      @threat_details = db_row['threat_details']
      @spam_checks = JSON.parse(db_row['spam_checks'] || '[]')
      @scan_timestamp = db_row['scan_timestamp'].to_f
      @hit_count = db_row['hit_count'].to_i
      @scanner_version = db_row['scanner_version']
    end
    
    # Check if cache entry is still fresh
    #
    # @return [Boolean]
    def fresh?
      # Check age against TTL
      age = Time.now.to_f - scan_timestamp
      return false if age > Postal::Config.scan_cache.ttl
      
      # Future: Check scanner version matches current
      # if Postal::Config.scan_cache.track_signatures
      #   return false if @scanner_version != SignatureTracker.current_version
      # end
      
      true
    end
    
    # Record cache hit (update hit_count and last_hit_timestamp)
    #
    # @return [Boolean]
    def record_hit
      query = <<-SQL
        UPDATE scan_result_cache
        SET hit_count = hit_count + 1,
            last_hit_timestamp = ?
        WHERE content_hash = ?
      SQL
      
      Postal::DB.main_db.query(query, Time.now.to_f, content_hash)
      true
    rescue => e
      Rails.logger.error "[Cache] Failed to record hit: #{e.message}"
      false
    end
  end
end
```

### File 4: Message Modifications

**Path:** `lib/postal/message_db/message.rb` (modifications)

```ruby
# Add to existing Message class

def inspect_message
  return if inspected  # Already scanned (per-message cache)
  
  # Check content-based cache if enabled
  if should_use_scan_cache?
    cache_key = compute_cache_key
    cached = ScanResultCache.lookup(cache_key, size)
    
    if cached && cached.fresh?
      Rails.logger.info(
        "[Cache HIT] message_id=#{id} server_id=#{server_id} " \
        "hash=#{cache_key[0..8]} age=#{Time.now.to_f - cached.scan_timestamp}s"
      )
      restore_from_cache(cached)
      return MessageInspectionResult.from_cache(cached)
    end
    
    Rails.logger.info(
      "[Cache MISS] message_id=#{id} server_id=#{server_id} hash=#{cache_key[0..8]}"
    )
  end
  
  # Perform actual scan
  result = MessageInspection.scan(self, scope&.to_sym)
  
  # Update the messages table with results
  update(
    inspected: true,
    spam_score: result.spam_score,
    threat: result.threat,
    threat_details: result.threat_message
  )
  
  # Store spam_checks
  database.insert_multi(
    :spam_checks,
    [:message_id, :code, :score, :description],
    result.spam_checks.map { |d| [id, d.code, d.score, d.description] }
  )
  
  # Store in cache if appropriate
  if should_use_scan_cache? && should_cache_result?(result)
    ScanResultCache.store(cache_key, result, size)
  end
  
  result
end

private

# Check if scan cache should be used
#
# @return [Boolean]
def should_use_scan_cache?
  return false unless Postal::Config.scan_cache.enabled
  return false unless server.scan_cache_enabled
  return false if size < Postal::Config.scan_cache.min_message_size
  true
end

# Check if scan result should be cached
#
# @param result [MessageInspectionResult]
# @return [Boolean]
def should_cache_result?(result)
  # Never cache threats
  return false if result.threat
  
  # Don't cache near-spam (within 20% of threshold)
  if server.spam_threshold
    threshold = server.spam_threshold * 0.8
    return false if result.spam_score >= threshold
  end
  
  true
end

# Compute cache key for this message
#
# @return [String] SHA-256 hex digest
def compute_cache_key
  @cache_key ||= Digest::SHA256.hexdigest(normalized_raw_message)
end

# Generate normalized version of message for caching
#
# @return [String] Normalized raw message
def normalized_raw_message
  mail_obj = Mail.new(raw_message)
  
  # Normalize recipient headers
  mail_obj.to = "NORMALIZED@CACHE.LOCAL" if Postal::Config.scan_cache.normalize_recipients
  mail_obj.cc = nil
  
  # Remove message-specific tracking headers
  mail_obj['X-Postal-MsgID'] = nil
  mail_obj['X-Postal-Timestamp'] = nil
  
  # Reconstruct normalized message
  mail_obj.to_s
end

# Restore message data from cached scan result
#
# @param cached [CachedScanResult]
# @return [void]
def restore_from_cache(cached)
  # Update message record
  update(
    inspected: true,
    spam_score: cached.spam_score,
    threat: cached.threat,
    threat_details: cached.threat_details
  )
  
  # Restore spam_checks
  database.insert_multi(
    :spam_checks,
    [:message_id, :code, :score, :description],
    cached.spam_checks.map { |c| [id, c['code'], c['score'], c['description']] }
  )
  
  # Record cache hit
  cached.record_hit
end
```

### File 5: Configuration Schema

**Path:** `lib/postal/config_schema.rb` (add to existing file)

```ruby
# Add after existing scanner configurations (~line 490)

config.scan_cache = config.enable_struct do |c|
  c.enabled = config.boolean(default: false)
  c.ttl = config.integer(default: 604800)  # 7 days in seconds
  c.min_message_size = config.integer(default: 102400)  # 100 KB
  c.max_cache_entries = config.integer(default: 100000)
  c.normalize_recipients = config.boolean(default: true)
  c.track_signatures = config.boolean(default: false)
  c.logging_mode = config.boolean(default: false)  # POC mode
end
```

### File 6: Configuration Example

**Path:** `config/postal.yml.example` (add new section)

```yaml
# Scan Result Caching (Performance Optimization)
# 
# Caches spam/virus scan results by content hash to avoid re-scanning
# identical newsletter content sent to multiple recipients.
#
scan_cache:
  # Master feature flag
  enabled: false
  
  # Cache entry lifetime (seconds)
  # Default: 604800 (7 days)
  ttl: 604800
  
  # Minimum message size to cache (bytes)
  # Small messages (<100KB) typically aren't newsletters
  # Default: 102400 (100 KB)
  min_message_size: 102400
  
  # Maximum cache entries before LRU eviction
  # Default: 100000
  max_cache_entries: 100000
  
  # Normalize recipient headers before hashing
  # Enables cache hits for newsletters with different recipients
  # Default: true
  normalize_recipients: true
  
  # Track scanner versions for cache invalidation
  # Requires signature update integration
  # Default: false
  track_signatures: false
```

---

## Testing Implementation

### Unit Test Example

**Path:** `spec/lib/postal/scan_result_cache_spec.rb`

```ruby
require 'rails_helper'

RSpec.describe Postal::ScanResultCache do
  describe '.lookup' do
    it 'returns nil for cache miss' do
      expect(described_class.lookup('nonexistent')).to be_nil
    end
    
    it 'returns CachedScanResult for cache hit' do
      # Setup: Store a test entry
      result = build_inspection_result(spam_score: 2.5, threat: false)
      described_class.store('abc123', result, 5000)
      
      # Test: Lookup
      cached = described_class.lookup('abc123')
      expect(cached).to be_a(Postal::CachedScanResult)
      expect(cached.spam_score).to eq(2.5)
    end
    
    it 'returns nil for expired entries' do
      # Create entry with old timestamp
      create_cache_entry(
        content_hash: 'old123',
        scan_timestamp: 10.days.ago.to_f
      )
      
      expect(described_class.lookup('old123')).to be_nil
    end
    
    it 'detects hash collision by size mismatch' do
      result = build_inspection_result
      described_class.store('abc123', result, 5000)
      
      # Lookup with different size
      expect(Rails.logger).to receive(:critical).with(/COLLISION/)
      expect(described_class.lookup('abc123', 6000)).to be_nil
    end
  end
  
  describe '.store' do
    it 'creates new cache entry' do
      result = build_inspection_result(spam_score: 3.2, threat: false)
      
      expect {
        described_class.store('new_hash', result, 10000)
      }.to change { cache_entry_count }.by(1)
    end
    
    it 'increments hit_count on duplicate' do
      result = build_inspection_result
      described_class.store('dup_hash', result, 5000)
      
      expect {
        described_class.store('dup_hash', result, 5000)
      }.to change {
        cache_entry('dup_hash').hit_count
      }.by(1)
    end
  end
end
```

---

## Deployment Checklist

### Pre-Deployment

- [ ] All tests passing (unit + integration)
- [ ] Code coverage >80%
- [ ] Code review approved by senior engineer
- [ ] Security review approved
- [ ] Documentation complete
- [ ] Staging validation complete

### Deployment Steps

1. **Merge to main**
   ```bash
   git checkout main
   git pull origin main
   git merge feature/scan-caching
   git push origin main
   ```

2. **Deploy to staging**
   ```bash
   cap staging deploy
   # Or manual: ssh + git pull + restart
   ```

3. **Run migration**
   ```bash
   ssh postal@staging
   cd /opt/postal
   bundle exec rake db:migrate RAILS_ENV=staging
   ```

4. **Enable feature flag (POC mode)**
   ```yaml
   # config/postal.yml
   scan_cache:
     enabled: false  # Start with logging only
     logging_mode: true
   ```

5. **Restart workers**
   ```bash
   sudo systemctl restart postal-workers
   ```

6. **Validate**
   ```bash
   tail -f /var/log/postal/postal.log | grep CACHE
   # Should see: [CACHE_POC] logs
   ```

### Post-Deployment

- [ ] Monitor logs for errors
- [ ] Validate cache table created
- [ ] Run POC analysis
- [ ] Document any issues
- [ ] Proceed to Stage 1 rollout

---

## Change Log

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-31 | OpenCode AI | Initial draft |

---

## End of Design Documentation

**All documents complete:**
- [00-INDEX.md](00-INDEX.md) - Navigation
- [01-PROJECT-OVERVIEW.md](01-PROJECT-OVERVIEW.md) - Business case
- [02-TECHNICAL-DESIGN.md](02-TECHNICAL-DESIGN.md) - Architecture
- [03-SECURITY-ANALYSIS.md](03-SECURITY-ANALYSIS.md) - Threat model
- [04-TESTING-STRATEGY.md](04-TESTING-STRATEGY.md) - Test plans
- [05-DEPLOYMENT-PLAN.md](05-DEPLOYMENT-PLAN.md) - Rollout strategy
- [06-MONITORING-OPERATIONS.md](06-MONITORING-OPERATIONS.md) - Operations
- [07-IMPLEMENTATION-GUIDE.md](07-IMPLEMENTATION-GUIDE.md) - Code guide

**Ready for project kickoff!**
