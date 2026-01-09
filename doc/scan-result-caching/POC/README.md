# POC Implementation Guide

This directory contains all the code artifacts needed to implement the scan result caching POC in the Postal repository.

## Directory Contents

### Database Migrations
- `20251231000000_create_scan_result_cache.rb` - Creates the cache table in main `postal` database
- `20251231000001_add_disable_scan_caching_to_servers.rb` - Adds per-server opt-out column

### Application Code
- `scan_result_cache.rb` - ActiveRecord model (goes in `app/models/`)
- `cached_scan_result.rb` - Result wrapper class (goes in `lib/postal/`)
- `scan_cache_manager.rb` - Core caching logic (goes in `lib/postal/`)

### Tests
- `scan_cache_manager_spec.rb` - Manager tests (goes in `spec/lib/postal/`)
- `scan_result_cache_spec.rb` - Model tests (goes in `spec/models/`)

### Patches
- `config_schema.patch` - Changes to `lib/postal/config_schema.rb`
- `message.patch` - Changes to `lib/postal/message_db/message.rb`

## Implementation Steps

### Step 1: Apply Database Migrations

```bash
# Copy migration files
cp 20251231000000_create_scan_result_cache.rb ../../db/migrate/
cp 20251231000001_add_disable_scan_caching_to_servers.rb ../../db/migrate/

# Run migrations
RAILS_ENV=development bundle exec rails db:migrate
RAILS_ENV=test bundle exec rails db:migrate
```

**Expected Output:**
```
== 20251231000000 CreateScanResultCache: migrating ===========================
-- create_table(:scan_result_cache, {:charset=>"utf8mb4", :collation=>"utf8mb4_general_ci"})
-- add_index(:scan_result_cache, [:content_hash, :message_size], {:unique=>true, :name=>"index_scan_cache_on_hash_and_size"})
-- add_index(:scan_result_cache, :scanned_at, {:name=>"index_scan_cache_on_scanned_at"})
-- add_index(:scan_result_cache, :hit_count, {:name=>"index_scan_cache_on_hit_count"})
== 20251231000000 CreateScanResultCache: migrated (0.0234s) ==================

== 20251231000001 AddDisableScanCachingToServers: migrating ==================
-- add_column(:servers, :disable_scan_caching, :boolean, {:default=>false, :after=>:privacy_mode})
== 20251231000001 AddDisableScanCachingToServers: migrated (0.0089s) =========
```

### Step 2: Add Model File

```bash
# Copy model to app/models/
cp scan_result_cache.rb ../../app/models/
```

**Verification:**
```ruby
# Rails console
rails console

# Test model
ScanResultCache.new(
  content_hash: "a" * 64,
  message_size: 1000,
  spam_score: 1.5,
  threat: false
).valid?
# => true
```

### Step 3: Add Library Classes

```bash
# Copy library files
cp cached_scan_result.rb ../../lib/postal/
cp scan_cache_manager.rb ../../lib/postal/
```

**Verification:**
```ruby
# Rails console
rails console

# Test hash computation
Postal::ScanCacheManager.compute_hash("test message")
# => "7815696ecbf1c96e6894b779456d330e8d45f8c8c85f4c2f3c87c5c7e6f8c9d1" (or similar 64-char hash)

# Test normalization
msg = "From: test@example.com\nTo: recipient@example.com\n\nBody"
normalized = Postal::ScanCacheManager.normalize_message(msg)
puts normalized
# => Should show "To: <normalized>" instead of actual recipient
```

### Step 4: Apply Configuration Changes

```bash
# Apply the patch
cd ../../lib/postal
patch -p0 < ../../doc/scan-result-caching/POC/config_schema.patch
```

**Or manually add** (after line 491, inside the ConfigSchema block):

```ruby
    group :message_inspection do
      boolean :cache_enabled do
        description "Enable caching of spam/virus scan results based on message content hash"
        default false
      end

      integer :cache_ttl_days do
        description "Number of days to keep scan results in cache before expiring"
        default 7
      end

      integer :cache_max_entries do
        description "Maximum number of entries to keep in the scan result cache (LRU eviction)"
        default 100_000
      end
    end
```

