# Performance Analysis Script

The `analyze_performance_logs.rb` script analyzes Postal worker performance logs and generates both CSV output for correlation with machine metrics and a detailed analysis report.

## Usage on Production Servers

Since the production servers don't have Ruby installed outside of Docker, run the script through the Postal Docker container:

### Option 1: Run from Web Container (Recommended)

```bash
# SSH to production server (e.g., e1.edify.press)
cd /opt/postal

# Run analysis for last 24 hours
docker exec postal_web_1 ruby script/analyze_performance_logs.rb

# Run analysis for last 48 hours
docker exec postal_web_1 ruby script/analyze_performance_logs.rb --hours 48

# Copy the CSV output to host
docker cp postal_web_1:/opt/postal/tmp/performance_analysis/. ./performance_analysis/
```

### Option 2: Run from Worker Container

```bash
# Run from worker container
docker exec postal_worker_1 ruby script/analyze_performance_logs.rb --hours 24

# Copy output
docker cp postal_worker_1:/opt/postal/tmp/performance_analysis/. ./performance_analysis/
```

### Option 3: Remote Analysis via SSH

Run from your local machine to analyze a remote server:

```bash
# From your development machine
cd /Users/matt/repo/postal

# Analyze e1.edify.press
ruby script/analyze_performance_logs.rb --server e1.edify.press --hours 24

# Analyze e2.edify.press
ruby script/analyze_performance_logs.rb --server e2.edify.press --hours 48
```

## Output

### Console Output
The script prints a comprehensive analysis to stdout including:
- Overall statistics (total messages, time range, unique servers)
- By-server breakdown (message count and average processing time)
- Status breakdown (success/failure rates)
- Timing breakdown (min/max/avg/p95/p99 for inspect, DKIM, delivery, total)
- Top 10 slowest messages with full timing details
- Server fairness analysis (round-robin effectiveness)
- Top 10 domains by message count

### CSV Output
A timestamped CSV file is generated in `tmp/performance_analysis/` with columns:
- `log_timestamp` - When the message was processed
- `message_id` - Unique message ID
- `server_id` - Which Postal server processed it
- `queue_id` - Queue identifier
- `domain` - Destination domain
- `status` - Processing status (success/failed/etc)
- `inspect_ms` - Time spent on spam/virus scanning
- `dkim_ms` - Time spent on DKIM signing
- `deliver_ms` - Time spent on SMTP delivery
- `total_ms` - Total processing time
- `message_size` - Message size in bytes
- `start_time` - ISO timestamp of processing start

## Correlating with Machine Metrics

1. **Collect Postal performance data:**
   ```bash
   docker exec postal_web_1 ruby script/analyze_performance_logs.rb --hours 24
   docker cp postal_web_1:/opt/postal/tmp/performance_analysis/performance_*.csv ./
   ```

2. **Collect machine metrics** (CPU, RAM, Disk I/O) at 1-minute intervals:
   ```bash
   # Example using sar, dstat, or your monitoring tool
   # Export as CSV with timestamp column
   ```

3. **Merge CSVs** by rounding log_timestamp to 1-minute buckets

4. **Analyze correlations:**
   - High `deliver_ms` times → Network issues or remote server slowness
   - High `inspect_ms` → CPU pressure or antivirus delays
   - High `dkim_ms` → CPU pressure (signature calculation)
   - Processing delays → RAM pressure, disk I/O bottlenecks, or thread starvation

## Interpreting Results

### Server Fairness (Round-Robin)
- **Max consecutive messages < 10**: Round-robin is working well
- **Max consecutive messages > 20**: One server may be dominating, investigate queue distribution

### Timing Percentiles
- **P95 total_ms < 3000ms** (3 seconds): Good performance
- **P95 total_ms 3000-5000ms**: Acceptable, monitor for trends
- **P95 total_ms > 5000ms**: Performance issue, investigate slowest messages

### By Operation
- **High inspect_ms**: Check antivirus/spam scanner performance or disable if not needed
- **High dkim_ms**: Usually only high for very large messages (>1MB), check message_size correlation
- **High deliver_ms**: Usually remote server delays (Yahoo, Gmail, etc.), not a Postal issue

## Example Output

```
================================================================================
POSTAL PERFORMANCE LOG ANALYZER
================================================================================
Analyzing logs from: local
Time range: Last 24 hours
Output directory: /opt/postal/tmp/performance_analysis
================================================================================

Fetching logs...
Fetched 1847 log lines

Parsing logs...
Parsed 1847 timing records

Generating CSV: /opt/postal/tmp/performance_analysis/performance_20260109_143022.csv
CSV generated with 1847 rows

================================================================================
PERFORMANCE ANALYSIS SUMMARY
================================================================================

OVERALL STATISTICS
--------------------------------------------------------------------------------
Total messages processed: 1847
Time range: 2026-01-08 14:30 to 2026-01-09 14:30
Unique servers: 18
Unique domains: 142

BY-SERVER MESSAGE COUNT
--------------------------------------------------------------------------------
  Server 3: 287 messages (avg: 1247.82ms)
  Server 11: 156 messages (avg: 982.41ms)
  Server 13: 134 messages (avg: 1105.23ms)
  ...

TIMING BREAKDOWN (milliseconds)
--------------------------------------------------------------------------------
  TOTAL MS:
    Min:    245.12ms
    Max:    8234.56ms
    Avg:    1156.78ms
    Median: 892.34ms
    P95:    2845.12ms
    P99:    4567.89ms

  DELIVER MS:
    Min:    198.45ms
    Max:    7890.23ms
    Avg:    1023.45ms
    Median: 785.12ms
    P95:    2567.89ms
    P99:    4234.56ms
...
```

## Troubleshooting

**Error: "Failed to fetch logs"**
- Ensure the Docker container is running: `docker ps`
- Check container name matches (default: `postal_worker_1`)
- Ensure you have permission to access Docker logs

**Error: "No timing records found"**
- Verify the timing instrumentation is deployed (version 3.3.4-edify.7+)
- Check worker logs manually: `docker logs postal_worker_1 | grep TIMING`
- Try increasing the hours: `--hours 48`

**CSV file is empty**
- No messages were processed in the time range
- Worker may not be running: `docker logs postal_worker_1`

## Requirements

- Postal version 3.3.4-edify.7 or later (includes timing instrumentation)
- Docker container running with access to logs
- For remote analysis: SSH access to production server
