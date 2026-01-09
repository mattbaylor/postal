# 06 - MONITORING & OPERATIONS

**Project:** Hash-Based Scan Result Caching  
**Document Version:** 1.0  
**Last Updated:** December 31, 2025

---

## Key Metrics

### Cache Performance Metrics

| Metric | Target | Alert Threshold | Dashboard |
|--------|--------|-----------------|-----------|
| Cache Hit Rate | >80% | <50% for 1 hour | Primary |
| Cache Lookup Time (p95) | <10ms | >50ms for 10 min | Performance |
| Cache Size (entries) | <100,000 | >90,000 | Capacity |
| Cache Memory Usage | <200 MB | >500 MB | Capacity |
| Eviction Rate | <1,000/day | >5,000/day | Health |

### Security Metrics

| Metric | Target | Alert Threshold | Dashboard |
|--------|--------|-----------------|-----------|
| Threat Detection Rate | Baseline | -5% vs baseline | Security |
| Threats Cached Count | 0 | >0 | Security |
| False Negative Count | 0 | >0 | Security |
| Cache Age (p95) | <3 days | >7 days | Security |

### Business Metrics

| Metric | Target | Alert Threshold | Dashboard |
|--------|--------|-----------------|-----------|
| Email Incidents (30d) | <10 | >15 | Executive |
| Avg Incident Duration | <10 min | >20 min | Executive |
| Thread Pool Utilization | <40% | >80% | Performance |
| Newsletter Processing Time | <10 min | >20 min | Business |

---

## Logging

### Log Levels

**INFO:** Normal operations
```ruby
Rails.logger.info "[Cache HIT] message_id=#{id} hash=#{cache_key[0..8]} age=#{cache_age}s"
Rails.logger.info "[Cache MISS] message_id=#{id} hash=#{cache_key[0..8]}"
Rails.logger.info "[Cache STORE] hash=#{cache_key[0..8]} size=#{size} spam_score=#{spam_score}"
```

**WARN:** Degraded performance
```ruby
Rails.logger.warn "[Cache] Eviction triggered, size=#{cache_size}"
Rails.logger.warn "[Cache] Lookup slow: #{lookup_time}ms for hash=#{cache_key[0..8]}"
Rails.logger.warn "[Cache] Hit rate below target: #{hit_rate}%"
```

**ERROR:** Failures
```ruby
Rails.logger.error "[Cache] Store failed: #{e.message}"
Rails.logger.error "[Cache] Database timeout on lookup"
```

**CRITICAL:** Security issues
```ruby
Rails.logger.critical "[Cache] COLLISION DETECTED: hash=#{cache_key}"
Rails.logger.critical "[Cache] THREAT CACHED: hash=#{cache_key}"
```

### Log Queries

**Calculate hit rate:**
```bash
grep -E 'Cache (HIT|MISS)' postal.log \
  | tail -1000 \
  | grep -c 'HIT' \
  | awk '{print ($1/1000)*100 "%"}'
```

**Find slow lookups:**
```bash
grep 'Cache.*slow' postal.log | tail -20
```

**Check for threats:**
```bash
grep 'THREAT CACHED' postal.log
# Should be empty!
```

---

## Alerting Rules

### Critical Alerts (PagerDuty / Immediate Response)

**Alert: Threat Cached**
```yaml
condition: log_contains("THREAT CACHED")
severity: critical
action: page_on_call
message: "SECURITY: Threat was cached. Immediate investigation required."
```

**Alert: Cache Collision**
```yaml
condition: log_contains("COLLISION DETECTED")
severity: critical  
action: page_on_call + notify_security_team
message: "Hash collision detected. Potential attack or bug."
```

**Alert: Cache Hit Rate Collapsed**
```yaml
condition: cache_hit_rate < 20% for 30 minutes
severity: critical
action: page_on_call
message: "Cache hit rate dropped to {value}%. Feature may not be working."
```

### Warning Alerts (Slack / Business Hours)

**Alert: Hit Rate Below Target**
```yaml
condition: cache_hit_rate < 60% for 2 hours
severity: warning
action: slack_#engineering
message: "Cache hit rate at {value}% (target: 80%). Investigate if sustained."
```

**Alert: High Eviction Rate**
```yaml
condition: evictions_per_hour > 500
severity: warning
action: slack_#ops
message: "High cache eviction rate. Consider increasing max_cache_entries."
```

**Alert: Slow Cache Lookups**
```yaml
condition: p95_lookup_time > 50ms for 15 minutes
severity: warning
action: slack_#ops
message: "Cache lookups slow ({value}ms p95). Check database performance."
```

---

## Dashboards

### Primary Dashboard: Cache Performance

**Panels:**
1. **Hit Rate Timeline** (line chart)
   - Last 24 hours
   - Target line at 80%
   - Color: Green if >80%, Yellow if 60-80%, Red if <60%

2. **Cache Operations** (stacked area)
   - Hits vs Misses vs Stores
   - Shows volume distribution

3. **Lookup Performance** (histogram)
   - p50, p95, p99 lookup times
   - Target line at 10ms

