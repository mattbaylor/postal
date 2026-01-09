# Executive Summary: Email Scan Result Caching

## The Problem

Over the past 45 days (Nov 15 - Dec 30, 2025), our Postal email system experienced 17 service disruptions that delayed email delivery by hours. Root cause analysis revealed that when churches send newsletters to their congregations, all messages go through spam and virus scanning one at a time using just 2 worker threads. Large newsletters (5MB attachments, 250+ recipients) take 20-43 seconds per message to scan, creating a bottleneck. On December 30, Calvary Bible Church's newsletter took 3 hours to process instead of the expected 5 minutes, causing emails to queue up and triggering our monitoring alerts.

## The Solution

We're implementing a smart caching system that remembers the spam/virus scan results for identical email content. When a church sends a newsletter, the first message gets scanned normally (20-43 seconds), but every subsequent identical message reuses the cached result in under 50 milliseconds - a 400x speedup. The system uses cryptographic hashing (SHA-256) to identify identical content while normalizing recipient-specific details, so the same newsletter sent to 250 people only requires one full scan instead of 250. For security, we never cache emails containing viruses or high spam scores, ensuring threats are always re-scanned with the latest detection rules.

## Expected Impact

Based on our incident analysis, this change will reduce the December 30 incident from 3 hours to 5 minutes (a 97% improvement) and prevent similar incidents from occurring. For Calvary Bible Church and The Shepherd's Church - our two highest-volume newsletter senders - we expect 88-99% of their messages to benefit from caching. This eliminates the thread pool bottleneck without requiring infrastructure upgrades or changes to how customers use the system. The feature includes per-customer opt-out for compliance flexibility, a 7-day cache lifetime to ensure freshness, and automatic cleanup to prevent storage bloat. Most importantly, eliminating these 17 recurring incidents restores confidence in system reliability and removes a key barrier to growing our customer base.

## Implementation Approach

We're deploying this in four phases over four weeks: (1) Week 1 - Proof of concept with logging only to validate our 80%+ cache hit rate assumption in production, (2) Week 2 - Enable for our monitoring server (Server 3) which has low traffic and zero customer impact, (3) Week 3 - Enable for one high-volume church to test during their next newsletter campaign, and (4) Week 4 - Enable globally for all 50 mail servers. At each phase, we have automated rollback procedures and will monitor queue depth, CPU usage, and message delivery rates. The caching system is disabled by default and degrades gracefully - if the cache fails, messages simply process the traditional way without errors.

## Risk Mitigation

The primary risk is caching a "clean" message that later becomes a threat (e.g., virus signature updates). We mitigate this with a 7-day cache expiration, immediate re-scanning when virus definitions update, and a policy of never caching anything already flagged as suspicious. Per-customer opt-out allows compliance-sensitive organizations to disable caching if needed. The cache stores only metadata (hash, size, spam score) - never actual email content - protecting customer privacy. We maintain comprehensive monitoring with alerts if cache hit rates drop below 50% or if the cache table exceeds 10GB. Full documentation includes troubleshooting runbooks and a 5-minute rollback procedure tested during development.

---

**Bottom Line:** This low-risk change eliminates our most frequent service disruption (17 incidents in 45 days) by reusing scan results for identical newsletter content, improving performance by 8-12x for our highest-volume customers, with no infrastructure cost and built-in safety mechanisms.

**Timeline:** 1 week deployment + 3 weeks phased rollout  
**Investment:** ~6 hours engineering time (2 hours analysis, 4 hours implementation)  
**Return:** Eliminates recurring incidents, restores system confidence, removes barrier to customer growth  
**Risk Level:** Low (phased rollout, automatic rollback, no customer changes required)