**Verification:**
```ruby
# Rails console
rails console

Postal::Config.message_inspection.cache_enabled
# => false (default)

Postal::Config.message_inspection.cache_ttl_days
# => 7 (default)
```

### Step 5: Apply Message Integration Changes

```bash
# Apply the patch
cd ../../lib/postal/message_db
patch -p0 < ../../../doc/scan-result-caching/POC/message.patch
```

**Or manually replace** the `inspect_message` method (around line 520) with:

```ruby
      def inspect_message
        result = nil

        # Try cache lookup first (if enabled)
        if Postal::ScanCacheManager.caching_enabled?(server_id)
          cache_entry = Postal::ScanCacheManager.lookup(raw_message, size)
          if cache_entry
            result = Postal::CachedScanResult.new(cache_entry, self, scope&.to_sym)
            result.record_hit!
            Postal.logger.info "Cache HIT for message #{id} [hash=#{cache_entry.content_hash[0..7]}]"
          else
            Postal.logger.debug "Cache MISS for message #{id}"
          end
        end

        # If no cache hit, perform actual scan
        if result.nil?
          result = MessageInspection.scan(self, scope&.to_sym)

          # Store result in cache for future use (if enabled and eligible)
          if Postal::ScanCacheManager.caching_enabled?(server_id)
            Postal::ScanCacheManager.store(raw_message, size, result)
          end
        end

        # Update the messages table with the results of our inspection
        update(inspected: true, spam_score: result.spam_score, threat: result.threat, threat_details: result.threat_message)

        # Add any spam details into the spam checks database
        database.insert_multi(:spam_checks, [:message_id, :code, :score, :description], result.spam_checks.map { |d| [id, d.code, d.score, d.description] })

        # Return the result
        result
      end
```

### Step 6: Add Tests

```bash
# Copy test files
cp scan_cache_manager_spec.rb ../../spec/lib/postal/
cp scan_result_cache_spec.rb ../../spec/models/
```

### Step 7: Run Tests

```bash
# Run cache-specific tests
bundle exec rspec spec/lib/postal/scan_cache_manager_spec.rb
bundle exec rspec spec/models/scan_result_cache_spec.rb

# Run full test suite to ensure no regressions
bundle exec rspec
```

**Expected Output:**
```
Postal::ScanCacheManager
  .normalize_message
    removes X-Postal-MsgID header
    removes Message-ID header
    removes Date header
    normalizes To header
    preserves From header
    preserves Subject header
    preserves message body
    produces same hash for messages with different recipients
    produces different hash when subject changes
    produces different hash when body changes
  .compute_hash
    returns a 64-character SHA-256 hex digest
    produces consistent hash for same message
  ...

Finished in 2.34 seconds (files took 3.2 seconds to load)
85 examples, 0 failures
```

## Configuration for Testing

### Development/Test Environment

Add to `config/postal.yml` or set environment variables:

```yaml
message_inspection:
  cache_enabled: false  # Start disabled for safety
  cache_ttl_days: 7
  cache_max_entries: 100000
```

Or via environment:
```bash
export MESSAGE_INSPECTION__CACHE_ENABLED=false
export MESSAGE_INSPECTION__CACHE_TTL_DAYS=7
export MESSAGE_INSPECTION__CACHE_MAX_ENTRIES=100000
```

## Manual Testing

### Test 1: Verify Cache Miss (First Scan)

```ruby
# Rails console
rails console

# Enable caching temporarily
allow(Postal::Config.message_inspection).to receive(:cache_enabled?).and_return(true)

# Find or create a test server
server = Server.find(3)  # Use monitoring server for testing

# Create a test message
msg = server.message_db.new_message
msg.rcpt_to = "test@example.com"
msg.mail_from = "sender@example.com"
msg.raw_message = <<~EMAIL
  From: sender@example.com
  To: test@example.com
  Subject: Test Cache Behavior
  
  This is a test message to verify caching works.
EMAIL
msg.save

# First inspection - should be MISS
result1 = msg.inspect_message
# Check logs for: "Cache MISS for message X"

# Verify cache entry was created
cache_entry = ScanResultCache.last
puts "Cache entry created:"
puts "  Hash: #{cache_entry.content_hash[0..7]}..."
puts "  Size: #{cache_entry.message_size}"
puts "  Spam Score: #{cache_entry.spam_score}"
puts "  Hit Count: #{cache_entry.hit_count}"  # Should be 0
```

