# Multi-Hash Email Scan Cache Enhancement - Implementation Complete

## Overview

The multi-hash cache enhancement has been implemented to improve cache hit rates for personalized emails (e.g., newsletters with "Hi John" vs "Hi Sarah"). This addresses the problem where identical newsletters with only recipient name variations would get 0% cache hits.

**Expected improvement:** From ~0% to 70-90% cache hit rate for personalized newsletters.

## What Was Implemented

### 1. Database Migration
**File:** `db/migrate/20260108000000_add_multi_hash_to_scan_result_cache.rb`

Added three new columns to `scan_result_cache` table:
- `attachment_hash` (string, 64 chars) - SHA-256 hash of sorted attachments
- `body_template_hash` (string, 64 chars) - SHA-256 hash of body with names normalized
- `matched_via` (string, 20 chars) - Tracks which hash type matched (full_hash, attachment_hash, or body_template_hash)

Added composite indexes for performance:
- `idx_scan_cache_attachment_hash_size` on `(attachment_hash, message_size)`
- `idx_scan_cache_template_hash_size` on `(body_template_hash, message_size)`

### 2. Core Cache Manager Logic
**File:** `lib/postal/scan_cache_manager.rb`

Completely rewritten with multi-hash support:

#### New Methods:
- `compute_attachment_hash(raw_message)` - Computes hash of all attachments (sorted by filename)
- `compute_body_template_hash(raw_message)` - Computes hash with recipient names normalized
- `normalize_template_text(text)` - Normalizes only greeting patterns ("Hi John" → "Hi NAME")
- `find_by_attachment_hash(hash, size)` - Helper for attachment hash lookup
- `find_by_template_hash(hash, size)` - Helper for template hash lookup
- `record_cache_hit(entry, match_type)` - Records which hash type matched
- `invalidate_all!()` - Clears entire cache
- `invalidate_older_than(days)` - Clears entries older than X days

#### Updated Methods:
- `lookup(raw_message, message_size)` - Now uses **sequential checking**:
  1. Try full hash (exact match)
  2. If enabled, try attachment hash (same attachments, different body)
  3. If enabled, try template hash (personalized messages)
  4. Return nil if no match
  
  **Key feature:** Stops at first match (lazy evaluation) - doesn't compute unnecessary hashes.

- `store(raw_message, message_size, inspection_result)` - Computes and stores all 3 hashes
  - Only caches if spam_score < 2.0 (more conservative than before)
  - Stores `attachment_hash` and `body_template_hash` when applicable

#### Feature Flags:
- `attachment_hash_enabled?` - Checks `Postal::Config.message_inspection.cache_attachment_hash_enabled?`
- `template_hash_enabled?` - Checks `Postal::Config.message_inspection.cache_template_hash_enabled?`

### 3. Model Updates
**File:** `app/models/scan_result_cache.rb`

Added enum for tracking match type:
```ruby
enum matched_via: {
  full_hash: 0,
  attachment_hash: 1,
  body_template_hash: 2
}, _prefix: true
```

### 4. Configuration Schema
**File:** `lib/postal/config_schema.rb`

Added two new config options to `message_inspection` group:
- `cache_attachment_hash_enabled` (boolean, default: true)
- `cache_template_hash_enabled` (boolean, default: true)

These allow disabling specific hash types if issues arise.

### 5. Comprehensive Tests
**File:** `spec/lib/postal/scan_cache_manager_spec.rb`

