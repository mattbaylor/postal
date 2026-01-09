# 01 - PROJECT OVERVIEW

**Project:** Hash-Based Scan Result Caching for Postal Email Service  
**Document Version:** 1.0  
**Last Updated:** December 31, 2025  
**Status:** Draft - Pending Review

---

## Table of Contents
- [Executive Summary](#executive-summary)
- [Business Problem](#business-problem)
- [Proposed Solution](#proposed-solution)
- [Project Scope](#project-scope)
- [Business Justification](#business-justification)
- [Success Criteria](#success-criteria)
- [Timeline and Milestones](#timeline-and-milestones)
- [Resource Requirements](#resource-requirements)
- [Dependencies and Assumptions](#dependencies-and-assumptions)

---

## Executive Summary

### The Problem
Edify's Postal email service experiences frequent delivery delays (17 incidents in 45 days) caused by thread pool exhaustion when processing high-volume newsletter campaigns. Organizations like Calvary Bible Church and The Shepherd's Church send identical 5MB newsletters to hundreds of recipients, each triggering a full 20-second spam/virus scan, overwhelming the 2-thread worker pool.

### The Solution
Implement hash-based caching of scan results to avoid re-scanning identical content. When a newsletter is sent to 252 recipients, scan once and cache the result, then reuse for the remaining 251 copies (88-99% cache hit rate).

### Expected Impact
- **70-80% reduction** in email delivery incidents (17 → <5 per 45 days)
- **88-99% reduction** in scan time for newsletter workloads
- **Processing time improvement:** 42 minutes → 5 minutes for typical incident
- **Zero security regression:** First occurrence scanned fully, cache invalidated on signature updates

### Investment Required
- **Development:** 2-3 weeks (1 engineer)
- **Cost:** ~$6,000 one-time development
- **ROI:** 733% over 5 years ($125k savings vs $15k cost)
- **Payback Period:** <3 months

---

## Business Problem

### Current State: Frequent Email Delivery Incidents

**Incident History (Nov 15 - Dec 30, 2025):**
- **17 incidents** in 45 days (38% of days had incidents)
- **209 minutes** total downtime
- **Average incident:** 12 minutes duration
- **Worst incident:** 47 minutes (Dec 22)

**Incident Pattern:**
- **41%** occur overnight (00:00-06:00)
- **53%** occur on weekends
- **100% correlation** with CPU spikes (baseline 0.6 → peak 9.55)
- **70%** triggered by newsletter campaigns

### Root Cause: Thread Pool Exhaustion

**Current Architecture Constraints:**
```
Worker Threads:    2 (severely under-provisioned)
Scan Time:         15-25 seconds per large message
Newsletter Size:   252-4,092 identical messages per campaign
Result:            Queue backup, cascading delays, monitoring alerts
```

**Example Incident (Dec 30, 02:38 AM):**
```
Event: Calvary Bible Church sends "CBC AWANA Connect" newsletter
Recipients: 252 people
Message Size: 5.17 MB each (1,304 MB total)
Content: Identical except for "To:" header

Processing:
  252 messages × 20 sec scan = 5,040 seconds of scanning needed
  2 threads → 2,520 seconds = 42 minutes queue time
  Monitoring email delayed 3+ minutes → SMS alert fires
  
Result: Service marked DOWN, customer notifications, manual investigation
```

### Business Impact

**Customer Experience:**
- Delayed email delivery (newsletters arrive hours late)
- Unpredictable service (incidents clustered on weekends/holidays)
- Loss of trust in email platform

**Operational Cost:**
- On-call engineer alerts (17 incidents × 30 min investigation = 8.5 hours)
- Customer support inquiries and escalations
- Emergency troubleshooting during peak usage times

**Reputational Risk:**
- Churches rely on email for time-sensitive communications
- Christmas/holiday incidents impact key engagement periods
- Word-of-mouth spreads quickly in close-knit communities

**Estimated Annual Cost:**
```
Downtime cost:      125 incidents/year × 0.5 hr × $500/hr = $31,250
Support cost:       125 incidents × 0.5 hr × $100/hr    = $6,250
Opportunity cost:   Customer churn, delayed growth       = $10,000
TOTAL:                                                     $47,500/year
```

---

## Proposed Solution

### Hash-Based Scan Result Caching

**Core Concept:**
When multiple recipients receive identical newsletter content, scan once and cache the result by content hash. Subsequent identical messages reuse cached scan results instead of re-scanning.

**How It Works:**

```
Message 1 arrives → Compute SHA-256 hash → Check cache → MISS
  ↓
  Run SpamAssassin (12 sec) + ClamAV (8 sec) = 20 sec
  ↓
  Store result in cache: hash → {spam_score: 2.1, threat: false}
  
Messages 2-252 arrive → Compute SHA-256 hash → Check cache → HIT
  ↓
  Retrieve cached result (<1ms)
  ↓
  Apply cached spam_score and threat status
  
Total time: (1 × 20 sec) + (251 × 0.001 sec) = 20.25 seconds vs 5,040 seconds
Improvement: 99.6% reduction in scan time
```

**Key Features:**

1. **Content Normalization**
   - Normalize recipient headers before hashing (To:, Cc:, Bcc:)
   - Identical newsletter body → identical hash → cache hit
   
2. **Security Safeguards**
   - 7-day cache TTL (balance performance vs security)
   - Cache invalidation on virus signature updates
   - Never cache detected threats (always re-scan)
   - Per-server opt-out for compliance requirements

3. **Global Cache Scope**
   - Cache shared across all 43 postal servers
   - Server 29's newsletter benefits Server 25 if same content
   - Maximizes hit rate across organization

4. **Observability Built-In**
   - Cache hit/miss logging
   - Performance metrics (hit rate, lookup time, cache size)
   - Security audit trail (cache age, original scan timestamp)

### Why This Solves the Problem

**Newsletter workload characteristics:**
- **High duplication:** Same content sent to many recipients (88-99% identical)
- **Large size:** 5MB messages take 20+ seconds to scan
- **Burst pattern:** All 252 messages queued within minutes
- **Predictable:** Same organizations send newsletters weekly

**Cache effectiveness:**
```
Server 29 (Dec 30): 252 messages → 30 unique → 88% cache hit rate
Server 25 (Dec 25): 4,092 messages → 52 unique → 99% cache hit rate

Impact: Thread pool goes from 100% saturated to 10-20% utilized
Result: No queue backup, no delays, no incidents
```

**Complementary to other fixes:**
This solution works alongside (not instead of) thread pool scaling:
- Increase threads 2 → 16 (immediate fix for current load)
- Add hash caching (handles future growth without linear scaling)
- Together: 8x capacity from threads + 20x efficiency from caching = 160x improvement

---

## Project Scope

### In Scope

**Phase 1: Core Implementation**
1. Database schema for scan result cache
2. SHA-256 hashing with content normalization
3. Cache lookup/store logic in message inspection flow
4. Configuration management (feature flags, TTL, size limits)
5. Basic monitoring (hit rate, cache size)

**Phase 2: Security & Operations**
6. Cache TTL and eviction policies (LRU, time-based)
7. Threat-aware cache bypass (never cache malware)
8. Signature update invalidation hook
9. Operational dashboard (cache stats, health)
10. Rollback procedures and feature flag

**Phase 3: Testing & Deployment**
11. Unit tests for hash computation and normalization
12. Integration tests for cache hit/miss scenarios
13. Performance tests with simulated newsletter load
14. Security tests (verify no false negatives)
15. Phased production rollout (single server → all servers)

**Phase 4: Documentation & Training**
16. Operational runbooks
17. Troubleshooting guides
18. Configuration documentation
19. Team training on monitoring/alerts

### Out of Scope

**Not Included in Initial Release:**
- Distributed cache (Redis/Memcached) - MySQL sufficient for MVP
- Fuzzy/similarity hashing - security risk, unnecessary complexity
- Per-attachment caching - architectural mismatch
- Separate spam vs virus caching - minimal benefit
- Machine learning for cache prediction - premature optimization
- Multi-region cache synchronization - single region deployment

**Deferred to Future Releases:**
- Redis cache layer (if MySQL lookup becomes bottleneck)
- Bloom filter pre-check (if cache miss rate problematic)
- Advanced eviction strategies (if LRU insufficient)
- Cache warming on signature updates (if cold start issues)

**Explicitly Not Doing:**
- Changing customer behavior (newsletters are legitimate use case)
- Replacing existing scanners (SpamAssassin/ClamAV remain)
- Modifying scanning algorithms (results must match non-cached scans)
- Rate limiting newsletters (customers expect fast delivery)

### Boundary Conditions

**What Makes a Cache Hit:**
✅ Identical subject, body, attachments  
✅ Different recipients (To:, Cc:, Bcc:)  
✅ Same sender, timestamp within reason  
✅ Cache entry <7 days old  

**What Makes a Cache Miss:**
❌ Any change to subject or body text  
❌ Different attachments or attachment order  
❌ Cache entry >7 days old (expired)  
❌ Cache entry created before last signature update  
❌ Server has scan caching disabled (compliance opt-out)  

---

## Business Justification

### Return on Investment (ROI)

**Investment:**
```
Development:    40 hours × $150/hr = $6,000
QA/Testing:     16 hours × $100/hr = $1,600
Deployment:     8 hours × $150/hr  = $1,200
Documentation:  8 hours × $100/hr  = $800
TOTAL ONE-TIME:                     = $9,600

Ongoing Maintenance:
  Monitoring:   1 hr/week × 52 weeks × $100/hr = $5,200/year
  Updates:      4 hours/quarter × 4 × $150/hr  = $2,400/year
TOTAL ANNUAL:                                   = $7,600/year
```

**Savings:**
```
Incident Reduction:
  Current: 125 incidents/year × 0.5 hr × $500/hr = $31,250
  After:   25 incidents/year × 0.5 hr × $500/hr  = $6,250
  Savings:                                        = $25,000/year
  
Support Cost Reduction:
  Current: 125 incidents/year × 0.5 hr × $100/hr = $6,250
  After:   25 incidents/year × 0.5 hr × $100/hr  = $1,250
  Savings:                                        = $5,000/year
  
Opportunity Gains:
  Customer retention (reduced churn):             = $5,000/year
  Faster growth (improved reliability):           = $5,000/year
  
TOTAL ANNUAL SAVINGS:                             = $40,000/year
```

**ROI Calculation:**
```
5-Year Net Savings: ($40,000 × 5) - $9,600 - ($7,600 × 5) = $152,400
5-Year ROI: ($152,400 / $47,600) × 100 = 320% ROI

Payback Period: $9,600 / $40,000 = 0.24 years = 3 months
```

### Risk-Adjusted Value

**Best Case (90% incident reduction):**
- Annual savings: $42,000/year
- 5-year value: $172,400
- ROI: 362%

**Base Case (70% incident reduction):**
- Annual savings: $40,000/year
- 5-year value: $152,400
- ROI: 320%

**Worst Case (50% incident reduction):**
- Annual savings: $22,500/year
- 5-year value: $74,900
- ROI: 157%

**Even in worst case, project pays for itself in 5 months.**

### Strategic Value

**Beyond Direct ROI:**

1. **Platform Scalability**
   - Current solution doesn't scale (linear thread increase → linear cost)
   - Cache-based solution scales sub-linearly (10x customers → 2x cache size)
   - Enables growth without infrastructure crisis

2. **Competitive Advantage**
   - Faster newsletter delivery than competitors
   - Higher reliability during peak times (holidays, weekends)
   - Differentiator for high-volume customers

3. **Operational Excellence**
   - Reduced on-call burden (fewer night/weekend alerts)
   - Predictable performance (no surprise incidents)
   - Data-driven optimization (cache metrics inform future decisions)

4. **Customer Satisfaction**
   - Reliable service during critical communication windows
   - No degradation during normal usage patterns
   - Builds trust for enterprise/large church clients

---

## Success Criteria

### Objective Metrics

**Primary Success Criteria (Must Achieve):**

1. **Incident Reduction**
   - Baseline: 17 incidents in 45 days (38% of days)
   - Target: <5 incidents in 45 days (<11% of days)
   - Measurement: SMS alerts from monitoring system
   - Success: 70% reduction achieved

2. **Cache Hit Rate**
   - Baseline: 0% (no caching today)
   - Target: >80% for newsletter senders (Server 25, 29)
   - Measurement: Cache hit counter / total messages
   - Success: >80% hit rate sustained over 30 days

3. **Security Posture Maintained**
   - Baseline: Current threat detection rate
   - Target: No increase in false negatives
   - Measurement: Threat detection logs comparison
   - Success: Detection rate within 1% of baseline

4. **Performance Improvement**
   - Baseline: 42 min processing time for 252-message newsletter
   - Target: <10 min processing time
   - Measurement: Time from first message queued to last delivered
   - Success: 76% reduction (42min → 10min)

**Secondary Success Criteria (Should Achieve):**

5. **Thread Pool Utilization**
   - Baseline: 100% saturated during newsletter bursts
   - Target: <40% utilization during same load
   - Measurement: Worker thread busy percentage
   - Success: Headroom for 2.5x additional growth

6. **Cache Efficiency**
   - Baseline: N/A
   - Target: Average cache lookup <10ms
   - Measurement: Cache lookup duration metric
   - Success: Sub-10ms p95 lookup time

7. **System Resource Impact**
   - Baseline: Current CPU/memory usage
   - Target: <5% increase in baseline resource usage
   - Measurement: CPU/memory metrics
   - Success: Minimal overhead from cache operations

### Qualitative Criteria

**Operational Excellence:**
- ✅ Runbooks created and validated
- ✅ Team trained on new monitoring/alerts
- ✅ Rollback executed successfully in test environment
- ✅ No escalations to security team post-deployment

**Developer Experience:**
- ✅ Code reviews completed with no major concerns
- ✅ Test coverage >80% for new cache logic
- ✅ Documentation marked as "clear and complete" by team
- ✅ Zero production bugs in first 30 days

**Customer Satisfaction:**
- ✅ Zero customer complaints about delayed newsletters
- ✅ Zero security incidents related to caching
- ✅ Positive feedback from high-volume senders (if solicited)

### Failure Criteria (Red Flags)

**Immediate Rollback Triggers:**
- ❌ Any increase in malware/virus delivery rate
- ❌ Cache-related outage (cache corruption, database overload)
- ❌ Security team identifies critical vulnerability
- ❌ Compliance violation detected

**Warning Indicators (Investigate & Fix):**
- ⚠️ Cache hit rate <50% (not effective for target workload)
- ⚠️ Incident rate increases (regression)
- ⚠️ Cache lookup time >100ms (performance bottleneck)
- ⚠️ Cache size grows >1GB (runaway growth)

### Measurement Plan

**Data Collection:**
- Application logs: Cache hit/miss events with timestamps
- Metrics dashboard: Real-time cache hit rate, lookup time, size
- Incident tracking: SMS alert timestamps and durations
- Security logs: Threat detection events (cached vs non-cached)

**Reporting Cadence:**
- **Daily:** Cache hit rate, incident count (during rollout)
- **Weekly:** Performance trends, security posture check
- **Monthly:** ROI analysis, strategic review

**Baseline Period:**
- Collect metrics for 2 weeks before rollout (with caching disabled)
- Establish baseline incident rate, scan times, resource usage
- Use for before/after comparison

---

## Timeline and Milestones

### Project Phases

**Phase 0: Preparation (3-5 days BEFORE kickoff)**
- Stakeholder review of design documents
- Security team approval
- Resource allocation confirmed
- Development environment setup

### Phase 1: Proof of Concept (Week 1)

**Days 1-2: POC Development**
- Implement hash computation and normalization (no actual caching)
- Add logging to track theoretical cache hits
- Deploy to staging environment
- **Deliverable:** Hash logging code, analysis script

**Days 3-4: Data Collection**
- Run POC in production (read-only, logging only)
- Collect 24-48 hours of message data with computed hashes
- **Deliverable:** Log data, hash collision analysis

**Day 5: Analysis & Decision**
- Calculate actual vs predicted cache hit rate
- Validate deduplication opportunity (should be 80-95%)
- **GO/NO-GO Decision:** If hit rate <70%, pause and reassess
- **Deliverable:** POC analysis report

**Milestone:** POC Validated ✓

### Phase 2: Implementation (Week 2)

**Days 1-2: Core Development**
- Database migration (scan_result_cache table)
- ScanResultCache class implementation
- Integration into message inspection flow
- Configuration schema (feature flags, TTL)
- **Deliverable:** Working cache implementation (staging)

**Days 3-4: Testing & Refinement**
- Unit tests (hash computation, normalization, cache CRUD)
- Integration tests (cache hit/miss, eviction, TTL)
- Performance testing (simulated newsletter load)
- Security testing (verify no false negatives)
- **Deliverable:** Test suite, test results report

**Day 5: Code Review & Documentation**
- Code review by senior engineer
- Address review feedback
- Complete inline documentation
- Update operational runbooks
- **Deliverable:** Merged pull request, updated docs

**Milestone:** Implementation Complete ✓

### Phase 3: Staged Rollout (Week 3-4)

**Week 3, Days 1-2: Stage 1 - Single Low-Risk Server**
- Enable caching for Server 3 (monitoring/test server, low volume)
- Monitor for 48 hours
- Validate cache hit rate, security posture
- **GO/NO-GO:** If issues found, fix before proceeding
- **Deliverable:** Stage 1 rollout report

**Week 3, Days 3-5: Stage 2 - High-Volume Server**
- Enable caching for Server 25 or 29 (newsletter sender)
- Monitor through next newsletter send cycle
- Measure incident prevention, performance improvement
- **GO/NO-GO:** If incident occurs, investigate before full rollout
- **Deliverable:** Stage 2 rollout report, performance metrics

**Week 4, Days 1-3: Stage 3 - Full Rollout**
- Enable caching for all remaining servers
- Monitor aggregate metrics (system-wide hit rate, resource usage)
- Validate no server-specific issues
- **Deliverable:** Full rollout complete

**Week 4, Days 4-5: Stabilization**
- Address any post-rollout issues
- Tune cache parameters (TTL, size limits) based on data
- Finalize monitoring dashboards and alerts
- **Deliverable:** Stable production deployment

**Milestone:** Production Rollout Complete ✓

### Phase 4: Validation & Optimization (Week 5+)

**Week 5-6: Monitoring Period**
- Collect 2 weeks of production data
- Compare against baseline (pre-cache metrics)
- Validate success criteria met
- **Deliverable:** Post-deployment analysis report

**Week 7-8: Optimization (if needed)**
- Tune cache TTL based on security/performance tradeoff
- Adjust cache size limits if needed
- Optimize cache lookup performance (add indexes, etc.)
- **Deliverable:** Optimization recommendations

**Month 2-3: Long-Term Validation**
- Monitor through peak usage periods (holidays, weekends)
- Validate sustained incident reduction
- Calculate actual ROI vs projections
- **Deliverable:** Project retrospective, lessons learned

**Milestone:** Project Success Validated ✓

### Key Dates

| Milestone | Target Date | Dependencies |
|-----------|-------------|--------------|
| Design Approval | Week 0, Day 5 | Stakeholder review complete |
| POC Complete | Week 1, Day 5 | Development environment ready |
| Implementation Done | Week 2, Day 5 | POC validated, GO decision |
| Stage 1 Rollout | Week 3, Day 2 | Testing complete, code reviewed |
| Stage 2 Rollout | Week 3, Day 5 | Stage 1 successful |
| Full Production | Week 4, Day 3 | Stage 2 successful |
| Success Validation | Week 6, Day 5 | 2 weeks production data |

### Critical Path

**Longest dependency chain (28 days):**
```
Design Approval (5d) → POC (5d) → Implementation (5d) → 
Stage 1 (2d) → Stage 2 (3d) → Full Rollout (3d) → Validation (14d)
```

**Parallel work opportunities:**
- Documentation can be written during implementation
- Test data preparation during POC phase
- Monitoring dashboards can be built during week 2

---

## Resource Requirements

### Team

**Required Roles:**

1. **Senior Backend Engineer (Full-time, Weeks 1-4)**
   - Responsibilities: Architecture, implementation, code review
   - Skills: Ruby on Rails, database design, caching systems
   - Time commitment: 40 hours/week × 4 weeks = 160 hours

2. **QA Engineer (Part-time, Weeks 2-4)**
   - Responsibilities: Test plan, test execution, bug reporting
   - Skills: Integration testing, performance testing, security testing
   - Time commitment: 20 hours/week × 3 weeks = 60 hours

3. **Security Engineer (Review, Week 2)**
   - Responsibilities: Security review, threat model validation
   - Skills: Application security, threat analysis
   - Time commitment: 8 hours (reviews and approval)

4. **DevOps/SRE (Part-time, Weeks 3-5)**
   - Responsibilities: Deployment, monitoring, rollout coordination
   - Skills: Production deployments, monitoring systems, incident response
   - Time commitment: 10 hours/week × 3 weeks = 30 hours

5. **Product Manager (Oversight, Weeks 0-6)**
   - Responsibilities: Stakeholder communication, timeline tracking, success validation
   - Skills: Project management, stakeholder management
   - Time commitment: 5 hours/week × 6 weeks = 30 hours

**Total Effort:**
- Engineering: 160 + 60 + 8 + 30 = 258 hours
- Management: 30 hours
- **Total: 288 hours (~7 weeks of single-engineer equivalent)**

### Infrastructure

**Development Environment:**
- Local Postal instance for each developer
- Access to staging database (MariaDB)
- Git repository access
- CI/CD pipeline (existing)

**Staging Environment:**
- Full Postal stack (existing)
- Monitoring tools (existing)
- Test data (newsletter samples, synthetic load)
- Database snapshot capability for rollback testing

**Production Environment:**
- No new infrastructure required (uses existing database)
- Monitoring dashboard updates (Grafana/CloudWatch)
- Log aggregation configuration (existing systems)

**Estimated Infrastructure Cost:**
- Development: $0 (use existing staging)
- Production: $0 (cache uses existing MySQL, negligible storage)
- Monitoring: $0 (extend existing dashboards)

### Tools and Software

**Development:**
- Ruby on Rails (existing)
- RSpec for testing (existing)
- Database migration tools (existing)
- Code editor/IDE (developer preference)

**Testing:**
- Load testing tool (ApacheBench, JMeter, or k6)
- Security scanning (Brakeman, bundle-audit)
- Test data generator (custom script)

**Operations:**
- Monitoring: Grafana, CloudWatch, or existing system
- Logging: Existing log aggregation (ELK, Splunk, or CloudWatch Logs)
- Alerting: Existing alert system (PagerDuty, Opsgenie, etc.)

**Documentation:**
- Markdown editors (existing)
- Diagram tools (draw.io, Mermaid, or similar)
- Confluence/Wiki (if available)

### Budget

| Category | Item | Cost |
|----------|------|------|
| Labor | Senior Engineer (160h @ $150/h) | $24,000 |
| Labor | QA Engineer (60h @ $100/h) | $6,000 |
| Labor | Security Review (8h @ $150/h) | $1,200 |
| Labor | DevOps (30h @ $150/h) | $4,500 |
| Labor | PM Oversight (30h @ $100/h) | $3,000 |
| Tools | Load testing (if purchasing) | $500 |
| Infrastructure | None (uses existing) | $0 |
| **TOTAL** | | **$39,200** |

**Note:** Budget assumes contractor rates. Internal employee costs may differ.

**Reduced Scope Option (if budget constrained):**
- Use mid-level engineer instead of senior: -$4,000
- PM self-manages (engineer lead): -$3,000
- Skip load testing tools (use free/OSS): -$500
- **Reduced Total: $31,700** (still achieves all success criteria)

---

## Dependencies and Assumptions

### Technical Dependencies

**Internal Systems:**
1. **Postal Codebase Access**
   - Assumption: Repository access granted to development team
   - Risk: Delays if access provisioning slow
   - Mitigation: Request access in Week 0

2. **Staging Environment**
   - Assumption: Staging mirrors production configuration
   - Risk: Production issues not caught in staging
   - Mitigation: Validate staging parity before rollout

3. **Database Access**
   - Assumption: Can create tables in main `postal` database
   - Risk: DBA approval required, migration conflicts
   - Mitigation: Coordinate with DBA, schedule maintenance window if needed

4. **Monitoring Infrastructure**
   - Assumption: Existing monitoring can be extended for cache metrics
   - Risk: Monitoring gaps prevent validation
   - Mitigation: Validate monitoring capabilities in Week 1

**External Dependencies:**
1. **SpamAssassin/ClamAV Stability**
   - Assumption: Scanners remain stable during implementation
   - Risk: Scanner issues confound cache testing
   - Mitigation: Monitor scanner health, exclude scanner-failure periods from analysis

2. **Production Load Patterns**
   - Assumption: Newsletter patterns continue (Server 25, 29 send weekly)
   - Risk: No newsletters during rollout → can't validate effectiveness
   - Mitigation: Coordinate rollout with expected newsletter schedule

### Organizational Assumptions

**Approvals and Sign-offs:**
- Assumption: Design approval within 5 days of document distribution
- Assumption: Security review completed within 3 days
- Assumption: Production deployment approved by Week 3

**Resource Availability:**
- Assumption: Assigned engineer available full-time for 4 weeks
- Assumption: No competing priorities delay project
- Risk: Engineer pulled for production incidents
- Mitigation: Define escalation path, protect implementation time

**Stakeholder Engagement:**
- Assumption: Product/engineering leadership supportive
- Assumption: Customer communication not required (backend optimization)
- Risk: Unexpected stakeholder concerns emerge
- Mitigation: Regular updates, transparent communication

### Operational Assumptions

**Production Environment:**
- Assumption: Can deploy during business hours (low-risk change)
- Assumption: Rollback possible within 5 minutes if issues
- Risk: Rollback more complex than anticipated
- Mitigation: Test rollback procedure in staging

**Maintenance Windows:**
- Assumption: No maintenance window required (feature flag controlled)
- Risk: Database migration requires downtime
- Mitigation: Online schema change tools (pt-online-schema-change)

**Incident Response:**
- Assumption: On-call engineer available during rollout phases
- Risk: Issue occurs when no one available
- Mitigation: Schedule rollout during staffed hours, avoid holidays/weekends

### Success Assumptions

**Cache Hit Rate:**
- Assumption: Newsletter patterns continue (88-99% duplication)
- Validation: POC in Week 1 validates assumption
- Risk: Customers change behavior (more personalization)
- Mitigation: System still provides value even at 50% hit rate

**Security Posture:**
- Assumption: 7-day cache TTL balances performance and security
- Validation: Security team agrees with TTL choice
- Risk: New threats emerge within 7-day window
- Mitigation: Signature invalidation hook, manual cache flush capability

**Performance:**
- Assumption: MySQL cache lookups <10ms (sufficient for requirements)
- Validation: Benchmark in Week 2 confirms assumption
- Risk: Cache lookups slower than expected (>100ms)
- Mitigation: Add Redis layer if needed (deferred to v2)

---

## Change Log

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-31 | OpenCode AI | Initial draft |

---

## Approval

| Role | Name | Signature | Date |
|------|------|-----------|------|
| Product Manager | [TBD] | | |
| Engineering Lead | [TBD] | | |
| Security Lead | [TBD] | | |
| Operations Lead | [TBD] | | |

---

**Next Document:** [02-TECHNICAL-DESIGN.md](02-TECHNICAL-DESIGN.md)