### Test 2: Verify Cache Hit (Second Identical Message)

```ruby
# Create second identical message (different recipient)
msg2 = server.message_db.new_message
msg2.rcpt_to = "different@example.com"  # Different recipient
msg2.mail_from = "sender@example.com"
msg2.raw_message = <<~EMAIL
  From: sender@example.com
  To: different@example.com
  Subject: Test Cache Behavior
  
  This is a test message to verify caching works.
EMAIL
msg2.save

# Second inspection - should be HIT
result2 = msg2.inspect_message
# Check logs for: "Cache HIT for message X [hash=...]"

# Verify same cache entry was reused
cache_entry.reload
puts "Cache entry reused:"
puts "  Hit Count: #{cache_entry.hit_count}"  # Should be 1

# Verify results match
puts "Results match:"
puts "  Spam Score 1: #{result1.spam_score}"
puts "  Spam Score 2: #{result2.spam_score}"
puts "  Match: #{result1.spam_score == result2.spam_score}"
```

### Test 3: Verify Cache Miss (Different Content)

```ruby
# Create message with different body
msg3 = server.message_db.new_message
msg3.rcpt_to = "test@example.com"
msg3.mail_from = "sender@example.com"
msg3.raw_message = <<~EMAIL
  From: sender@example.com
  To: test@example.com
  Subject: Test Cache Behavior
  
  This is DIFFERENT content, should not hit cache.
EMAIL
msg3.save

# Third inspection - should be MISS (different content)
result3 = msg3.inspect_message
# Check logs for: "Cache MISS for message X"

# Verify new cache entry was created
new_entries = ScanResultCache.count
puts "Total cache entries: #{new_entries}"  # Should be 2
```

### Test 4: Verify Security Policies

```ruby
# Test that threats are NOT cached
# (This requires SpamAssassin/ClamAV to be running and detect a threat)

# Check cache entries
puts "Cache entries with threats: #{ScanResultCache.where(threat: true).count}"
# Should be 0 - threats are never cached

# Check cache entries with high spam scores
threshold = Postal::Config.postal.default_spam_threshold || 5.0
max_cached_score = threshold * 0.8
high_spam = ScanResultCache.where("spam_score > ?", max_cached_score).count
puts "Cache entries with high spam (>#{max_cached_score}): #{high_spam}"
# Should be 0 or very few - high spam scores not cached
```

## Production Readiness Checklist

Before enabling in production:

- [ ] All tests pass (`bundle exec rspec`)
- [ ] Manual testing shows cache HIT/MISS working correctly
- [ ] Configuration is set to `cache_enabled: false` initially
- [ ] Monitoring/alerting configured for cache metrics
- [ ] Rollback procedure documented and understood
- [ ] Team has reviewed implementation
- [ ] Security has approved caching policies

## Troubleshooting

### Issue: Migrations fail with "table already exists"

**Solution:**
```bash
# Check if table exists
mysql -u root -p postal -e "SHOW TABLES LIKE 'scan_result_cache';"

# If it exists, drop it and re-run migration
mysql -u root -p postal -e "DROP TABLE scan_result_cache;"
bundle exec rails db:migrate
```

### Issue: "uninitialized constant ScanResultCache"

**Solution:**
```bash
# Verify model file is in correct location
ls -la app/models/scan_result_cache.rb

# Restart Rails console/server
# The model should auto-load
```

### Issue: "undefined method `message_inspection` for Postal::Config"

**Solution:**
```bash
# Verify config_schema.rb changes were applied
grep -A 10 "group :message_inspection" lib/postal/config_schema.rb

# Restart Rails to reload config
```

### Issue: Cache always returns nil (no hits)

**Debug:**
```ruby
# Check if caching is enabled
Postal::ScanCacheManager.caching_enabled?
# Should return true

# Check cache entries exist
ScanResultCache.count
# Should be > 0

# Check hash computation is consistent
msg = "From: test@test.com\n\nBody"
hash1 = Postal::ScanCacheManager.compute_hash(msg)
hash2 = Postal::ScanCacheManager.compute_hash(msg)
hash1 == hash2
# Should be true

# Check TTL hasn't expired
ScanResultCache.where("scanned_at > ?", 7.days.ago).count
# Should be > 0 if entries are fresh
```

