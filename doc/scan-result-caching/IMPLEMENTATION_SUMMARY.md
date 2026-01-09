# Scan Result Caching - Implementation Summary

**Date**: December 31, 2025  
**Status**: POC Implementation Complete  
**Branch**: `feature/scan-result-caching` (to be created)

## Overview

Implemented hash-based caching for spam/virus scan results to resolve email delivery incidents caused by newsletter campaigns overwhelming the 2-thread worker pool. This POC is ready for testing and validation before production deployment.

## Validation Results ✅

All design assumptions validated against actual Postal codebase:

- **Message Inspection Flow**: Confirmed `inspect_message` method at lib/postal/message_db/message.rb:520-531
- **Scanner Integration**: Both SpamAssassin and ClamAV receive full `raw_message` 
- **Configuration System**: Konfig-based schema supports new `:message_inspection` group
- **Database**: MariaDB/MySQL with utf8mb4, no existing cache conflicts
- **Migration Pattern**: Follows existing ActiveRecord migration conventions

## Files Created

### Database Layer
1. **`db/migrate/20251231000000_create_scan_result_cache.rb`** (35 lines)
   - Creates `scan_result_cache` table in main `postal` database
   - Unique index on `[content_hash, message_size]` for collision detection
   - Maintenance indexes on `scanned_at` and `hit_count` for LRU eviction

2. **`db/migrate/20251231000001_add_disable_scan_caching_to_servers.rb`** (7 lines)
   - Adds `disable_scan_caching` boolean column to `servers` table
   - Allows per-server opt-out of caching

### Application Layer
3. **`app/models/scan_result_cache.rb`** (57 lines)
   - ActiveRecord model for cache table
   - JSON serialization of spam_checks array
   - Methods: `#record_hit!`, `#valid_cache_entry?`, `#spam_checks`, `#spam_checks=`

4. **`lib/postal/cached_scan_result.rb`** (37 lines)
   - Wrapper to make cached results compatible with `MessageInspection` interface
   - Implements same methods as `MessageInspection`: `spam_score`, `spam_checks`, `threat`, etc.
   - Includes `#cached?` method to identify cache hits in logs

5. **`lib/postal/scan_cache_manager.rb`** (145 lines)
   - Core caching logic
   - Message normalization (removes recipient-specific headers)
   - SHA-256 hash computation
   - Cache lookup with TTL and size validation
   - Cache storage with security policies (no threats, no high spam)
   - Maintenance routine for TTL expiry and LRU eviction

### Configuration
6. **`lib/postal/config_schema.rb`** (Modified, +17 lines)
   - Added `:message_inspection` configuration group
   - Settings: `cache_enabled`, `cache_ttl_days`, `cache_max_entries`
   - Defaults: disabled, 7 days TTL, 100K max entries

### Core Integration
7. **`lib/postal/message_db/message.rb`** (Modified, +24 lines at line 520)
   - Modified `inspect_message` method to check cache before scanning
   - Stores successful scan results in cache
   - Logs cache HIT/MISS for monitoring

### Tests
8. **`spec/lib/postal/scan_cache_manager_spec.rb`** (370 lines)
   - Comprehensive tests for normalization, hashing, lookup, storage
   - Tests for TTL expiry, LRU eviction, collision detection
   - Tests for security policies (no caching threats/high spam)

9. **`spec/models/scan_result_cache_spec.rb`** (200 lines)
   - Model validations and callbacks
   - JSON serialization of spam_checks
   - Hit recording and TTL validation
   - Unique constraint enforcement

## Configuration

Add to `config/postal.yml` (v2 format):

```yaml
message_inspection:
  cache_enabled: true
  cache_ttl_days: 7
  cache_max_entries: 100000
```

Or via environment variables:

```bash
MESSAGE_INSPECTION__CACHE_ENABLED=true
MESSAGE_INSPECTION__CACHE_TTL_DAYS=7
MESSAGE_INSPECTION__CACHE_MAX_ENTRIES=100000
```

## How It Works

### 1. Message Normalization
Before hashing, the cache manager normalizes messages by:
- Removing `X-Postal-MsgID`, `Message-ID`, `Date`, `Received` headers
- Replacing `To:` and `Cc:` with `<normalized>` placeholder
- Preserving `From:`, `Subject:`, and all body content

**Why**: Newsletter campaigns send same content to many recipients. Normalization ensures identical content gets same hash regardless of recipient.

### 2. Hash Computation
- Algorithm: SHA-256 (64 hex character output)
- Input: Normalized message (headers + body)
- Collision detection: Also stores `message_size` for secondary validation

### 3. Cache Lookup Flow
```
inspect_message called
  └─> Check if caching enabled (global + per-server)
       ├─> Compute content_hash from normalized message
       ├─> Lookup cache entry by [content_hash, message_size]
       ├─> Validate TTL (scanned_at > 7 days ago?)
       └─> If HIT: Return CachedScanResult (record hit)
           If MISS: Call MessageInspection.scan() → Store result
```

