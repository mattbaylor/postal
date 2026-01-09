# 02 - TECHNICAL DESIGN

**Project:** Hash-Based Scan Result Caching for Postal Email Service  
**Document Version:** 1.0  
**Last Updated:** December 31, 2025  
**Status:** Draft - Pending Review

---

## Table of Contents
- [Architecture Overview](#architecture-overview)
- [Component Design](#component-design)
- [Database Schema](#database-schema)
- [Algorithm Specification](#algorithm-specification)
- [Code Integration Points](#code-integration-points)
- [Configuration Management](#configuration-management)
- [Data Flow](#data-flow)
- [Performance Considerations](#performance-considerations)
- [Scalability](#scalability)

---

## Architecture Overview

### System Context

```
┌─────────────────────────────────────────────────────────────┐
│                     Postal Email System                      │
│                                                              │
│  ┌──────────┐      ┌───────────────┐      ┌──────────────┐│
│  │ Message  │──────▶│Message        │──────▶│ SpamAssassin ││
│  │ Queue    │      │Inspection     │      │ / ClamAV     ││
│  └──────────┘      │  (MODIFIED)   │      └──────────────┘│
│                     │               │                       │
│                     │   ┌─────────┐ │                       │
│                     │   │  Cache  │ │      ┌──────────────┐│
│                     │   │  Layer  │ │──────▶│   MySQL      ││
│                     │   │  (NEW)  │ │      │ scan_result  ││
│                     │   └─────────┘ │      │ _cache table ││
│                     └───────────────┘      └──────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### High-Level Design

**Cache-Aside Pattern:**
1. Message arrives in queue
2. Worker thread picks up message
3. **Check cache** for content hash
4. **If HIT:** Restore cached scan results, skip scanner calls
5. **If MISS:** Call scanners, store results in cache
6. Continue with message delivery

**Key Design Decisions:**

| Decision | Rationale |
|----------|-----------|
| Cache-aside (not write-through) | Simplifies implementation, natural fit for inspection flow |
| MySQL storage (not Redis) | Leverage existing database, audit trail, persistence |
| SHA-256 hashing | Industry standard, negligible collision risk |
| Global cache (not per-server) | Maximize hit rate across all organizations |
| 7-day TTL | Balance security (signature updates) vs performance |
| Recipient normalization | Newsletter use case (same body, different To:) |

---

## Component Design

### Component Diagram

```
┌────────────────────────────────────────────────────────────────┐
│ lib/postal/message_db/message.rb                               │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ inspect_message (MODIFIED)                                │ │
│  │  1. compute_cache_key                                     │ │
│  │  2. ScanResultCache.lookup(key) ──────────┐              │ │
│  │  3. If cache hit:                          │              │ │
│  │     - Restore cached results               │              │ │
│  │     - Record cache hit metric              │              │ │
│  │     - Return early                         │              │ │
│  │  4. If cache miss:                         │              │ │
│  │     - Call MessageInspection.scan          │              │ │
│  │     - Store in cache                       │              │ │
│  │                                             │              │ │
│  │  compute_cache_key (NEW)                   │              │ │
│  │  - normalize_raw_message                   │              │ │
│  │  - SHA256(normalized)                      │              │ │
│  └────────────────────────────────────────────┼──────────────┘ │
└─────────────────────────────────────────────────┼────────────────┘
                                                   │
                    ┌──────────────────────────────┘
                    ▼
┌────────────────────────────────────────────────────────────────┐
│ lib/postal/scan_result_cache.rb (NEW)                          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ ScanResultCache (Class)                                   │ │
│  │                                                            │ │
│  │  .lookup(content_hash) → CachedScanResult | nil           │ │
│  │    - Query scan_result_cache table                        │ │
│  │    - Check freshness (TTL, signature updates)             │ │
│  │    - Return CachedScanResult or nil                       │ │
│  │                                                            │ │
│  │  .store(content_hash, inspection_result, message_size)    │ │
│  │    - Serialize scan results to JSON                       │ │
│  │    - INSERT or UPDATE cache entry                         │ │
│  │    - Increment hit_count                                  │ │
│  │                                                            │ │
│  │  .cleanup_expired                                         │ │
│  │    - DELETE entries older than TTL                        │ │
│  │    - Run via scheduled job (daily)                        │ │
│  │                                                            │ │
│  │  .invalidate_all                                          │ │
│  │    - TRUNCATE cache (signature update hook)               │ │
│  │                                                            │ │
│  │  .evict_lru                                               │ │
│  │    - DELETE oldest 10% when size limit reached            │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ CachedScanResult (Class)                                  │ │
│  │  - spam_score: Float                                      │ │
│  │  - threat: Boolean                                        │ │
│  │  - threat_details: String                                 │ │
│  │  - spam_checks: Array<Hash>                               │ │
│  │  - scan_timestamp: Time                                   │ │
│  │  - fresh?: Boolean (check TTL)                            │ │
│  │  - record_hit: Update hit_count, last_hit_timestamp       │ │
│  └──────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

### Component: ScanResultCache

**Responsibilities:**
- Query cache by content hash
- Store scan results with metadata
- Enforce TTL and eviction policies
- Provide cache statistics

**Interface:**
```ruby
module Postal
  class ScanResultCache
    # Lookup cached scan result
    # @param content_hash [String] SHA-256 hex digest
    # @param message_size [Integer] Optional size check
    # @return [CachedScanResult, nil]
    def self.lookup(content_hash, message_size = nil)
    
    # Store scan result in cache
    # @param content_hash [String] SHA-256 hex digest
    # @param inspection_result [MessageInspectionResult]
    # @param message_size [Integer]
    # @return [Boolean] Success
    def self.store(content_hash, inspection_result, message_size)
    
    # Cleanup expired entries (run daily)
    # @return [Integer] Number of entries deleted
    def self.cleanup_expired
    
    # Invalidate entire cache (signature updates)
    # @return [Integer] Number of entries deleted
    def self.invalidate_all
    
    # LRU eviction when size limit reached
    # @return [Integer] Number of entries evicted
    def self.evict_lru
    
    # Cache statistics for monitoring
    # @return [Hash] {total_entries, total_hits, hit_rate, avg_size}
    def self.statistics
  end
end
```

### Component: Message.inspect_message (Modified)

**Current Flow:**
```ruby
def inspect_message
  return if inspected  # Already scanned
  
  result = MessageInspection.scan(self, scope)
  update(inspected: true, spam_score: result.spam_score, ...)
  # Store spam_checks
  result
end
```

**New Flow with Caching:**
```ruby
def inspect_message
  return if inspected  # Already scanned (per-message cache)
  
  # NEW: Check content-based cache
  if Postal::Config.scan_cache.enabled && should_use_cache?
    cache_key = compute_cache_key
    cached = ScanResultCache.lookup(cache_key, size)
    
    if cached && cached.fresh?
      Rails.logger.info "[Cache HIT] message_id=#{id} hash=#{cache_key[0..8]}"
      restore_from_cache(cached)
      return MessageInspectionResult.from_cache(cached)
    end
    
    Rails.logger.info "[Cache MISS] message_id=#{id} hash=#{cache_key[0..8]}"
  end
  
  # Perform actual scan
  result = MessageInspection.scan(self, scope)
  update(inspected: true, spam_score: result.spam_score, ...)
  # Store spam_checks
  
  # NEW: Store in cache if enabled
  if Postal::Config.scan_cache.enabled && should_cache_result?(result)
    ScanResultCache.store(cache_key, result, size)
  end
  
  result
end

private

def should_use_cache?
  size >= Postal::Config.scan_cache.min_message_size &&
    server.scan_cache_enabled  # Per-server opt-in
end

def should_cache_result?(result)
  !result.threat &&  # Never cache threats
    result.spam_score < (server.spam_threshold * 0.8)  # Don't cache near-spam
end

def compute_cache_key
  @cache_key ||= Digest::SHA256.hexdigest(normalized_raw_message)
end

def normalized_raw_message
  mail_obj = Mail.new(raw_message)
  
  # Normalize recipient headers
  mail_obj.to = "NORMALIZED@CACHE.LOCAL"
  mail_obj.cc = nil
  mail_obj['X-Postal-MsgID'] = nil
  
  mail_obj.to_s
end

def restore_from_cache(cached)
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
  
  cached.record_hit
end
```

---

## Database Schema

### New Table: scan_result_cache

```sql
CREATE TABLE scan_result_cache (
  id INT AUTO_INCREMENT PRIMARY KEY,
  
  -- Cache key (SHA-256 of normalized message)
  content_hash VARCHAR(64) NOT NULL,
  
  -- Scan results
  spam_score DECIMAL(8,2) NOT NULL DEFAULT 0.00,
  threat BOOLEAN NOT NULL DEFAULT FALSE,
  threat_details VARCHAR(255) DEFAULT NULL,
  spam_checks JSON NOT NULL,  -- [{code, score, description}, ...]
  
  -- Metadata
  message_size INT NOT NULL,
  scan_timestamp DECIMAL(18,6) NOT NULL,  -- Unix timestamp with microseconds
  scanner_version VARCHAR(50) DEFAULT NULL,  -- For invalidation tracking
  
  -- Usage tracking
  hit_count INT NOT NULL DEFAULT 1,
  last_hit_timestamp DECIMAL(18,6) DEFAULT NULL,
  
  -- Timestamps
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  
  -- Indexes
  UNIQUE KEY idx_content_hash (content_hash),
  KEY idx_scan_timestamp (scan_timestamp),
  KEY idx_last_hit (COALESCE(last_hit_timestamp, scan_timestamp)),
  KEY idx_hit_count (hit_count),
  KEY idx_message_size (message_size)
  
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

### Schema Design Rationale

**Why JSON for spam_checks?**
- SpamAssassin returns variable number of rules triggered (0-50+)
- Storing as JSON avoids separate join table
- Easier to serialize/deserialize
- Query performance not critical (cache lookups don't filter by spam_checks)

**Why DECIMAL(18,6) for timestamps?**
- Matches Postal's existing timestamp format
- Microsecond precision for accurate TTL enforcement
- Compatible with Ruby's `Time.now.to_f`

**Why track hit_count?**
- Metrics: Identify highly duplicated content
- Eviction: LRU can prioritize by hit_count (keep frequently accessed)
- Debugging: Validate cache effectiveness

**Why store message_size?**
- Collision detection (unlikely, but defensive)
- Metrics: Understand cache composition (small vs large messages)
- Eviction: Can prioritize evicting large low-hit entries

### Migration Script

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_scan_result_cache.rb
class CreateScanResultCache < ActiveRecord::Migration[7.1]
  def up
    create_table :scan_result_cache do |t|
      t.string :content_hash, limit: 64, null: false
      t.decimal :spam_score, precision: 8, scale: 2, null: false, default: 0.00
      t.boolean :threat, null: false, default: false
      t.string :threat_details, limit: 255
      t.json :spam_checks, null: false
      t.integer :message_size, null: false
      t.decimal :scan_timestamp, precision: 18, scale: 6, null: false
      t.string :scanner_version, limit: 50
      t.integer :hit_count, null: false, default: 1
      t.decimal :last_hit_timestamp, precision: 18, scale: 6
      t.timestamps
    end
    
    add_index :scan_result_cache, :content_hash, unique: true
    add_index :scan_result_cache, :scan_timestamp
    add_index :scan_result_cache, 'COALESCE(last_hit_timestamp, scan_timestamp)', name: 'idx_last_hit'
    add_index :scan_result_cache, :hit_count
    add_index :scan_result_cache, :message_size
  end
  
  def down
    drop_table :scan_result_cache
  end
end
```

### Servers Table Modification (Optional)

Add per-server opt-out capability:

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_scan_cache_to_servers.rb
class AddScanCacheToServers < ActiveRecord::Migration[7.1]
  def change
    add_column :servers, :scan_cache_enabled, :boolean, default: true, null: false
    add_index :servers, :scan_cache_enabled
  end
end
```

---

## Algorithm Specification

### Hash Computation Algorithm

**Input:** Raw email message (headers + body)  
**Output:** 64-character SHA-256 hex digest

**Steps:**

1. **Parse Message**
   ```ruby
   mail_obj = Mail.new(raw_message)
   ```

2. **Normalize Recipient Headers**
   ```ruby
   mail_obj.to = "NORMALIZED@CACHE.LOCAL"
   mail_obj.cc = nil  # Remove Cc header entirely
   # BCC already not in raw_message (removed during SMTP)
   ```

3. **Remove Message-Specific Headers**
   ```ruby
   mail_obj['X-Postal-MsgID'] = nil      # Postal tracking ID
   mail_obj['X-Postal-Timestamp'] = nil  # Postal internal timestamp
   # Keep Message-ID (from sender, part of content)
   # Keep Date (from sender, part of content)
   ```

4. **Reconstruct Normalized Message**
   ```ruby
   normalized = mail_obj.to_s
   ```

5. **Compute Hash**
   ```ruby
   content_hash = Digest::SHA256.hexdigest(normalized)
   ```

**Example:**

```
Original Message 1:
  To: alice@example.com
  From: church@example.org
  Subject: Weekly Newsletter
  Body: [5 MB of HTML]
  
Original Message 2:
  To: bob@example.com
  From: church@example.org
  Subject: Weekly Newsletter
  Body: [5 MB of HTML]

After Normalization (BOTH):
  To: NORMALIZED@CACHE.LOCAL
  From: church@example.org
  Subject: Weekly Newsletter
  Body: [5 MB of HTML]

SHA-256: abc123...def (SAME HASH)
Cache Hit: ✅
```

### Cache Lookup Algorithm

**Input:** content_hash (String), message_size (Integer)  
**Output:** CachedScanResult or nil

```ruby
def self.lookup(content_hash, message_size = nil)
  # Query database
  row = database.select_one(
    "SELECT * FROM scan_result_cache 
     WHERE content_hash = ? 
     LIMIT 1",
    content_hash
  )
  
  return nil unless row
  
  # Defensive: Verify size matches (collision detection)
  if message_size && row['message_size'] != message_size
    Rails.logger.warn "Hash collision detected: #{content_hash} (sizes: #{message_size} vs #{row['message_size']})"
    return nil
  end
  
  cached = CachedScanResult.new(row)
  
  # Check freshness
  return nil unless cached.fresh?
  
  cached
end
```

### Freshness Check Algorithm

```ruby
class CachedScanResult
  def fresh?
    # Check age
    age = Time.now.to_f - scan_timestamp
    return false if age > Postal::Config.scan_cache.ttl
    
    # Check signature version (if tracked)
    if Postal::Config.scan_cache.track_signatures
      current_version = SignatureTracker.current_version
      return false if scanner_version && scanner_version != current_version
    end
    
    true
  end
end
```

### Cache Store Algorithm

**Input:** content_hash, inspection_result, message_size  
**Output:** Boolean (success)

```ruby
def self.store(content_hash, inspection_result, message_size)
  spam_checks_json = inspection_result.spam_checks.map do |check|
    {
      code: check.code,
      score: check.score,
      description: check.description
    }
  end.to_json
  
  # Check cache size limit
  if should_evict?
    evict_lru
  end
  
  # Insert or update
  database.query(
    "INSERT INTO scan_result_cache 
       (content_hash, spam_score, threat, threat_details, spam_checks, 
        message_size, scan_timestamp, scanner_version, hit_count, last_hit_timestamp)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1, NULL)
     ON DUPLICATE KEY UPDATE
       hit_count = hit_count + 1,
       last_hit_timestamp = VALUES(scan_timestamp)",
    content_hash,
    inspection_result.spam_score,
    inspection_result.threat,
    inspection_result.threat_message,
    spam_checks_json,
    message_size,
    Time.now.to_f,
    SignatureTracker.current_version
  )
  
  true
rescue => e
  Rails.logger.error "Failed to store scan cache: #{e.message}"
  false
end
```

### Eviction Algorithm (LRU)

```ruby
def self.evict_lru
  max_entries = Postal::Config.scan_cache.max_cache_entries
  current_count = database.select_value("SELECT COUNT(*) FROM scan_result_cache")
  
  return 0 if current_count < max_entries
  
  # Evict oldest 10% by last access time
  evict_count = (max_entries * 0.1).to_i
  
  # Find cutoff timestamp
  cutoff = database.select_value(
    "SELECT COALESCE(last_hit_timestamp, scan_timestamp) 
     FROM scan_result_cache 
     ORDER BY COALESCE(last_hit_timestamp, scan_timestamp) ASC 
     LIMIT 1 OFFSET ?",
    evict_count
  )
  
  deleted = database.query(
    "DELETE FROM scan_result_cache 
     WHERE COALESCE(last_hit_timestamp, scan_timestamp) <= ?",
    cutoff
  )
  
  Rails.logger.info "Evicted #{deleted} LRU cache entries"
  deleted
end
```

---

## Code Integration Points

### File: lib/postal/message_db/message.rb

**Location:** Line ~520 (inspect_message method)

**Changes:**
1. Add cache lookup before `MessageInspection.scan`
2. Add cache store after scan completes
3. Add helper methods: `compute_cache_key`, `normalized_raw_message`, `restore_from_cache`

**Impact:** ~50 lines added to existing method

### File: lib/postal/scan_result_cache.rb (NEW)

**Location:** New file

**Purpose:** Cache management logic

**Lines of Code:** ~200 lines (class + tests)

### File: lib/postal/config_schema.rb

**Location:** Line ~490 (after existing scanner configs)

**Changes:**
```ruby
config.scan_cache = config.enable_struct do |c|
  c.enabled = config.boolean(default: false)
  c.ttl = config.integer(default: 604800)  # 7 days in seconds
  c.min_message_size = config.integer(default: 102400)  # 100 KB
  c.max_cache_entries = config.integer(default: 100000)
  c.normalize_recipients = config.boolean(default: true)
  c.track_signatures = config.boolean(default: false)  # Future: invalidate on signature updates
end
```

**Impact:** ~10 lines added

### File: config/postal.yml (EXAMPLE)

**New Section:**
```yaml
scan_cache:
  enabled: false  # Enable via feature flag
  ttl: 604800  # 7 days
  min_message_size: 102400  # 100 KB
  max_cache_entries: 100000
  normalize_recipients: true
  track_signatures: false
```

### File: app/models/server.rb

**Changes:**
```ruby
# Add to existing model
def scan_cache_enabled
  return false unless Postal::Config.scan_cache.enabled
  # Check server-specific override if column exists
  read_attribute(:scan_cache_enabled) != false
end
```

**Impact:** ~5 lines added

### File: lib/postal/message_inspection.rb

**Location:** No changes required

**Note:** Existing scanner integration remains unchanged. Cache layer sits above `MessageInspection.scan`.

---

## Configuration Management

### Configuration Hierarchy

```
1. Global Default (config_schema.rb)
   ↓
2. Environment Config (postal.yml)
   ↓
3. Environment Variable Override (POSTAL_SCAN_CACHE_*)
   ↓
4. Server-Specific Setting (servers.scan_cache_enabled)
```

### Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `scan_cache.enabled` | Boolean | false | Master feature flag |
| `scan_cache.ttl` | Integer | 604800 | Cache entry lifetime (seconds) |
| `scan_cache.min_message_size` | Integer | 102400 | Only cache if message >= 100 KB |
| `scan_cache.max_cache_entries` | Integer | 100000 | LRU eviction threshold |
| `scan_cache.normalize_recipients` | Boolean | true | Normalize To:/Cc: headers |
| `scan_cache.track_signatures` | Boolean | false | Track scanner versions |

### Environment Variables

```bash
# Master switch
POSTAL_SCAN_CACHE_ENABLED=true

# Cache lifetime (7 days)
POSTAL_SCAN_CACHE_TTL=604800

# Minimum message size (100 KB)
POSTAL_SCAN_CACHE_MIN_SIZE=102400

# Max cache entries
POSTAL_SCAN_CACHE_MAX_ENTRIES=100000
```

### Feature Flag Strategy

**Phase 1: POC (Logging Only)**
```yaml
scan_cache:
  enabled: false  # Cache disabled, only logging hashes
```

**Phase 2: Stage 1 Rollout (Server 3)**
```yaml
scan_cache:
  enabled: true
  
# In database:
UPDATE servers SET scan_cache_enabled = FALSE WHERE id != 3;
```

**Phase 3: Stage 2 Rollout (Server 25 or 29)**
```yaml
scan_cache:
  enabled: true
  
# In database:
UPDATE servers SET scan_cache_enabled = TRUE WHERE id IN (3, 25);
```

**Phase 4: Full Rollout**
```yaml
scan_cache:
  enabled: true
  
# In database:
UPDATE servers SET scan_cache_enabled = TRUE;  -- All servers
```

---

## Data Flow

### Normal Flow (Cache Miss)

```
1. Message arrives in queue
   ↓
2. Worker picks up queued_message
   ↓
3. Message.inspect_message called
   ↓
4. Compute content_hash = SHA256(normalized_raw_message)
   ↓
5. ScanResultCache.lookup(content_hash) → nil (MISS)
   ↓
6. MessageInspection.scan(message) 
   ├─ SpamAssassin: 12 sec
   ├─ ClamAV: 8 sec
   └─ Total: 20 sec
   ↓
7. Store results in message record (inspected=true, spam_score, threat)
   ↓
8. ScanResultCache.store(content_hash, result, message_size)
   ↓
9. Continue with delivery
```

**Timeline:** 20-25 seconds

### Fast Path (Cache Hit)

```
1. Message arrives in queue
   ↓
2. Worker picks up queued_message
   ↓
3. Message.inspect_message called
   ↓
4. Compute content_hash = SHA256(normalized_raw_message)
   ↓
5. ScanResultCache.lookup(content_hash) → CachedScanResult (HIT)
   ├─ Database query: ~5ms
   ├─ Freshness check: <1ms
   └─ Total: ~6ms
   ↓
6. Restore cached results to message record
   ├─ UPDATE messages: ~2ms
   ├─ INSERT spam_checks: ~3ms
   └─ Total: ~5ms
   ↓
7. cached_result.record_hit (update hit_count)
   ├─ UPDATE scan_result_cache: ~2ms
   ↓
8. Continue with delivery
```

**Timeline:** ~15 milliseconds (1,300x faster)

### Cache Eviction Flow

```
Daily Scheduled Job:
  ↓
1. ScanResultCache.cleanup_expired
   ├─ Find entries where (now - scan_timestamp) > TTL
   ├─ DELETE expired entries
   └─ Log count
   
2. IF cache_size > max_cache_entries:
   ├─ ScanResultCache.evict_lru
   ├─ Find oldest 10% by last_hit_timestamp
   ├─ DELETE oldest entries
   └─ Log count
```

### Signature Update Flow (Future)

```
SpamAssassin/ClamAV Update Event:
  ↓
1. SignatureTracker.update_version(new_version)
   ↓
2. ScanResultCache.invalidate_all
   ├─ TRUNCATE scan_result_cache
   └─ Log invalidation
   ↓
3. All subsequent messages: Cache MISS → Full scan
```

---

## Performance Considerations

### Hash Computation Cost

**SHA-256 Performance:**
- ~500 MB/sec on modern CPU
- 5 MB message → ~10 milliseconds
- Negligible compared to 20-second scan time

**Normalization Cost:**
- Mail.new: ~50ms (parse MIME)
- Header modification: ~1ms
- mail_obj.to_s: ~20ms (reconstruct)
- **Total: ~70ms overhead per message**

**Impact:**
- Cache miss: 70ms normalization + 20 sec scan = 20.07 sec (0.3% overhead)
- Cache hit: 70ms normalization + 5ms lookup = 75ms (acceptable)

**Optimization opportunity:**
- Lazy hash computation: Only compute if cache enabled
- Cache normalized message: Avoid re-parsing for cache store

### Database Query Performance

**Cache Lookup Query:**
```sql
SELECT * FROM scan_result_cache 
WHERE content_hash = 'abc123...' 
LIMIT 1;
```

**Index usage:** `idx_content_hash` (unique)  
**Expected time:** 5-10ms (single-row lookup by unique index)

**Cache Store Query:**
```sql
INSERT INTO scan_result_cache (...) VALUES (...)
ON DUPLICATE KEY UPDATE hit_count = hit_count + 1;
```

**Expected time:** 2-5ms (single-row upsert)

**hit_count Update:**
```sql
UPDATE scan_result_cache 
SET hit_count = hit_count + 1, last_hit_timestamp = ?
WHERE content_hash = ?;
```

**Expected time:** 2-3ms (single-row update by unique index)

### Memory Considerations

**Cache Size Calculation:**
```
100,000 entries × average row size

Row size breakdown:
  content_hash: 64 bytes
  spam_score: 8 bytes
  threat: 1 byte
  threat_details: ~50 bytes avg
  spam_checks: ~500 bytes avg (JSON)
  message_size: 4 bytes
  timestamps: 24 bytes
  hit_count: 4 bytes
  created_at/updated_at: 16 bytes
  ────────────────────────
  Total per row: ~671 bytes

100,000 rows × 671 bytes = 67 MB
Plus indexes: ~30 MB
Total: ~100 MB
```

**Impact:** Negligible (database likely has GBs of RAM)

### Thread Pool Impact

**Current bottleneck:**
```
2 threads × 20 sec/message = 360 messages/hour max capacity
```

**With 88% cache hit rate:**
```
Effective scan time: (0.12 × 20 sec) + (0.88 × 0.015 sec) = 2.41 sec
2 threads × 3600/2.41 = 2,987 messages/hour capacity
8.3x improvement
```

**With 99% cache hit rate:**
```
Effective scan time: (0.01 × 20 sec) + (0.99 × 0.015 sec) = 0.215 sec
2 threads × 3600/0.215 = 33,488 messages/hour capacity
93x improvement
```

---

## Scalability

### Vertical Scaling (Larger Database)

**Cache grows with message volume:**
- 1,000 messages/day → ~50 unique → 50 cache entries/day
- 365 days × 50 = 18,250 entries (with 1-year TTL)
- At 100 KB/entry storage: 1.8 GB

**MySQL can handle:**
- Millions of rows easily
- Gigabytes of cache without performance issues
- Indexes fit in memory (InnoDB buffer pool)

**When to worry:**
- Cache >10 million entries → consider Redis
- Cache >10 GB → tune eviction aggressively
- Lookup time >50ms → add Redis layer

### Horizontal Scaling (Multiple Postal Instances)

**Current design: Shared cache**
- All Postal instances use same MySQL database
- Cache hits benefit all instances (global scope)
- No synchronization needed

**Multi-region deployment:**
- Option 1: Regional caches (isolated, lower hit rate)
- Option 2: Shared cache (single region MySQL)
- Option 3: Redis cluster (distributed cache)

**Recommendation:** Start with single-region shared cache

### Load Balancing Considerations

**No special handling needed:**
- Cache is stateless from worker perspective
- Any worker can lookup/store
- Database handles concurrency (row-level locks)

**Race condition scenario:**
```
Thread 1: Lookup cache for hash X → MISS
Thread 2: Lookup cache for hash X → MISS (same time)
Thread 1: Scan message, store cache
Thread 2: Scan message, store cache (duplicate work)
```

**Impact:** Minimal (rare, only affects duplicates arriving simultaneously)
**Mitigation:** ON DUPLICATE KEY UPDATE handles gracefully

### Future Optimization: Redis Layer

**If MySQL becomes bottleneck:**

```ruby
# Two-tier cache
def self.lookup(content_hash)
  # L1: Redis (fast, volatile)
  redis_key = "scan_cache:#{content_hash}"
  if cached_json = Redis.current.get(redis_key)
    return CachedScanResult.from_json(cached_json)
  end
  
  # L2: MySQL (slower, persistent)
  if cached = lookup_mysql(content_hash)
    # Promote to L1
    Redis.current.setex(redis_key, 3600, cached.to_json)
    return cached
  end
  
  nil
end
```

**Benefits:**
- Sub-millisecond lookups from Redis
- MySQL provides persistence and audit trail
- Best of both worlds

**Complexity:** Medium (defer until proven necessary)

---

## Change Log

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-31 | OpenCode AI | Initial draft |

---

**Next Document:** [03-SECURITY-ANALYSIS.md](03-SECURITY-ANALYSIS.md)