### Issue: Tests fail with "undefined method" errors

**Solution:**
```bash
# Ensure test database is migrated
RAILS_ENV=test bundle exec rails db:migrate

# Ensure all dependencies are loaded
# Add to spec/rails_helper.rb if needed:
require "postal/scan_cache_manager"
require "postal/cached_scan_result"
```

## Performance Monitoring

### Key Metrics to Track

```ruby
# Cache statistics
total_entries = ScanResultCache.count
avg_hit_count = ScanResultCache.average(:hit_count)
cache_size_mb = ScanResultCache.sum(:message_size) / 1024.0 / 1024.0

puts "Cache Statistics:"
puts "  Total Entries: #{total_entries}"
puts "  Avg Hit Count: #{avg_hit_count.round(2)}"
puts "  Cache Size: #{cache_size_mb.round(2)} MB"

# Top cached messages (most reused)
top_cached = ScanResultCache.order(hit_count: :desc).limit(10)
top_cached.each do |entry|
  puts "Hash: #{entry.content_hash[0..7]}... Hits: #{entry.hit_count} Size: #{entry.message_size}"
end

# Cache age distribution
fresh = ScanResultCache.where("scanned_at > ?", 1.day.ago).count
recent = ScanResultCache.where("scanned_at > ?", 3.days.ago).count
old = ScanResultCache.where("scanned_at <= ?", 3.days.ago).count

puts "Cache Age Distribution:"
puts "  < 1 day: #{fresh}"
puts "  1-3 days: #{recent - fresh}"
puts "  > 3 days: #{old}"
```

## Maintenance

### Manual Cache Cleanup

```ruby
# Run maintenance manually
Postal::ScanCacheManager.perform_maintenance

# Or via rake task (create this):
# lib/tasks/cache_maintenance.rake
namespace :cache do
  desc "Perform scan result cache maintenance"
  task maintenance: :environment do
    Postal::ScanCacheManager.perform_maintenance
    puts "Cache maintenance complete"
  end
end

# Then run:
bundle exec rake cache:maintenance
```

### Scheduled Maintenance (Cron)

Add to crontab:
```bash
# Run cache maintenance daily at 3am
0 3 * * * cd /opt/postal && bundle exec rake cache:maintenance
```

## Files Summary

| File | Lines | Purpose | Destination |
|------|-------|---------|-------------|
| `20251231000000_create_scan_result_cache.rb` | 35 | Cache table migration | `db/migrate/` |
| `20251231000001_add_disable_scan_caching_to_servers.rb` | 7 | Per-server opt-out | `db/migrate/` |
| `scan_result_cache.rb` | 57 | ActiveRecord model | `app/models/` |
| `cached_scan_result.rb` | 37 | Result wrapper | `lib/postal/` |
| `scan_cache_manager.rb` | 145 | Core logic | `lib/postal/` |
| `config_schema.patch` | ~20 | Config changes | Apply to `lib/postal/config_schema.rb` |
| `message.patch` | ~35 | Integration | Apply to `lib/postal/message_db/message.rb` |
| `scan_cache_manager_spec.rb` | 370 | Manager tests | `spec/lib/postal/` |
| `scan_result_cache_spec.rb` | 200 | Model tests | `spec/models/` |

**Total Implementation**: ~850 lines of code + tests

## Next Steps After Implementation

1. Run full test suite and ensure no failures
2. Test manually with development server
3. Review with team
4. Prepare for POC deployment (see `../IMPLEMENTATION_SUMMARY.md`)
5. Begin Phase 1: Production logging validation

## Questions?

Refer to:
- `../IMPLEMENTATION_SUMMARY.md` - Full deployment guide
- `../02-TECHNICAL-DESIGN.md` - Architecture details
- `../04-TESTING-STRATEGY.md` - Testing approach
- `../05-DEPLOYMENT-PLAN.md` - Rollout phases

This POC implementation is complete and ready for agent execution.