### 4. Security Policies
Never cache:
- Messages with `threat = true` (virus detected)
- Messages with spam_score > 80% of threshold (e.g., >4.0 if threshold is 5.0)

**Why**: Security posture may change (new virus signatures, updated spam rules). Always re-scan suspicious content.

### 5. Cache Maintenance
Automatic cleanup via `ScanCacheManager.perform_maintenance`:
- Delete entries where `scanned_at < (TTL days) ago`
- If `count > max_entries`, delete least-hit entries (LRU)

**Trigger**: Should be run via cron job or scheduled task (e.g., daily at 3am)

## Testing the Implementation

### 1. Run Migrations
```bash
cd /Users/matt/repo/postal
RAILS_ENV=test bundle exec rails db:migrate
```

### 2. Run Tests
```bash
# Run all cache-related tests
bundle exec rspec spec/lib/postal/scan_cache_manager_spec.rb
bundle exec rspec spec/models/scan_result_cache_spec.rb

# Run full test suite
bundle exec rspec
```

### 3. Manual Testing (Staging Environment)
```ruby
# Rails console
rails console

# Enable caching
Postal::Config.message_inspection.cache_enabled = true

# Send test message
server = Server.find(3) # Use monitoring server
msg = server.message_db.new_message
msg.rcpt_to = "test@example.com"
msg.mail_from = "sender@example.com"
msg.raw_message = File.read("test_newsletter.eml")
msg.save

# First inspection (MISS)
result1 = msg.inspect_message
# Check logs for "Cache MISS for message X"

# Second inspection (HIT) - should skip actual scanning
msg.update(inspected: false) # Reset flag
result2 = msg.inspect_message
# Check logs for "Cache HIT for message X [hash=...]"

# Verify cache entry
cache_entry = ScanResultCache.last
puts "Hash: #{cache_entry.content_hash[0..7]}"
puts "Hit count: #{cache_entry.hit_count}"
puts "Spam score: #{cache_entry.spam_score}"
```

## Performance Expectations

Based on Dec 30 incident (Server 29):
- **Messages**: 252 identical newsletters @ 5.17 MB each
- **Without cache**: 252 × 43s = 10,836s (3.0 hours)
- **With cache**: (1 × 43s) + (251 × 0.05s) = 55.5s (~1 minute)
- **Speedup**: 195x for this incident

