# 04 - TESTING STRATEGY

**Project:** Hash-Based Scan Result Caching  
**Document Version:** 1.0  
**Last Updated:** December 31, 2025

---

## Testing Pyramid

```
           ┌──────────────┐
           │    E2E (5%)  │  Full newsletter flow
           ├──────────────┤
           │ Integration  │  Cache + scanning
           │    (25%)     │  component interaction
           ├──────────────┤
           │  Unit Tests  │  Hash, normalize,
           │    (70%)     │  lookup, store, TTL
           └──────────────┘
```

---

## Unit Tests (Target: 80%+ Coverage)

### Hash Computation Tests

```ruby
RSpec.describe "Message#compute_cache_key" do
  it "produces consistent hashes for identical content" do
    msg1 = build_message(body: "Newsletter", to: "alice@example.com")
    msg2 = build_message(body: "Newsletter", to: "bob@example.com")
    expect(msg1.compute_cache_key).to eq(msg2.compute_cache_key)
  end
  
  it "produces different hashes for different content" do
    msg1 = build_message(body: "Newsletter 1")
    msg2 = build_message(body: "Newsletter 2")
    expect(msg1.compute_cache_key).not_to eq(msg2.compute_cache_key)
  end
  
  it "normalizes To: header" do
    original = build_message(to: "alice@example.com")
    normalized = original.send(:normalized_raw_message)
    expect(normalized).to include("NORMALIZED@CACHE.LOCAL")
    expect(normalized).not_to include("alice@example.com")
  end
  
  it "removes X-Postal-MsgID header" do
    original = build_message(headers: {"X-Postal-MsgID" => "12345"})
    normalized = original.send(:normalized_raw_message)
    expect(normalized).not_to include("X-Postal-MsgID")
  end
  
  it "preserves Message-ID and Date headers" do
    msg_id = "<unique@example.com>"
    date = "Mon, 1 Jan 2025 12:00:00 +0000"
    original = build_message(message_id: msg_id, date: date)
    normalized = original.send(:normalized_raw_message)
    expect(normalized).to include(msg_id)
    expect(normalized).to include(date)
  end
end
```

### Cache Lookup Tests

```ruby
RSpec.describe ScanResultCache do
  describe ".lookup" do
    it "returns nil for cache miss" do
      expect(ScanResultCache.lookup("nonexistent_hash")).to be_nil
    end
    
    it "returns CachedScanResult for cache hit" do
      store_test_cache_entry(hash: "abc123")
      result = ScanResultCache.lookup("abc123")
      expect(result).to be_a(CachedScanResult)
    end
    
    it "returns nil for expired entries" do
      store_test_cache_entry(hash: "abc123", age: 8.days)
      expect(ScanResultCache.lookup("abc123")).to be_nil
    end
    
    it "verifies message size matches" do
      store_test_cache_entry(hash: "abc123", size: 5000)
      result = ScanResultCache.lookup("abc123", 5000)
      expect(result).not_to be_nil
      
      result = ScanResultCache.lookup("abc123", 6000)  # Size mismatch
      expect(result).to be_nil
    end
  end
end
```

### Cache Store Tests

```ruby
RSpec.describe ScanResultCache do
  describe ".store" do
    it "creates new cache entry" do
      result = build_inspection_result(spam_score: 2.5, threat: false)
      expect {
        ScanResultCache.store("abc123", result, 5000)
      }.to change { ScanResultCache.count }.by(1)
    end
    
    it "updates existing entry (deduplication)" do
      ScanResultCache.store("abc123", build_inspection_result, 5000)
      expect {
        ScanResultCache.store("abc123", build_inspection_result, 5000)
      }.not_to change { ScanResultCache.count }
    end
    
    it "increments hit_count on duplicate" do
      ScanResultCache.store("abc123", build_inspection_result, 5000)
      expect {
        ScanResultCache.store("abc123", build_inspection_result, 5000)
      }.to change { 
        ScanResultCache.lookup("abc123").hit_count 
      }.by(1)
    end
    
    it "serializes spam_checks to JSON" do
      result = build_inspection_result(spam_checks: [
        {code: "RULE1", score: 1.0, description: "Test"},
        {code: "RULE2", score: 0.5, description: "Test2"}
      ])
      ScanResultCache.store("abc123", result, 5000)
      
      cached = ScanResultCache.lookup("abc123")
      expect(cached.spam_checks).to be_an(Array)
      expect(cached.spam_checks.size).to eq(2)
    end
  end
end
```

### TTL and Eviction Tests

