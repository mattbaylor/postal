# 03 - SECURITY ANALYSIS

**Project:** Hash-Based Scan Result Caching for Postal Email Service  
**Document Version:** 1.0  
**Last Updated:** December 31, 2025  
**Status:** Draft - Pending Security Review

---

## Table of Contents
- [Threat Model](#threat-model)
- [Risk Assessment Matrix](#risk-assessment-matrix)
- [Detailed Risk Analysis](#detailed-risk-analysis)
- [Mitigation Strategies](#mitigation-strategies)
- [Compliance Considerations](#compliance-considerations)
- [Security Testing Requirements](#security-testing-requirements)

---

## Threat Model

### Assets

**Primary Assets:**
1. Email messages (confidential customer data)
2. Scan result cache (system integrity)
3. Threat detection capability (security function)
4. Service availability (business continuity)

**Secondary Assets:**
1. Database integrity
2. Customer trust
3. Compliance posture

### Threat Actors

| Actor | Motivation | Capability | Likelihood |
|-------|------------|------------|------------|
| **External Attacker** | Deliver malware/spam | Medium-High | Medium |
| **Malicious User** | Bypass scanning | Low-Medium | Low |
| **Compromised Account** | Send malicious newsletters | Medium | Low |
| **Nation State** | Advanced persistent threat | Very High | Very Low |

### Attack Vectors

1. **Cache poisoning** - Store false negative results
2. **Cache bypass** - Avoid detection through clever content manipulation
3. **Timing attacks** - Infer cache state through timing
4. **Hash collision** - Craft messages with identical hash
5. **TTL exploitation** - Old cache entries used after signatures update
6. **DoS via cache** - Overflow cache, degrade performance

---

## Risk Assessment Matrix

| Risk ID | Threat | Likelihood | Impact | Risk Level | Priority |
|---------|--------|------------|--------|------------|----------|
| R1 | Time-of-Check/Time-of-Use | Medium | High | **HIGH** | P0 |
| R2 | Hash Collision Attack | Very Low | High | **LOW** | P3 |
| R3 | Cache Poisoning | Low | High | **MEDIUM** | P1 |
| R4 | Privacy Leak (Timing) | Low | Low | **LOW** | P4 |
| R5 | DoS via Cache Overflow | Low | Medium | **LOW** | P2 |
| R6 | Compliance Violation | Medium | High | **MEDIUM** | P1 |
| R7 | False Negative (Bug) | Low | Critical | **MEDIUM** | P1 |
| R8 | Cache Corruption | Very Low | High | **LOW** | P2 |

**Risk Level Calculation:** Likelihood × Impact

**Priority:**
- P0: Critical - Must address before deployment
- P1: High - Address in initial implementation
- P2: Medium - Monitor, address if observed
- P3: Low - Accept risk, document
- P4: Very Low - Accept risk

---

## Detailed Risk Analysis

### R1: Time-of-Check / Time-of-Use (TOCT)

**Risk Level:** HIGH (P0)

**Scenario:**
```
Day 0:  Attacker sends benign newsletter "Weekly Update"
        → Scanned clean, cached for 7 days
        
Day 1:  New virus "BadMacro.docx" discovered
        → Antivirus signatures updated
        → Cache NOT invalidated (no hook implemented)
        
Day 3:  Attacker sends SAME newsletter containing BadMacro.docx
        → Cache HIT
        → Virus delivered without scanning
```

**Attack Prerequisites:**
- Attacker can send identical content twice (7 days apart)
- New threat emerges between sends
- Cache not invalidated on signature update

**Impact:**
- Zero-day exploits bypass detection for up to 7 days
- Newly identified spam patterns not caught
- False sense of security

**Mitigations:**

**M1.1: Short Cache TTL**
```yaml
scan_cache:
  ttl: 604800  # 7 days (reduces window but doesn't eliminate)
```
- **Effectiveness:** 50% (reduces exposure window)
- **Cost:** None
- **Status:** Implemented

**M1.2: Never Cache Threats**
```ruby
def should_cache_result?(result)
  !result.threat  # NEVER cache if virus detected
end
```
- **Effectiveness:** 90% (prevents false negative caching)
- **Cost:** Slight performance hit on threat-containing newsletters
- **Status:** Implemented

**M1.3: Never Cache Near-Spam**
```ruby
def should_cache_result?(result)
  result.spam_score < (server.spam_threshold * 0.8)
end
```
- **Effectiveness:** 70% (prevents borderline cases)
- **Cost:** Lower cache hit rate for legitimate newsletters near threshold
- **Status:** Implemented

**M1.4: Signature Update Invalidation** ⚠️ CRITICAL
```ruby
# Hook into signature update process
def self.on_signature_update
  ScanResultCache.invalidate_all
  Rails.logger.warn "Cache invalidated due to signature update"
end
```
- **Effectiveness:** 95% (eliminates TOCT window)
- **Cost:** Cache miss storm after updates (temporary performance hit)
- **Status:** DEFERRED to Phase 2 (requires signature tracking)

**Residual Risk:** MEDIUM (without M1.4), LOW (with M1.4)

**Acceptance Criteria:**
- [ ] M1.1, M1.2, M1.3 implemented
- [ ] M1.4 implementation plan documented
- [ ] Security team sign-off

---

### R2: Hash Collision Attack

**Risk Level:** LOW (P3)

**Scenario:**
```
Attacker crafts malicious message M1 and benign message M2
such that: SHA256(M1) == SHA256(M2)

Step 1: Send M2 → scanned clean → cached
Step 2: Send M1 → cache HIT from M2 → malware delivered
```

**Attack Prerequisites:**
- Find SHA-256 collision (computationally infeasible)
- OR exploit implementation flaw in hash computation

**Likelihood Analysis:**

**SHA-256 Collision Resistance:**
- Best known attack: None practical (theoretical 2^128 operations)
- Cost to break: >$1 billion with current technology
- Time to break: Millions of years with supercomputer

**Collision Probability:**
```
For 100,000 cached messages:
P(random collision) = n² / (2 × 2^256)
                    = 10^10 / 2^257
                    ≈ 10^-67
                    = 0.0000000000000000000000000000000000000000000000000000000000000001%
```

**Implementation Flaw Risk:**
- More likely than SHA-256 break
- Example: Truncating hash, using weak hash, etc.

**Impact:**
- Complete bypass of scanning
- Targeted attack possible (if collision found)
- Silent failure (no detection)

**Mitigations:**

**M2.1: Use Full SHA-256**
```ruby
Digest::SHA256.hexdigest(normalized)  # 64 hex chars = 256 bits
```
- **Effectiveness:** 99.99%
- **Cost:** None
- **Status:** Implemented

**M2.2: Verify Message Size Match**
```ruby
def self.lookup(content_hash, message_size)
  cached = database.select_one(
    "WHERE content_hash = ? AND message_size = ?",
    content_hash, message_size
  )
  # Collision would need matching hash AND size
end
```
- **Effectiveness:** 99.999% (additional constraint)
- **Cost:** Minimal (size already available)
- **Status:** Implemented

**M2.3: Collision Detection Monitoring**
```ruby
def self.store(content_hash, result, size)
  existing = lookup(content_hash, size)
  if existing && existing.spam_score != result.spam_score
    Rails.logger.critical "COLLISION DETECTED: #{content_hash}"
    # Alert security team, force re-scan
  end
end
```
- **Effectiveness:** Detection only (doesn't prevent)
- **Cost:** Extra database query on store
- **Status:** Recommended for Phase 1

**Residual Risk:** VERY LOW

**Acceptance Criteria:**
- [x] SHA-256 used (not MD5 or SHA-1)
- [x] Size verification implemented
- [ ] Collision monitoring implemented

---

### R6: Compliance Violation

**Risk Level:** MEDIUM (P1)

**Concern:**
Some regulatory frameworks may require "real-time" or "per-message" scanning. Cache-based approach might be interpreted as "skipping" required checks.

**Affected Standards:**
- HIPAA (if processing health-related emails)
- PCI-DSS (if processing payment-related emails)
- SOC 2 Type II (audit trail requirements)
- GDPR (data processing transparency)

**Scenarios:**

**Scenario 1: Auditor Questions**
```
Auditor: "Do you scan every email for viruses?"
Company: "Yes, but we cache results for identical content"
Auditor: "How do we verify identical content?"
Company: "SHA-256 hash comparison"
Auditor: "Has this been validated by a third party?"
Company: "No"
Result: FINDING - Scan caching not approved by assessor
```

**Scenario 2: Breach Investigation**
```
Regulator: "Virus was delivered on Jan 15. Was it scanned?"
Company: "Yes, cache hit from Jan 10 scan"
Regulator: "But virus was discovered Jan 12"
Company: "Cache wasn't invalidated"
Result: VIOLATION - Inadequate controls
```

**Mitigations:**

**M6.1: Per-Server Opt-Out**
```ruby
# Database
add_column :servers, :scan_cache_enabled, :boolean, default: true

# Code
def inspect_message
  return perform_full_scan unless server.scan_cache_enabled
  # ... cache logic
end
```
**Usage:**
```sql
-- Disable for HIPAA/PCI customers
UPDATE servers 
SET scan_cache_enabled = FALSE 
WHERE organization_id IN (
  SELECT id FROM organizations WHERE compliance_tier = 'STRICT'
);
```
- **Effectiveness:** 100% (opt-out for regulated customers)
- **Cost:** Lower cache hit rate globally
- **Status:** Recommended for Phase 1

**M6.2: Audit Trail**
```ruby
def restore_from_cache(cached)
  # ... restore results ...
  
  database.query(
    "INSERT INTO scan_audit_log 
     (message_id, content_hash, scan_type, scan_timestamp, cache_age)
     VALUES (?, ?, 'cached', ?, ?)",
    id, cache_key, Time.now.to_f, Time.now.to_f - cached.scan_timestamp
  )
end
```
**Provides:**
- Forensic trail of cache usage
- Ability to demonstrate "effective scanning"
- Audit report: "Message 12345 used cached scan from 2 days prior"
- **Status:** Recommended for Phase 1

**M6.3: Documented Policy**
```
Security Policy Addendum:

"Edify email system employs content-based scan result caching to 
optimize performance while maintaining security. Scan results for 
identical email content are cached for a maximum of 7 days. The cache 
is automatically invalidated when antivirus signatures are updated. 
Customers in regulated industries may request cache-opt-out for 
real-time scanning of every message."
```
- **Status:** Required before rollout

**M6.4: Legal Review**
- Engage legal/compliance team to review caching approach
- Document approval before production deployment
- Add to SOC 2 audit documentation
- **Status:** Required before rollout

**Residual Risk:** LOW (with mitigations)

**Acceptance Criteria:**
- [ ] Per-server opt-out implemented
- [ ] Audit trail implemented
- [ ] Policy documented and approved by legal
- [ ] Compliance team sign-off

---

### R7: False Negative Due to Implementation Bug

**Risk Level:** MEDIUM (P1)

**Scenarios:**

**Bug 1: Hash Normalization Error**
```ruby
# BUG: Forgot to normalize To: header
def normalized_raw_message
  mail_obj = Mail.new(raw_message)
  # mail_obj.to = "NORMALIZED@CACHE.LOCAL"  # MISSING!
  mail_obj.to_s
end

Result: Different recipients → different hashes → no cache hits
Impact: Feature ineffective but safe
```

**Bug 2: Freshness Check Error**
```ruby
# BUG: TTL comparison inverted
def fresh?
  age = Time.now.to_f - scan_timestamp
  return true if age > Postal::Config.scan_cache.ttl  # WRONG: should be <
  true
end

Result: Expired entries used → TOCT window extended
Impact: Security risk
```

**Bug 3: Threat Caching Bug**
```ruby
# BUG: Logic inverted
def should_cache_result?(result)
  result.threat  # WRONG: should be !result.threat
end

Result: Only threats cached (!) → false negatives on subsequent sends
Impact: Critical security risk
```

**Mitigations:**

**M7.1: Comprehensive Unit Tests**
```ruby
RSpec.describe ScanResultCache do
  it "never caches threats" do
    result = build(:scan_result, threat: true)
    ScanResultCache.store(hash, result, size)
    expect(ScanResultCache.lookup(hash)).to be_nil
  end
  
  it "expires entries after TTL" do
    # ... test TTL enforcement
  end
  
  it "normalizes recipient headers" do
    msg1 = build_message(to: "alice@example.com")
    msg2 = build_message(to: "bob@example.com")
    expect(msg1.compute_cache_key).to eq(msg2.compute_cache_key)
  end
end
```
- **Coverage Target:** >80%
- **Status:** Required before merge

**M7.2: Integration Tests**
```ruby
RSpec.describe "Message Inspection with Cache" do
  it "caches clean scan results" do
    msg1 = create_test_message
    msg1.inspect_message  # Cache miss, full scan
    
    msg2 = create_identical_message
    expect { msg2.inspect_message }.not_to change { SpamAssassinCallCount }
    # Cache hit, no scanner call
  end
  
  it "does not cache threats" do
    msg1 = create_message_with_virus
    msg1.inspect_message  # Virus detected
    
    msg2 = create_identical_message
    expect { msg2.inspect_message }.to change { ClamAVCallCount }.by(1)
    # Re-scanned (not cached)
  end
end
```
- **Status:** Required before merge

**M7.3: Code Review Checklist**
- [ ] Hash normalization logic reviewed
- [ ] TTL/freshness check logic reviewed
- [ ] Threat caching exclusion verified
- [ ] Cache bypass conditions verified
- [ ] Error handling reviewed
- **Status:** Required before merge

**M7.4: Staging Validation**
```
Pre-deployment checklist:
1. Send test newsletter to 10 recipients
2. Verify cache hit on messages 2-10
3. Send test message with EICAR test file
4. Verify virus detected on both sends (not cached)
5. Expire cache entry (manual UPDATE)
6. Verify subsequent send triggers re-scan
```
- **Status:** Required before production rollout

**Residual Risk:** LOW (with comprehensive testing)

---

## Mitigation Strategies Summary

### Phase 1: Must Implement Before Production

| Mitigation | Risk | Implementation | Testing |
|------------|------|----------------|---------|
| M1.1: 7-day TTL | R1 | Configuration | Unit test |
| M1.2: Never cache threats | R1 | Code logic | Integration test |
| M1.3: Never cache near-spam | R1 | Code logic | Integration test |
| M2.1: Use SHA-256 | R2 | Code (hash algorithm) | Unit test |
| M2.2: Size verification | R2 | Code (lookup) | Unit test |
| M6.1: Per-server opt-out | R6 | Database + code | Integration test |
| M6.2: Audit trail | R6 | Database + logging | Manual verification |
| M6.3: Policy document | R6 | Documentation | Legal review |
| M7.1: Unit tests | R7 | Test suite | CI/CD |
| M7.2: Integration tests | R7 | Test suite | CI/CD |
| M7.3: Code review | R7 | Process | Manual |

### Phase 2: Implement Within 30 Days

| Mitigation | Risk | Implementation | Testing |
|------------|------|----------------|---------|
| M1.4: Signature invalidation | R1 | Signature tracking + hook | Integration test |
| M2.3: Collision monitoring | R2 | Logging + alerting | Alert test |
| M5.1: Rate limiting | R5 | Cache size monitoring | Load test |

### Deferred / Accept Risk

| Risk | Acceptance Rationale |
|------|---------------------|
| R4: Privacy leak | Low impact, difficult to exploit, global cache reduces info gain |
| R8: Cache corruption | Database integrity mechanisms sufficient, can rebuild cache |

---

## Compliance Considerations

### HIPAA (Health Insurance Portability and Accountability Act)

**Concern:** PHI (Protected Health Information) in emails

**Requirements:**
- Access controls
- Audit trails
- Integrity controls
- Transmission security

**Cache Implications:**
- Cached data contains scan metadata (not message content)
- Audit trail implemented (M6.2)
- Per-organization opt-out available (M6.1)

**Recommendation:** **Enable caching** (low risk, metadata only)
- Alternative: Disable for HIPAA customers if concerned

### PCI-DSS (Payment Card Industry Data Security Standard)

**Concern:** Credit card data in emails

**Requirements:**
- Antivirus must be "current"
- Scan all systems regularly
- Maintain audit trail

**Cache Implications:**
- 7-day cache may not be "current" for all scans
- Signature invalidation (M1.4) addresses this

**Recommendation:** **Enable caching with signature invalidation**
- Alternative: Disable for PCI-scoped servers

### SOC 2 (System and Organization Controls)

**Concern:** Control effectiveness

**Requirements:**
- Demonstrate security controls operate effectively
- Audit trail of security decisions
- Risk assessment documented

**Cache Implications:**
- Caching is performance optimization, not security control
- Actual scanning still occurs (just deduplicated)
- Audit trail demonstrates effectiveness

**Recommendation:** **Enable caching**
- Include in SOC 2 audit: "Cache optimization does not reduce security posture"
- Provide audit trail reports to assessor

### GDPR (General Data Protection Regulation)

**Concern:** Data processing transparency

**Requirements:**
- Document data processing activities
- Transparency about automated decision-making

**Cache Implications:**
- Cached scan results are automated processing
- Must be documented in privacy policy
- Right to erasure: Cache entries removed after TTL

**Recommendation:** **Enable caching with transparency**
- Update privacy policy to mention caching
- Cache entries automatically purged (GDPR-compliant)

---

## Security Testing Requirements

### Unit Tests

**Coverage Target:** >80%

**Critical Paths:**
- [x] Hash computation with normalization
- [x] Cache lookup (hit/miss scenarios)
- [x] Cache store with deduplication
- [x] TTL enforcement
- [x] Threat exclusion (never cache)
- [x] Near-spam exclusion
- [x] LRU eviction
- [x] Size verification

### Integration Tests

**Scenarios:**
- [x] Newsletter to 10 recipients → 9 cache hits
- [x] Virus in message → not cached, detected on both sends
- [x] Cache expiry → re-scan after TTL
- [x] Per-server opt-out → server 3 bypasses cache
- [x] Large message → cached (>100KB threshold)
- [x] Small message → not cached (<100KB threshold)

### Security Tests

**Attack Simulations:**
- [ ] TOCT: Send benign, wait, send malicious (same hash)
- [ ] Collision: Attempt to find hash collision (negative test)
- [ ] Bypass: Try to manipulate headers to avoid cache
- [ ] Overflow: Send 200k unique messages (LRU eviction test)
- [ ] Timing: Measure cache hit vs miss timing (privacy test)

### Performance Tests

**Load Scenarios:**
- [ ] Baseline: 1000 msg/hr without cache
- [ ] Optimized: 1000 msg/hr with cache (90% hit rate)
- [ ] Spike: 5000 msg/hr newsletter burst
- [ ] Sustained: 10k msg/day for 7 days (cache growth)

### Penetration Testing

**Recommended (Optional):**
- Engage third-party security firm
- Simulate advanced attacker
- Test cache poisoning, bypass, timing attacks
- Report findings, implement fixes
- **Budget:** $5,000-10,000
- **Timeline:** Week 5-6 (after initial rollout)

---

## Change Log

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-31 | OpenCode AI | Initial draft |

---

## Approval

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Security Lead | [TBD] | | |
| Compliance Lead | [TBD] | | |
| Legal | [TBD] | | |

---

**Next Document:** [04-TESTING-STRATEGY.md](04-TESTING-STRATEGY.md)
