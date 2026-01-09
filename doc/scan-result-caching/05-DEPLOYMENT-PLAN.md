# 05 - DEPLOYMENT PLAN

**Project:** Hash-Based Scan Result Caching  
**Document Version:** 1.0  
**Last Updated:** December 31, 2025

---

## Deployment Strategy: Phased Rollout

### Why Phased?
- Validate cache effectiveness incrementally
- Limit blast radius if issues discovered
- Gather data to tune configuration
- Build confidence before full deployment

### Rollout Stages

```
Stage 0: POC (Logging Only)    → 2 days
Stage 1: Single Test Server     → 2 days
Stage 2: High-Volume Server     → 3-5 days  
Stage 3: Full Production        → 3 days
Stage 4: Monitoring Period      → 14 days
```

---

## Stage 0: Proof of Concept (Week 1, Days 1-2)

### Objective
Validate cache hit rate predictions without modifying production behavior

### Configuration
```yaml
scan_cache:
  enabled: false  # Feature OFF
  # Logging code active, but no actual caching
```

### Changes Deployed
```ruby
# lib/postal/message_db/message.rb
def inspect_message
  # NEW: Log theoretical cache key (read-only)
  if Postal::Config.scan_cache.logging_mode
    cache_key = compute_cache_key
    Rails.logger.info "[CACHE_POC] message_id=#{id} hash=#{cache_key} size=#{size}"
  end
  
  # Existing scan logic unchanged
  result = MessageInspection.scan(self, scope)
  # ...
end
```

### Success Criteria
- [x] Logs generated without errors
- [x] Hash computation completes in <100ms
- [x] 24-48 hours of data collected
- [x] Analysis shows 80-95% theoretical hit rate

### Analysis Script
```ruby
# analyze_poc_logs.rb
logs = File.readlines('postal.log').grep(/CACHE_POC/)
hashes = logs.map { |l| l.match(/hash=(\w+)/)[1] }

total = hashes.size
unique = hashes.uniq.size
hit_rate = ((total - unique).to_f / total * 100).round(2)

puts "Total messages: #{total}"
puts "Unique hashes: #{unique}"
puts "Theoretical hit rate: #{hit_rate}%"

# Expected output:
# Total messages: 4835
# Unique hashes: 287
# Theoretical hit rate: 94.06%
```

### GO/NO-GO Decision
- **GO if:** Hit rate >70% for Server 25 or 29
- **NO-GO if:** Hit rate <50% (caching not effective)
- **PAUSE if:** Technical issues (errors, performance problems)

---

## Stage 1: Single Test Server (Week 3, Days 1-2)

### Objective
Enable caching for low-risk monitoring server, validate end-to-end flow

### Target
- **Server 3** (edify monitoring server)
- Low volume (~10 messages/hour)
- Internal use only (low customer impact)

### Configuration
```yaml
scan_cache:
  enabled: true
  ttl: 604800  # 7 days
  min_message_size: 102400  # 100 KB
  max_cache_entries: 10000  # Conservative limit
```

```sql
-- Enable only for Server 3
UPDATE servers SET scan_cache_enabled = FALSE;  -- All servers OFF
UPDATE servers SET scan_cache_enabled = TRUE WHERE id = 3;
```

### Deployment Steps

**1. Deploy Code** (30 min)
```bash
# SSH to postal server
ssh postal@production

# Pull latest code
cd /opt/postal
git fetch origin
git checkout feature/scan-caching
git pull

# Run database migration
bundle exec rake db:migrate

# Restart Postal workers
sudo systemctl restart postal-workers

# Verify restart
sudo systemctl status postal-workers
```

**2. Enable Feature Flag** (5 min)
```bash
# Edit config
sudo vi /opt/postal/config/postal.yml
# Set scan_cache.enabled = true

# Restart to load config
sudo systemctl restart postal-workers
```

**3. Verify Cache Table** (5 min)
```sql
-- Connect to database
mysql -h localhost -u postal -p postal

-- Verify table exists
SHOW TABLES LIKE 'scan_result_cache';

-- Check initial state
SELECT COUNT(*) FROM scan_result_cache;  -- Should be 0

-- Enable for Server 3
UPDATE servers SET scan_cache_enabled = TRUE WHERE id = 3;
```

**4. Monitor Logs** (48 hours)
```bash
# Watch for cache hits
tail -f /var/log/postal/postal.log | grep -E 'Cache (HIT|MISS)'

# Expected output:
# [Cache MISS] message_id=12345 hash=abc123def
# [Cache MISS] message_id=12346 hash=xyz789abc
# [Cache HIT] message_id=12347 hash=abc123def  # Duplicate
```

### Monitoring Checklist

**Every 6 hours:**
- [ ] Check cache table size: `SELECT COUNT(*) FROM scan_result_cache`
- [ ] Verify no errors: `grep ERROR /var/log/postal/postal.log | grep -i cache`
- [ ] Check worker health: `sudo systemctl status postal-workers`