```ruby
RSpec.describe ScanResultCache do
  describe ".cleanup_expired" do
    it "deletes entries older than TTL" do
      store_test_cache_entry(hash: "old", age: 8.days)
      store_test_cache_entry(hash: "fresh", age: 1.day)
      
      expect {
        ScanResultCache.cleanup_expired
      }.to change { ScanResultCache.count }.by(-1)
      
      expect(ScanResultCache.lookup("old")).to be_nil
      expect(ScanResultCache.lookup("fresh")).not_to be_nil
    end
  end
  
  describe ".evict_lru" do
    it "removes oldest 10% when limit reached" do
      # Create 101 entries (max = 100)
      101.times { |i| store_test_cache_entry(hash: "entry_#{i}") }
      
      ScanResultCache.evict_lru
      expect(ScanResultCache.count).to eq(90)  # Evicted 11 entries
    end
    
    it "prioritizes by last_hit_timestamp" do
      store_test_cache_entry(hash: "old", last_hit: 10.days.ago)
      store_test_cache_entry(hash: "recent", last_hit: 1.day.ago)
      
      ScanResultCache.evict_lru
      expect(ScanResultCache.lookup("old")).to be_nil
      expect(ScanResultCache.lookup("recent")).not_to be_nil
    end
  end
end
```

### Security Tests

```ruby
RSpec.describe "Security constraints" do
  it "never caches threats" do
    msg = build_message
    result = build_inspection_result(threat: true)
    
    expect(msg.send(:should_cache_result?, result)).to be false
  end
  
  it "never caches near-spam" do
    msg = build_message(server: build_server(spam_threshold: 5.0))
    result = build_inspection_result(spam_score: 4.5)  # 90% of threshold
    
    expect(msg.send(:should_cache_result?, result)).to be false
  end
  
  it "caches clean messages below threshold" do
    msg = build_message(server: build_server(spam_threshold: 5.0))
    result = build_inspection_result(spam_score: 2.0, threat: false)
    
    expect(msg.send(:should_cache_result?, result)).to be true
  end
end
```

---

## Integration Tests (Target: Key Workflows)

### End-to-End Cache Flow

```ruby
RSpec.describe "Message inspection with caching" do
  before do
    enable_scan_cache
  end
  
  it "caches clean scan results" do
    msg1 = create_test_message(body: "Newsletter", to: "alice@example.com")
    
    expect {
      msg1.inspect_message
    }.to change { scanner_call_count }.by(1)
    
    msg2 = create_test_message(body: "Newsletter", to: "bob@example.com")
    
    expect {
      msg2.inspect_message
    }.not_to change { scanner_call_count }
    
    expect(msg2.spam_score).to eq(msg1.spam_score)
    expect(msg2.threat).to eq(msg1.threat)
  end
  
  it "does not cache threats" do
    msg1 = create_message_with_virus
    msg1.inspect_message
    expect(msg1.threat).to be true
    
    msg2 = create_message_with_virus  # Identical
    expect {
      msg2.inspect_message
    }.to change { scanner_call_count }.by(1)  # Re-scanned
    
    expect(msg2.threat).to be true
  end
  
  it "respects per-server opt-out" do
    server = create_server(scan_cache_enabled: false)
    msg1 = create_test_message(server: server)
    msg1.inspect_message
    
    msg2 = create_test_message(server: server)  # Identical
    expect {
      msg2.inspect_message
    }.to change { scanner_call_count }.by(1)  # Not cached
  end
end
```

### Newsletter Simulation

```ruby
RSpec.describe "Newsletter workflow" do
  it "handles 100-recipient newsletter efficiently" do
    newsletter_body = generate_large_html(size: 5.megabytes)
    recipients = generate_recipients(count: 100)
    
    messages = recipients.map do |recipient|
      create_test_message(body: newsletter_body, to: recipient)
    end
    
    expect {
      messages.each(&:inspect_message)
    }.to change { scanner_call_count }.by(1)  # Only first message scanned
    
    cache_stats = ScanResultCache.statistics
    expect(cache_stats[:hit_rate]).to be > 0.95  # >95% hit rate
  end
end
```

---

## Performance Tests

### Baseline Measurement

```ruby
RSpec.describe "Performance benchmarks" do
  it "hash computation completes in <100ms" do
    msg = create_test_message(size: 5.megabytes)
    
    time = Benchmark.measure {
      msg.compute_cache_key
    }.real
    
    expect(time).to be < 0.1  # 100ms
  end
  
  it "cache lookup completes in <10ms" do
    store_test_cache_entry(hash: "abc123")
    
    time = Benchmark.measure {
      ScanResultCache.lookup("abc123")
    }.real
    
    expect(time).to be < 0.01  # 10ms
  end
  
  it "cache hit is 1000x faster than full scan" do
    msg1 = create_test_message
    scan_time = Benchmark.measure { msg1.inspect_message }.real
    
    msg2 = create_test_message  # Identical
    cache_time = Benchmark.measure { msg2.inspect_message }.real
    
    expect(scan_time / cache_time).to be > 1000
  end
end
```

### Load Testing

Use external tool (k6, JMeter, or custom Ruby script):

