# Standalone Dead Webhook Cleanup Script

This script disables webhooks that are consistently failing by connecting directly to MariaDB, **without requiring access to the Docker container**.

## Purpose

Webhooks that repeatedly fail (connection refused, timeouts, etc.) create excessive log noise and waste system resources. This script identifies and disables them.

## Requirements

- Ruby 2.7+ with `mysql2` gem installed
- Direct network access to MariaDB database
- Read access to `postal.yml` configuration file

## Installation

On the Postal server, install the mysql2 gem:

```bash
# If using system Ruby
sudo gem install mysql2

# Or if using rbenv/rvm
gem install mysql2
```

## Usage

### Basic Usage (Dry Run)

By default, the script runs in **dry-run mode** and shows what would be disabled without making changes:

```bash
ruby script/standalone_disable_dead_webhooks.rb
```

### Live Mode (Actually Disable Webhooks)

To actually disable the dead webhooks:

```bash
ruby script/standalone_disable_dead_webhooks.rb --live
```

### Custom Configuration Path

If postal.yml is not in the default location:

```bash
ruby script/standalone_disable_dead_webhooks.rb --config /path/to/postal.yml
```

### Adjust Thresholds

```bash
# Require 20 failures in last 48 hours
ruby script/standalone_disable_dead_webhooks.rb --threshold 20 --hours 48
```

## Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `--live` | Actually disable webhooks (not dry-run) | false (dry-run) |
| `--config PATH` | Path to postal.yml | `/opt/postal/config/postal.yml` |
| `--threshold N` | Minimum failed requests to consider | 10 |
| `--hours N` | Look back window in hours | 24 |
| `-h`, `--help` | Show help message | - |

## Environment Variables

You can also use environment variables instead of command-line options:

```bash
DRY_RUN=false \
CONFIG_PATH=/opt/postal/config/postal.yml \
FAILURE_THRESHOLD=15 \
TIME_WINDOW_HOURS=48 \
ruby script/standalone_disable_dead_webhooks.rb
```

## How It Works

1. **Reads postal.yml** to get MariaDB connection details
2. **Connects to database** using credentials from config
3. **Queries webhook_requests** table for recent failures
4. **Identifies webhooks** with error status codes:
   - `-2` = Connection failed
   - `-1` = Other errors (timeout, etc.)
5. **Disables webhooks** that exceed failure threshold

## Example Output

```
================================================================================
Dead Webhook Detector (Standalone)
================================================================================
Mode: DRY RUN (no changes)
Config: /opt/postal/config/postal.yml
Threshold: 10 failed requests in last 24 hours
Error codes: -2, -1
================================================================================

Connecting to database:
  Host: db.edify.press:3306
  Database: postal
  Username: postal

✓ Connected to database

Found 3 dead webhook(s):

Webhook ID: 7
  Server: example-server (ID: 42)
  URL: https://dead-endpoint.example.com/webhook
  Enabled: true
  Total requests (24h): 152
  Failed requests: 152
  Failure rate: 100.0%
  Last error: Connection refused - connect(2) for "dead-endpoint.example.com" port 443
  Last attempt: 2026-01-03 14:23:45 UTC
  → Would disable (DRY RUN)

[... more webhooks ...]

================================================================================
DRY RUN complete. Run with --live to actually disable webhooks.
================================================================================
```

## Running on Production Servers

### On e1.edify.press (postal database)

```bash
# Dry run first to see what would be disabled
ruby script/standalone_disable_dead_webhooks.rb

# If output looks good, disable them
ruby script/standalone_disable_dead_webhooks.rb --live
```

### On e2.edify.press (e2postal database)

The script reads the database name from postal.yml, so it automatically uses the correct database:

```bash
# Dry run
ruby script/standalone_disable_dead_webhooks.rb

# Live
ruby script/standalone_disable_dead_webhooks.rb --live
```

## Safety Features

- **Dry-run by default**: Won't make changes unless `--live` is specified
- **Detailed reporting**: Shows exactly what will be disabled before taking action
- **Configurable thresholds**: Adjust sensitivity to avoid disabling temporarily failing webhooks
- **Read-only first**: Queries database to show report before any modifications
- **Connection validation**: Fails fast if can't connect to database

## Troubleshooting

### Error: Config file not found

```
ERROR: Config file not found: /opt/postal/config/postal.yml
```

**Solution**: Specify correct path with `--config`:
```bash
ruby script/standalone_disable_dead_webhooks.rb --config /path/to/postal.yml
```

### Error: Failed to connect to database

```
ERROR: Failed to connect to database: Access denied for user 'postal'@'host'
```

**Solution**: Verify database credentials in postal.yml are correct and user has access.

### Error: mysql2 gem not installed

```
cannot load such file -- mysql2 (LoadError)
```

**Solution**: Install the mysql2 gem:
```bash
gem install mysql2
```

## Comparison with Docker-Based Script

| Feature | Standalone Script | Docker Script |
|---------|------------------|---------------|
| Requires Docker | No | Yes |
| Requires mysql2 gem | Yes | No (included) |
| Access method | Direct MariaDB | Through Rails |
| Config source | postal.yml | Rails environment |
| Use case | External automation, cron | One-time manual runs |

## Automation with Cron

You can run this script periodically to automatically clean up dead webhooks:

```bash
# Add to crontab: Run daily at 3 AM
0 3 * * * cd /opt/postal && ruby script/standalone_disable_dead_webhooks.rb --live >> /var/log/postal/dead_webhooks.log 2>&1
```

## Security Notes

- Script requires read access to postal.yml (contains DB password)
- Ensure script has appropriate file permissions (e.g., 600 or 700)
- Database user needs SELECT and UPDATE permissions on `webhooks` and `webhook_requests` tables
- Consider running from a secure location with limited access