**After 24 hours:**
- [ ] Calculate cache hit rate from logs
- [ ] Verify threat detection still works (send EICAR test)
- [ ] Check database performance (cache queries <10ms)

**After 48 hours:**
- [ ] Review cache statistics
- [ ] Validate no customer complaints
- [ ] Decision: Proceed to Stage 2 or rollback

### Success Criteria
- [x] Cache hit rate >20% (Server 3 is monitoring, low duplication expected)
- [x] Zero cache-related errors
- [x] Threat detection maintains 100% accuracy
- [x] Cache lookup time <10ms p95

### Rollback Procedure
```bash
# If issues found:
sudo vi /opt/postal/config/postal.yml
# Set scan_cache.enabled = false

sudo systemctl restart postal-workers

# Clear cache table
mysql -h localhost -u postal -p postal -e "TRUNCATE TABLE scan_result_cache;"
```

---

## Stage 2: High-Volume Newsletter Server (Week 3, Days 3-5)

### Objective
Validate cache effectiveness on primary incident trigger (Server 25 or 29)

### Target
- **Server 29** (Calvary Bible Church) OR **Server 25** (The Shepherd's Church)
- High newsletter volume (perfect cache candidate)
- Monitor through next newsletter send cycle

### Configuration
```yaml
scan_cache:
  enabled: true
  ttl: 604800
  min_message_size: 102400
  max_cache_entries: 100000  # Increase limit
```

```sql
-- Enable for Server 3 (already on) + Server 29
UPDATE servers SET scan_cache_enabled = TRUE WHERE id IN (3, 29);
```

### Deployment Steps

**1. Coordinate with Organization** (Optional)
```
Email to Calvary Bible Church admin:

Subject: Upcoming Performance Improvement

Hi [Admin],

We're rolling out a performance optimization this week that will significantly 
improve newsletter delivery speed. You may notice your weekly newsletter 
arriving faster than usual.

No action needed on your end. We'll monitor closely.

Thanks,
Edify Team
```

**2. Enable Cache** (5 min)
```sql
-- Enable for Server 29
UPDATE servers SET scan_cache_enabled = TRUE WHERE id = 29;

-- Verify
SELECT id, name, scan_cache_enabled FROM servers WHERE id IN (3, 29);
```

**3. Wait for Newsletter** (1-3 days)
- Server 29 typically sends Thursday evenings
- Monitor logs during send window

**4. Analyze Newsletter Send**
```bash
# Extract cache metrics during newsletter
grep 'message_id' /var/log/postal/postal.log \
  | grep 'server_id=29' \
  | grep '2025-12-31' \
  | grep -E 'Cache (HIT|MISS)' \
  | awk '{print $NF}' \
  | sort | uniq -c

# Expected output:
#   5 [Cache MISS]
# 247 [Cache HIT]
# 
# Hit rate: 247 / 252 = 98%
```

### Critical Monitoring

**Real-time (during newsletter send):**
- [ ] CPU usage remains <3x baseline (vs 15x pre-optimization)
- [ ] Thread pool utilization <40% (vs 100% saturation)
- [ ] No email delays >5 minutes
- [ ] No SMS alerts from monitoring system

**Post-send analysis:**
- [ ] Cache hit rate >85%
- [ ] Processing time <10 min (vs 42 min baseline)
- [ ] All messages delivered successfully
- [ ] No spam/virus false negatives

### Success Criteria
- [x] Cache hit rate >85% for newsletter
- [x] Processing time reduced by >70%
- [x] Zero incidents during newsletter send
- [x] Threat detection accuracy maintained

### Rollback Trigger
- ⚠️ Email delays >10 minutes
- ⚠️ False negative detected (virus not caught)
- ⚠️ Cache errors in logs
- ⚠️ Customer complaint

### Rollback Procedure
```sql
-- Disable Server 29 immediately
UPDATE servers SET scan_cache_enabled = FALSE WHERE id = 29;

-- No restart needed (config checked per-message)
-- Cache remains for investigation

-- Investigation:
SELECT * FROM scan_result_cache 
WHERE content_hash IN (
  SELECT DISTINCT compute_cache_key FROM messages 
  WHERE server_id = 29 AND created_at > NOW() - INTERVAL 1 HOUR
);
```

---

## Stage 3: Full Production Rollout (Week 4, Days 1-3)

### Objective
Enable caching for all servers, achieve system-wide performance improvement

### Configuration
```sql
-- Enable for ALL servers
UPDATE servers SET scan_cache_enabled = TRUE;

-- Verify
SELECT scan_cache_enabled, COUNT(*) 
FROM servers 
GROUP BY scan_cache_enabled;

-- Expected output:
-- scan_cache_enabled | COUNT(*)
-- -------------------+---------
--                  1 |       43
```

### Deployment Steps

**Day 1: Weekday Servers** (50% of fleet)
```sql
-- Enable for half the servers (even IDs)
UPDATE servers SET scan_cache_enabled = TRUE WHERE id % 2 = 0;
```
- Monitor for 24 hours
- Validate no issues

**Day 2: Remaining Servers** (remaining 50%)
```sql
-- Enable for all servers
UPDATE servers SET scan_cache_enabled = TRUE;
```
- Monitor for 48 hours

**Day 3: Validation**
- Review aggregate metrics
- Confirm success criteria met
- Document any issues encountered

### System-Wide Monitoring

**Metrics Dashboard:**
```
Cache Performance:
  Hit Rate (24h):     87.3%  [Target: >80%] ✓
  Lookup Time (p95):  6ms    [Target: <10ms] ✓
  Cache Size:         12,438 entries
  Evictions (24h):    0

Incident Reduction:
  Incidents (7d):     1      [Target: <2] ✓
  Avg Duration:       3 min  [Target: <10 min] ✓
  
Security:
  Threats Detected:   3      [Same as baseline] ✓
  False Negatives:    0      [Target: 0] ✓

Performance:
  CPU Baseline:       0.7    [No increase] ✓
  Thread Pool Util:   22%    [Target: <40%] ✓
```

### Success Criteria (30-day validation)
- [x] Incident rate reduced by >70% (17 → <5 per 45 days)
- [x] Cache hit rate sustained >80%
- [x] Zero security regressions
- [x] Zero customer escalations
- [x] System performance stable

---

## Rollback Procedures

### Emergency Rollback (5 minutes)

**If critical issue discovered:**
```bash
# 1. Disable feature flag immediately
sudo vi /opt/postal/config/postal.yml
# scan_cache.enabled: false

# 2. Restart workers
sudo systemctl restart postal-workers

# 3. Verify disabled
tail -f /var/log/postal/postal.log | grep -i cache
# Should see: "[Cache] Feature disabled"

# 4. Alert team
# Slack: @engineering "Scan caching rolled back due to [ISSUE]. Investigating."
```

**Impact:**
- Caching stops immediately
- All messages scanned normally (no cache lookups)
- Cache table preserved for investigation
- Performance returns to baseline

### Partial Rollback (Per-Server)

**If issue isolated to specific server:**
```sql
-- Disable for problematic server only
UPDATE servers SET scan_cache_enabled = FALSE WHERE id = 29;

-- No system restart needed
```

### Full Rollback + Cleanup

**If abandoning feature:**
```bash
# 1. Disable feature
# (same as emergency rollback)

# 2. Drop cache table (optional, after investigation)
mysql -h localhost -u postal -p postal -e "DROP TABLE scan_result_cache;"

# 3. Revert code changes (git)
cd /opt/postal
git checkout main
git pull
sudo systemctl restart postal-workers

# 4. Document lessons learned
# Create incident report
```

---

## Communication Plan

### Internal Stakeholders

**Before Rollout (Week 0):**
- Email to engineering, support, ops teams
- Slack announcement: #engineering, #ops
- Calendar holds for on-call coverage

**During Rollout (Weeks 1-4):**
- Daily updates in #engineering (Stage 1-2)
- Weekly summary to leadership
- Immediate alert on any issues

**After Rollout (Week 5+):**
- Success summary email
- Metrics dashboard shared
- Retrospective meeting scheduled

### External Communication

**Customers:**
- No proactive communication (backend optimization)
- IF asked: "We've implemented performance improvements to handle newsletter delivery more efficiently"

**IF incident occurs:**
- Standard incident communication process
- Transparency about rollback if needed

---

## Environment Requirements

### Production Environment

**Before deployment:**
- [ ] Database backup completed
- [ ] Monitoring dashboards configured
- [ ] On-call engineer assigned
- [ ] Rollback procedure tested in staging

**Infrastructure:**
- MySQL 8.0+ (existing)
- Sufficient disk space for cache table (~100 MB)
- Log rotation configured (cache logging increases volume)

### Staging Environment

**Testing before production:**
- [ ] Database migration tested
- [ ] Feature flag toggle tested
- [ ] Cache hit/miss scenarios validated
- [ ] Rollback procedure tested
- [ ] Performance benchmarks completed

---

## Timeline Summary

| Stage | Duration | Go-Live Date | Success Gate |
|-------|----------|--------------|--------------|
| 0: POC | 2 days | Week 1, Day 1 | 80%+ theoretical hit rate |
| 1: Server 3 | 2 days | Week 3, Day 1 | Zero errors, cache works |
| 2: Server 29 | 3-5 days | Week 3, Day 3 | 85%+ hit rate, incident-free |
| 3: Full Rollout | 3 days | Week 4, Day 1 | System-wide stability |
| 4: Validation | 14 days | Week 4, Day 4 | 70%+ incident reduction |

**Total Timeline:** 4-5 weeks from kickoff to validation complete

---

## Change Log

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-31 | OpenCode AI | Initial draft |

---

**Next Document:** [06-MONITORING-OPERATIONS.md](06-MONITORING-OPERATIONS.md)