Added extensive test coverage for:
- `compute_attachment_hash` (sorting, nil handling, errors)
- `compute_body_template_hash` (conservative regex, subject inclusion)
- `normalize_template_text` (greetings only, not all caps words)
- Sequential lookup behavior (stops on first hit)
- Lazy computation (doesn't compute unnecessary hashes)
- `matched_via` tracking
- Cache invalidation methods
- Feature flag behavior
- New spam threshold (2.0)

## Key Technical Decisions

### 1. Sequential Lookups (Not OR Query)
**Rationale:** Better index usage, no table scans
- Check full hash first (fastest, most specific)
- Then attachment hash (if enabled and no full match)
- Finally template hash (if enabled and no other match)
- Stop at first match

### 2. Conservative Template Regex
**Pattern:** Only matches greeting patterns like:
- `Hi John,`
- `Dear Sarah,`
- `Hello Bob!`

**Does NOT match:**
- Standalone capitalized words ("Monday", "Sale", "Big")
- Words not in greeting context

**Rationale:** Prevents false positives that would incorrectly cache different emails together.

### 3. Include Subject in Template Hash
**Rationale:** Security - prevents spam with same body but different subjects from sharing cache entries.

### 4. Sort Attachments Before Hashing
**Rationale:** Ensures consistent hash regardless of attachment order in MIME structure.

### 5. Lower Spam Threshold (2.0 vs 4.0)
**Old:** Cached if `spam_score < 0.8 * threshold` (0.8 * 5.0 = 4.0)
**New:** Cached if `spam_score < 2.0`

**Rationale:** More conservative caching reduces risk of caching borderline spam.

### 6. Feature Flags for Each Hash Type
**Rationale:** Allows disabling specific hash types if:
- Template regex causes false positives
- Attachment hashing has performance issues
- Need to troubleshoot which hash type is problematic

### 7. Lazy Hash Computation
**Rationale:** Performance optimization
- Only compute hashes as needed during lookup
- If full hash matches, don't compute attachment/template hashes
- If attachment hash matches, don't compute template hash

### 8. Tracked Match Type (`matched_via`)
**Rationale:** Metrics and debugging
- Shows which hash type is providing cache hits
- Helps identify if template regex needs tuning
- Useful for performance analysis

## Deployment Instructions

### Prerequisites
- Migration file must be present in `db/migrate/` directory on servers
- Updated code files must be deployed to servers

### Option 1: Automated Deployment Script
Run the provided deployment script on each server:

```bash
# On e1.edify.press
./deploy_multi_hash_migration.sh

# On e2.edify.press  
./deploy_multi_hash_migration.sh
```

The script will:
1. Detect which server it's running on
2. Find the worker container
3. Run the migration
4. Verify columns were added
5. Restart worker containers

### Option 2: Manual Deployment

#### On e1.edify.press:
```bash
# Find worker container
WORKER=$(docker ps --filter 'name=worker' --format '{{.Names}}' | head -1)

# Run migration
docker exec $WORKER rails db:migrate

# Verify migration
docker exec $WORKER rails runner "
  puts 'Attachment hash column exists: ' + 
       ActiveRecord::Base.connection.column_exists?(:scan_result_cache, :attachment_hash).to_s
  puts 'Body template hash column exists: ' + 
       ActiveRecord::Base.connection.column_exists?(:scan_result_cache, :body_template_hash).to_s
  puts 'Matched via column exists: ' + 
       ActiveRecord::Base.connection.column_exists?(:scan_result_cache, :matched_via).to_s
"

# Restart workers
docker restart $(docker ps --filter 'name=worker' --format '{{.Names}}')
```

#### On e2.edify.press:
```bash
# Same commands as e1
```

### Verification After Deployment

1. **Check migration status:**
   ```bash
   docker exec <worker-container> rails db:migrate:status | grep multi_hash
   ```
   Should show: `up     20260108000000  Add multi hash to scan result cache`

2. **Monitor logs for cache activity:**
   ```bash
   docker logs -f <worker-container> | grep -i cache
   ```
   Look for:
   - `Cache HIT (full_hash)` - Exact match
   - `Cache HIT (attachment_hash)` - Attachment match
   - `Cache HIT (body_template_hash)` - Template match
   - `Cache MISS` - No match found

3. **Test with personalized emails:**
   Send two identical newsletters with only name variations:
   - Email 1: "Hi John, ..."
   - Email 2: "Hi Sarah, ..."
   
   Both should show `Cache HIT (body_template_hash)` after the first is scanned.

## Configuration (Optional)

The enhancement works with default settings (both hash types enabled). To customize:

Add to `/opt/postal/config/postal.yml`:
```yaml
message_inspection:
  cache_enabled: true
  cache_ttl_days: 7
  cache_max_entries: 100000
  # New options:
  cache_attachment_hash_enabled: true   # Set false to disable attachment hash
  cache_template_hash_enabled: true      # Set false to disable template hash
```

After config changes, restart workers:
```bash
docker restart $(docker ps --filter 'name=worker' --format '{{.Names}}')
```

## Troubleshooting

### Issue: Template hash causing false positives
**Symptom:** Different emails incorrectly sharing cache entries

**Solution:** Disable template hash temporarily:
```yaml
message_inspection:
  cache_template_hash_enabled: false
```

Then investigate which emails are being incorrectly matched and adjust the regex in `normalize_template_text()`.

### Issue: Performance degradation
**Symptom:** Slower email processing

**Possible causes:**
1. Too many cache entries - check `ScanResultCache.count`
2. Missing indexes - verify with `SHOW INDEX FROM scan_result_cache;`

**Solutions:**
1. Lower `cache_max_entries` or run `ScanCacheManager.perform_maintenance`
2. Verify indexes exist with migration status

### Issue: Cache not working at all
**Symptom:** All cache MISS, no cache HIT messages

**Checklist:**
1. Is `cache_enabled: true` in postal.yml?
2. Did migration run successfully?
3. Are columns present in database?
4. Is rspamd/spamd/clamav enabled? (Cache only works when scanning is enabled)

**Verify:**
```bash
docker exec <worker> rails runner "
  puts 'Cache enabled: ' + Postal::Config.message_inspection.cache_enabled?.to_s
  puts 'Columns exist: ' + ActiveRecord::Base.connection.column_exists?(:scan_result_cache, :attachment_hash).to_s
"
```

## Performance Expectations

### Before (Single Hash):
- **Identical emails:** 90-95% cache hit rate
- **Personalized newsletters:** 0-5% cache hit rate
- **Emails with attachments:** 0-5% cache hit rate (if body differs)

### After (Multi-Hash):
- **Identical emails:** 90-95% cache hit rate (unchanged - full hash)
- **Personalized newsletters:** 70-90% cache hit rate (template hash)
- **Emails with attachments:** 60-80% cache hit rate (attachment hash)

### Cache Lookup Performance:
- **Full hash match:** ~1-2ms (fastest - stops immediately)
- **Attachment hash match:** ~3-5ms (parses MIME, computes attachment hash)
- **Template hash match:** ~5-10ms (parses MIME, computes template hash)
- **Cache miss:** ~10-15ms (tries all three lookups)

Still much faster than full spam scan (100-500ms).

## Monitoring Queries

### Check cache hit rates by type:
```sql
SELECT 
  matched_via,
  COUNT(*) as hits,
  ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM scan_result_cache WHERE matched_via IS NOT NULL), 2) as percentage
FROM scan_result_cache
WHERE matched_via IS NOT NULL
GROUP BY matched_via
ORDER BY hits DESC;
```

### Check recent cache activity:
```sql
SELECT 
  matched_via,
  spam_score,
  scanned_at,
  last_hit_at,
  hit_count
FROM scan_result_cache
WHERE last_hit_at > NOW() - INTERVAL 1 HOUR
ORDER BY last_hit_at DESC
LIMIT 20;
```

### Find most frequently hit cache entries:
```sql
SELECT 
  matched_via,
  hit_count,
  spam_score,
  scanned_at,
  last_hit_at
FROM scan_result_cache
ORDER BY hit_count DESC
LIMIT 20;
```

## Files Modified

1. ✅ `db/migrate/20260108000000_add_multi_hash_to_scan_result_cache.rb` (new)
2. ✅ `lib/postal/scan_cache_manager.rb` (major rewrite)
3. ✅ `app/models/scan_result_cache.rb` (added enum)
4. ✅ `lib/postal/config_schema.rb` (added config options)
5. ✅ `spec/lib/postal/scan_cache_manager_spec.rb` (comprehensive tests)
6. ✅ `deploy_multi_hash_migration.sh` (deployment script)

## Next Steps

1. **Deploy to e1.edify.press**
   - Run migration
   - Restart workers
   - Monitor logs

2. **Deploy to e2.edify.press**
   - Run migration
   - Restart workers
   - Monitor logs

3. **Test with real emails**
   - Send personalized newsletters
   - Verify cache HIT (body_template_hash)
   - Check cache hit rate improvement

4. **Monitor for one week**
   - Track cache hit rates by type
   - Watch for false positives
   - Tune template regex if needed

5. **Analyze results**
   - Run monitoring queries
   - Calculate ROI (cache hits vs scans)
   - Document any issues found

## Success Criteria

✅ Migration completes without errors on both servers
✅ All three hash columns present in database
✅ Composite indexes created successfully
✅ Workers restart without errors
✅ Logs show cache HIT messages with match types
✅ Personalized emails show template hash matches
✅ No false positives detected
✅ Cache hit rate improves from ~0% to 70%+ for newsletters

## Support

For issues or questions:
1. Check troubleshooting section above
2. Review logs: `docker logs -f <worker-container>`
3. Check design docs: `doc/scan-result-caching/MULTI_HASH_ENHANCEMENT_v2.md`
4. Review code comments in `lib/postal/scan_cache_manager.rb`

---

**Implementation completed:** January 8, 2026
**Ready for deployment:** YES
**Breaking changes:** NO (backward compatible)
**Rollback plan:** Run `rails db:rollback` to remove new columns