4. **Cache Size** (line + gauge)
   - Entry count over time
   - Gauge showing % of max (100k limit)

5. **Top Cached Content** (table)
   - Hash (truncated) | Hit Count | Size | Age
   - Identifies highly duplicated content

### Security Dashboard

**Panels:**
1. **Threat Detection** (counter + timeline)
   - Total threats detected (cached vs non-cached)
   - Should be: 100% non-cached

2. **Cache Age Distribution** (histogram)
   - Shows how old cached entries are
   - Alert if many entries near TTL

3. **Security Events** (event log)
   - Collision detections
   - Threat cache attempts
   - Signature invalidations

### Executive Dashboard

**Panels:**
1. **Incident Reduction** (line chart)
   - Incidents per week (before vs after)
   - Target line

2. **Newsletter Performance** (bar chart)
   - Processing time before/after
   - Server 25, 29 highlighted

3. **System Health** (gauges)
   - Thread pool utilization
   - CPU usage
   - Cache hit rate

---

## Operational Runbooks

### Runbook 1: Cache Hit Rate Low

**Symptoms:**
- Hit rate <60% sustained
- Expected duplicates not hitting cache

**Investigation Steps:**
1. Check if feature enabled globally:
   ```sql
   SELECT scan_cache_enabled, COUNT(*) 
   FROM servers 
   GROUP BY scan_cache_enabled;
   ```

2. Review recent cache entries:
   ```sql
   SELECT content_hash, hit_count, message_size, 
          FROM_UNIXTIME(scan_timestamp) as scanned_at
   FROM scan_result_cache
   ORDER BY scan_timestamp DESC
   LIMIT 20;
   ```

3. Check normalization working:
   ```bash
   # Extract recent hashes from logs
   grep 'Cache' postal.log | grep 'hash=' | tail -100
   # Look for duplicate hashes (should exist for newsletters)
   ```

4. Verify min_message_size not filtering:
   ```yaml
   # Check config
   min_message_size: 102400  # 100KB
   # If newsletters < 100KB, they won't be cached
   ```

**Resolution:**
- Adjust min_message_size if needed
- Verify normalization logic (unit test)
- Check if customers changed newsletter patterns

---

### Runbook 2: Slow Cache Lookups

**Symptoms:**
- Lookup time >50ms p95
- Database CPU high

**Investigation Steps:**
1. Check database load:
   ```sql
   SHOW PROCESSLIST;
   -- Look for slow SELECT on scan_result_cache
   ```

2. Verify index usage:
   ```sql
   EXPLAIN SELECT * FROM scan_result_cache 
   WHERE content_hash = 'abc123...' LIMIT 1;
   -- Should use idx_content_hash (key lookup)
   ```

3. Check cache size:
   ```sql
   SELECT COUNT(*), 
          SUM(LENGTH(spam_checks))/1024/1024 as size_mb
   FROM scan_result_cache;
   ```

4. Review slow query log:
   ```bash
   sudo tail -100 /var/log/mysql/slow-query.log | grep scan_result_cache
   ```

**Resolution:**
- Add missing indexes if needed
- Tune MySQL buffer pool size
- Consider Redis layer (future optimization)
- Aggressive eviction if cache too large

---

### Runbook 3: Threat Cached (CRITICAL)

**Symptoms:**
- Alert: "THREAT CACHED"
- Potential false negative risk

**Immediate Actions:**
1. **Disable caching immediately:**
   ```yaml
   scan_cache.enabled: false
   sudo systemctl restart postal-workers
   ```

2. **Find affected entries:**
   ```sql
   SELECT * FROM scan_result_cache WHERE threat = 1;
   -- Should be empty (threats shouldn't be cached)
   ```

3. **Identify root cause:**
   ```ruby
   # Check code logic
   def should_cache_result?(result)
     !result.threat  # This line must exist and be correct
   end
   ```

4. **Clear cache:**
   ```sql
   TRUNCATE TABLE scan_result_cache;
   ```

5. **Incident report:**
   - Document how threat was cached (bug? edge case?)
   - Check if any messages delivered with false negative
   - Notify security team

**Follow-up:**
- Fix bug in code
- Add integration test to prevent regression
- Re-deploy with fix
- Monitor closely

---

### Runbook 4: Cache Overflow

**Symptoms:**
- Cache size approaching limit (>90k entries)
- High eviction rate

**Investigation:**
1. Check growth rate:
   ```sql
   SELECT DATE(FROM_UNIXTIME(scan_timestamp)) as date,
          COUNT(*) as entries
   FROM scan_result_cache
   GROUP BY date
   ORDER BY date DESC
   LIMIT 7;
   -- Expected: ~1000-2000 entries/day
   ```

2. Identify large entries:
   ```sql
   SELECT content_hash, message_size, hit_count,
          LENGTH(spam_checks) as spam_checks_size
   FROM scan_result_cache
   ORDER BY message_size DESC
   LIMIT 20;
   ```