Expected production impact:
- **Server 29** (Calvary Bible Church): 88% cache hit rate → 42 min → 5 min
- **Server 25** (The Shepherd's Church): 99% cache hit rate → 75 min → 6.5 min

## Deployment Plan

### Phase 1: POC Validation (Week 1)
**Goal**: Validate cache hit rate in production without actually caching

**Steps**:
1. Deploy code with `cache_enabled: false`
2. Add logging to track theoretical cache hits
3. Collect 48 hours of data from Server 29 and Server 25
4. Analyze logs: `grep 'CACHE_POC' /var/log/postal/worker.log | wc -l`
5. Calculate actual hit rate vs. predicted 80%+

**Success Criteria**:
- Hit rate ≥ 70%
- No performance degradation from hash computation
- No errors in hash computation or normalization

**GO/NO-GO Decision**: If hit rate < 70%, investigate message variability before proceeding

### Phase 2: Limited Production (Week 2-3)
**Goal**: Enable caching for low-risk server first

**Steps**:
1. Enable caching for Server 3 (monitoring server, low traffic)
2. Monitor for 48 hours: cache hits, database load, worker CPU
3. If successful, enable for Server 29 OR Server 25 (pick one)
4. Wait for next newsletter campaign (natural load test)
5. Monitor queue depth during campaign vs. historical baseline

**Success Criteria**:
- Queue depth stays < 100 during newsletter (historical: 500+)
- CPU stays < 2.0 during campaign (historical: 9.55)
- No increase in database latency
- No failed messages

**Rollback Trigger**: Any of:
- Queue depth > 300
- CPU > 5.0 sustained for > 5 minutes
- Database latency > 100ms
- Message delivery failures > 1%

### Phase 3: Full Production (Week 4)
**Goal**: Enable caching for all servers

**Steps**:
1. Enable `cache_enabled: true` globally
2. Monitor all 50 servers for 7 days
3. Run maintenance script daily: `Postal::ScanCacheManager.perform_maintenance`
4. Track cache statistics via dashboard

**Success Criteria**:
- Zero incidents in 7-day period
- Average cache hit rate > 60% across all servers
- Queue depth < 50 at all times
- Worker CPU < 2.0 baseline

### Phase 4: Long-term Monitoring (Week 5+)
**Goal**: Validate sustained performance improvement

**Steps**:
1. Continue monitoring for 30 days
2. Compare incidents: Pre-cache (17 incidents in 45 days) vs. Post-cache (target: 0 incidents)
3. Measure ROI: Worker time saved, infrastructure costs
4. Optimize cache parameters if needed (TTL, max_entries)

## Monitoring & Alerts

### Key Metrics to Track

1. **Cache Performance**
   - Hit rate: `(cache_hits / total_scans) * 100`
   - Miss rate: `(cache_misses / total_scans) * 100`
   - Average lookup time: `< 5ms`

2. **Database Health**
   - `scan_result_cache` table size: `< 10 GB`
   - Query performance: `SELECT` by hash `< 1ms`
   - Index usage: `content_hash` index should be primary

3. **Worker Performance**
   - Queue depth: `< 50` (baseline), `< 100` (during newsletter)
   - CPU usage: `< 2.0` (baseline), `< 4.0` (during newsletter)
   - Processing time per message: `< 5s` (was 20-43s)

4. **Application Health**
   - Cache errors: `0` (degraded gracefully, should not fail messages)
   - Cache storage failures: `< 1%` (race conditions acceptable)
   - Maintenance completion: Daily successful run

### Log Queries

```bash
# Count cache hits in last hour
journalctl -u postal-worker --since "1 hour ago" | grep "Cache HIT" | wc -l

# Count cache misses in last hour
journalctl -u postal-worker --since "1 hour ago" | grep "Cache MISS" | wc -l

# Calculate hit rate
hits=$(journalctl -u postal-worker --since "1 hour ago" | grep "Cache HIT" | wc -l)
misses=$(journalctl -u postal-worker --since "1 hour ago" | grep "Cache MISS" | wc -l)
total=$((hits + misses))
echo "Hit rate: $((hits * 100 / total))%"

# Check for cache errors
journalctl -u postal-worker --since "1 hour ago" | grep "Cache.*failed"
```

### Alert Rules (Prometheus/Alertmanager)

```yaml
- alert: CacheLowHitRate
  expr: (postal_cache_hits / (postal_cache_hits + postal_cache_misses)) < 0.5
  for: 1h
  annotations:
    summary: "Postal cache hit rate below 50% for 1 hour"

- alert: CacheTableTooBig
  expr: mysql_table_size_bytes{table="scan_result_cache"} > 10737418240  # 10GB
  for: 5m
  annotations:
    summary: "scan_result_cache table exceeds 10GB"

- alert: CacheMaintenanceFailed
  expr: increase(postal_cache_maintenance_errors[24h]) > 0
  annotations:
    summary: "Cache maintenance job failed in last 24 hours"
```

## Rollback Procedure

If issues occur in production:

### Immediate Rollback (< 5 minutes)
```bash
# 1. Disable caching via config
# Edit config/postal.yml or set env var:
export MESSAGE_INSPECTION__CACHE_ENABLED=false

# 2. Restart workers
systemctl restart postal-worker

# 3. Verify caching disabled
journalctl -u postal-worker -f | grep "Cache"  # Should see no cache logs
```

### Data Cleanup (Optional)
```bash
# If cache table causing issues, truncate it:
mysql -u root -p postal -e "TRUNCATE TABLE scan_result_cache;"

# Or drop the table entirely:
mysql -u root -p postal -e "DROP TABLE scan_result_cache;"
```

### Code Rollback
```bash
# Revert to previous commit
git revert <commit-hash>
git push origin main

# Or checkout previous release
git checkout v2.x.x
```

## Known Limitations

1. **Initial Cache Warm-up**: First message of each unique content will still take 20-43s to scan. Subsequent identical messages benefit.

2. **Cache Miss Penalty**: Hash computation adds ~1-2ms overhead per message. For cache misses, this is negligible compared to 20-43s scan time.

3. **Memory Usage**: In-memory hash computation for 5MB messages uses ~10MB RAM per worker thread. With 2 threads, this is ~20MB baseline.

4. **Database Growth**: At 100K max entries × ~500 bytes per row = ~50MB table size. Well within MariaDB capacity.

5. **Signature Updates**: When ClamAV virus signatures update, cached "clean" results may be outdated. Mitigated by 7-day TTL. For immediate re-scanning, truncate cache table.

## Next Steps

1. **Review this implementation** with team (Engineering, Product, Security)
2. **Get approval** for POC deployment to staging
3. **Deploy to staging** and run test scenarios
4. **Execute Phase 1 POC** in production (logging only)
5. **Analyze results** and make GO/NO-GO decision for Phase 2

## Questions / Concerns?

Contact: [Your email]  
Design Docs: `/Users/matt/repo/postal/doc/scan-result-caching/`  
Implementation: See files listed above  
Tests: `spec/lib/postal/scan_cache_manager_spec.rb`, `spec/models/scan_result_cache_spec.rb`
