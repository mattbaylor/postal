# Quick Start: Running Performance Analysis on Production

## Step 1: SSH to Production Server

```bash
ssh root@e1.edify.press
# or
ssh root@e2.edify.press
```

## Step 2: Update Code

```bash
cd /opt/postal
git pull
```

## Step 3: Run Analysis

```bash
# Analyze last 24 hours (default)
./script/run_performance_analysis.sh

# Or specify hours (e.g., 48 hours)
./script/run_performance_analysis.sh 48
```

## Step 4: Get the Results

The script will create a timestamped directory like:
```
/opt/postal/performance_analysis_20260109_150530/
├── analysis_report.txt       # Full text analysis
└── performance_*.csv          # CSV for machine metrics correlation
```

## Step 5: Copy Results to Your Local Machine

From your Mac:

```bash
# Copy the CSV
scp root@e1.edify.press:/opt/postal/performance_analysis_*/performance_*.csv ./

# Or copy the full directory
scp -r root@e1.edify.press:/opt/postal/performance_analysis_20260109_150530 ./
```

## What You'll Get

### Text Report (analysis_report.txt)
- Total messages processed in the time window
- Per-server message counts and averages
- Success/failure rates
- Timing breakdown (min/max/avg/p95/p99) for:
  - Inspection (spam/virus scanning)
  - DKIM signing
  - SMTP delivery
  - Total processing time
- Top 10 slowest messages with full details
- **Round-robin fairness check** (are all servers getting equal access?)
- Top 10 domains by volume

### CSV File (performance_*.csv)
Perfect for correlating with machine metrics (CPU, RAM, Disk I/O):
- One row per message processed
- Columns: timestamp, server_id, message_id, domain, all timing metrics, message_size, status
- Import into Excel/Numbers/spreadsheet
- Group by 1-minute timestamp buckets
- Join with your machine metrics by timestamp
- Analyze correlations

## Expected Results (if everything is working)

✅ **Round-robin working:**
- "Max consecutive messages from same server" should be < 10
- Multiple different server_ids in the logs

✅ **Performance good:**
- P95 total_ms < 3000ms (3 seconds)
- Most deliver_ms time should be in remote SMTP (not our issue)
- inspect_ms and dkim_ms should be very fast (< 5ms for normal messages)

⚠️ **Potential issues to look for:**
- Max consecutive > 20: Round-robin not working properly
- P95 total_ms > 5000ms: Performance problems
- High inspect_ms: Antivirus/spam scanner slowdown
- Any server_id with significantly higher avg times: That server may have issues

## Troubleshooting

**"No timing records found"**
- Make sure you're running version 3.3.4-edify.7 or later
- Check: `docker logs postal_worker_1 | grep TIMING` to verify logs exist

**"Container not found"**
- Check container name: `docker ps`
- May be `postal-web-1` instead of `postal_web_1` (check the hyphen)

**"Permission denied"**
- Make sure scripts are executable: `chmod +x script/*.sh`

---

That's it! The whole process takes ~2 minutes and gives you comprehensive performance insights.