```javascript
// k6 load test script
import http from 'k6/http';
import { check } from 'k6';

export let options = {
  stages: [
    { duration: '5m', target: 100 },  // Ramp up
    { duration: '10m', target: 100 }, // Steady state
    { duration: '5m', target: 0 },    // Ramp down
  ],
};

export default function () {
  // Send newsletter (simulated)
  let payload = generateNewsletter();
  let res = http.post('http://postal/api/messages', payload);
  
  check(res, {
    'status is 200': (r) => r.status === 200,
    'processing time < 5s': (r) => r.timings.duration < 5000,
  });
}
```

**Scenarios:**
1. **Baseline:** 1000 unique messages/hour (no cache benefit)
2. **Newsletter:** 1000 identical messages/hour (99% cache hit)
3. **Mixed:** 80% newsletter, 20% unique (80% cache hit)
4. **Spike:** 5000 messages in 5 minutes (stress test)

**Success Criteria:**
- Newsletter scenario: 10x faster than baseline
- No increase in error rate
- Cache hit rate >80%
- Database CPU <50%

---

## Security Testing

### TOCT Attack Simulation

```ruby
RSpec.describe "TOCT attack prevention" do
  it "detects virus after signature update" do
    # Day 0: Benign message
    msg1 = create_test_message(body: "Clean content")
    msg1.inspect_message
    expect(msg1.threat).to be false
    
    # Day 1: Simulate signature update
    update_virus_signatures(add: "Clean content" => "Virus.Test")
    ScanResultCache.invalidate_all  # Cache flushed
    
    # Day 2: Same message now detected
    msg2 = create_test_message(body: "Clean content")
    msg2.inspect_message
    expect(msg2.threat).to be true  # Detected after re-scan
  end
end
```

### Hash Collision Detection

```ruby
RSpec.describe "Hash collision handling" do
  it "logs warning on hash collision" do
    result1 = build_inspection_result(spam_score: 1.0)
    result2 = build_inspection_result(spam_score: 5.0)
    
    ScanResultCache.store("abc123", result1, 5000)
    
    expect(Rails.logger).to receive(:critical).with(/COLLISION/)
    ScanResultCache.store("abc123", result2, 5000)
  end
end
```

---

## Test Data Requirements

### Synthetic Messages

```ruby
def build_test_message(options = {})
  defaults = {
    from: "sender@example.com",
    to: "recipient@example.com",
    subject: "Test Message",
    body: "Test body content",
    size: 10.kilobytes
  }
  Message.create!(defaults.merge(options))
end

def build_newsletter(recipient_count: 100)
  body = generate_html_newsletter(size: 5.megabytes)
  recipients = (1..recipient_count).map { |i| "user#{i}@example.com" }
  
  recipients.map do |recipient|
    build_test_message(body: body, to: recipient)
  end
end

def build_message_with_virus
  build_test_message(
    body: "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*",
    # EICAR test file (safe virus signature)
  )
end
```

### Database Fixtures

```yaml
# fixtures/scan_result_cache.yml
clean_newsletter:
  content_hash: "abc123def456..."
  spam_score: 2.1
  threat: false
  spam_checks: '[{"code":"RULE1","score":1.0}]'
  message_size: 5242880
  scan_timestamp: <%= 1.day.ago.to_f %>
  hit_count: 50
  
expired_entry:
  content_hash: "old123..."
  spam_score: 1.5
  threat: false
  scan_timestamp: <%= 10.days.ago.to_f %>
  hit_count: 1
```

---

## Test Environments

### Local Development
- SQLite or MySQL (developer choice)
- SpamAssassin/ClamAV on localhost (or Docker)
- Sample test data (50 messages)

### CI/CD (GitHub Actions / Jenkins)
- MySQL 8.0
- SpamAssassin/ClamAV containers
- Automated test suite on every commit
- Coverage report generated

### Staging
- Production-like environment
- Real SpamAssassin/ClamAV instances
- Larger dataset (1000+ messages)
- Manual testing before rollout

---

## Acceptance Criteria

**Unit Tests:**
- [ ] 80%+ code coverage
- [ ] All critical paths tested
- [ ] No flaky tests

**Integration Tests:**
- [ ] Newsletter workflow validated
- [ ] Cache hit/miss scenarios covered
- [ ] Security constraints enforced

**Performance Tests:**
- [ ] Hash computation <100ms
- [ ] Cache lookup <10ms
- [ ] Newsletter 10x faster than baseline

**Security Tests:**
- [ ] TOCT scenario tested
- [ ] Threat caching prevented
- [ ] Collision detection works

**Manual Testing:**
- [ ] Staging validation checklist completed
- [ ] No regressions found
- [ ] Cache statistics accurate

---

## Change Log

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-12-31 | OpenCode AI | Initial draft |

---

**Next Document:** [05-DEPLOYMENT-PLAN.md](05-DEPLOYMENT-PLAN.md)