3. Check for abnormal pattern:
   ```bash
   # Are unique messages being created excessively?
   grep 'Cache MISS' postal.log | wc -l
   ```

**Resolution:**
- Increase max_cache_entries if disk allows:
  ```yaml
  max_cache_entries: 200000  # Was 100,000
  ```
- Lower min_message_size to reduce entries:
  ```yaml
  min_message_size: 1048576  # 1MB (was 100KB)
  ```
- Implement more aggressive LRU:
  ```ruby
  evict_lru(percentage: 0.20)  # Evict 20% instead of 10%
  ```

---

## Maintenance Tasks

### Daily Automated Tasks

**Cache Cleanup (scheduled job):**
```ruby
# config/schedule.rb
every 1.day, at: '2:00 AM' do
  rake 'postal:cache:cleanup'
end

# lib/tasks/postal/cache.rake
namespace :postal do
  namespace :cache do
    task cleanup: :environment do
      deleted_expired = ScanResultCache.cleanup_expired
      Rails.logger.info "Cleaned up #{deleted_expired} expired cache entries"
      
      if ScanResultCache.count > Postal::Config.scan_cache.max_cache_entries
        evicted = ScanResultCache.evict_lru
        Rails.logger.info "Evicted #{evicted} LRU cache entries"
      end
    end
  end
end
```

**Cache Statistics (daily report):**
```ruby
every 1.day, at: '9:00 AM' do
  rake 'postal:cache:report'
end

# Sends email with:
# - Cache hit rate (24h)
# - Total entries, size
# - Top 10 cached hashes by hit count
# - Eviction count
```

### Weekly Manual Tasks

**Review Performance:**
- [ ] Check dashboards for anomalies
- [ ] Review security logs (collision attempts, threats)
- [ ] Validate hit rate targets met
- [ ] Review incident count (should be trending down)

**Capacity Planning:**
- [ ] Project cache growth (entries/week)
- [ ] Estimate time to hit max_cache_entries
- [ ] Plan increase if needed

### Monthly Tasks

**Performance Tuning:**
- [ ] Analyze hit rate by server (identify low performers)
- [ ] Review TTL (7 days optimal?)
- [ ] Consider Redis layer if lookups >10ms

**Security Review:**
- [ ] Verify threat detection rate matches baseline
- [ ] Review audit logs (cache usage patterns)
- [ ] Check for any collision attempts

---

## Troubleshooting Guide

### Issue: Feature Not Working

**Check:**
```bash
# 1. Feature enabled?
grep 'scan_cache' /opt/postal/config/postal.yml

# 2. Database migration applied?
mysql -u postal -p postal -e "SHOW TABLES LIKE 'scan_result_cache';"

# 3. Workers restarted after config change?
sudo systemctl status postal-workers

# 4. Servers enabled?
mysql -u postal -p postal -e "SELECT scan_cache_enabled, COUNT(*) FROM servers GROUP BY scan_cache_enabled;"

# 5. Logs showing cache activity?
tail -100 /var/log/postal/postal.log | grep -i cache
```

### Issue: High False Negative Rate

**Investigation:**
```sql
-- Find messages that were cached but are threats
SELECT m.id, m.threat, m.threat_details, m.spam_score
FROM messages m
WHERE m.inspected = 1
  AND m.threat = 1
  AND EXISTS (
    SELECT 1 FROM scan_result_cache c
    WHERE c.content_hash = m.compute_cache_key
      AND c.threat = 0  -- Cached as clean!
  );
```

**If found:** CRITICAL BUG - disable caching, investigate

### Issue: Database Deadlocks

**Symptoms:**
```
ERROR: Deadlock found when trying to get lock; try restarting transaction
```

**Investigation:**
```sql
-- Check for concurrent cache updates
SHOW ENGINE INNODB STATUS\G
-- Look for "LATEST DETECTED DEADLOCK" section
```

**Resolution:**
- Retry logic (already in Rails)
- Reduce concurrent workers if persistent
- Consider row-level locking optimization

---

## Performance Baselines

### Expected Performance

| Scenario | Baseline (No Cache) | With Cache (80% Hit) | Improvement |
|----------|---------------------|----------------------|-------------|
| Newsletter (252 msg) | 42 minutes | 5 minutes | 8.4x faster |
| Mixed workload | 100 msg/hr | 400 msg/hr | 4x throughput |
| Cache lookup | N/A | 5ms p95 | N/A |
| Hash computation | N/A | 70ms | Negligible |

### Capacity Estimates

| Metric | Current | 6 Months | 12 Months |
|--------|---------|----------|-----------|
| Messages/day | 10,000 | 15,000 | 25,000 |
| Unique content/day | 1,000 | 1,500 | 2,500 |
| Cache size (entries) | 20,000 | 40,000 | 60,000 |
| Cache size (MB) | 15 MB | 30 MB | 45 MB |

---

## Change Log

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-31 | OpenCode AI | Initial draft |

---

**Next Document:** [07-IMPLEMENTATION-GUIDE.md](07-IMPLEMENTATION-GUIDE.md)
