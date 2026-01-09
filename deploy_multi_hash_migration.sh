#!/bin/bash
# Deploy script for multi-hash cache enhancement migration
# Run this script on each server (e1 and e2)

set -e

echo "==== Multi-Hash Cache Migration Deployment ===="
echo ""

# Detect which server we're on
if [ -f "/opt/postal/config/postal.yml" ]; then
    if grep -q "database: e2postal" /opt/postal/config/postal.yml; then
        SERVER="e2"
    else
        SERVER="e1"
    fi
else
    echo "Error: Could not detect server configuration"
    exit 1
fi

echo "Detected server: $SERVER"
echo ""

# Find the worker container
WORKER_CONTAINER=$(docker ps --filter 'name=worker' --format '{{.Names}}' | head -1)

if [ -z "$WORKER_CONTAINER" ]; then
    echo "Error: Could not find worker container"
    exit 1
fi

echo "Using container: $WORKER_CONTAINER"
echo ""

# Step 1: Run the migration
echo "Step 1: Running database migration..."
docker exec "$WORKER_CONTAINER" rails db:migrate

if [ $? -eq 0 ]; then
    echo "✓ Migration completed successfully"
else
    echo "✗ Migration failed"
    exit 1
fi
echo ""

# Step 2: Verify the migration
echo "Step 2: Verifying migration..."
docker exec "$WORKER_CONTAINER" rails runner "
  if ActiveRecord::Base.connection.column_exists?(:scan_result_cache, :attachment_hash) &&
     ActiveRecord::Base.connection.column_exists?(:scan_result_cache, :body_template_hash) &&
     ActiveRecord::Base.connection.column_exists?(:scan_result_cache, :matched_via)
    puts '✓ All columns added successfully'
    exit 0
  else
    puts '✗ Migration verification failed'
    exit 1
  end
"

if [ $? -ne 0 ]; then
    echo "Migration verification failed"
    exit 1
fi
echo ""

# Step 3: Restart workers
echo "Step 3: Restarting worker containers..."
WORKER_CONTAINERS=$(docker ps --filter 'name=worker' --format '{{.Names}}')
for container in $WORKER_CONTAINERS; do
    echo "Restarting $container..."
    docker restart "$container"
done

echo ""
echo "✓ Deployment completed successfully on $SERVER"
echo ""
echo "Next steps:"
echo "1. Monitor logs: docker logs -f $WORKER_CONTAINER"
echo "2. Check for cache HIT/MISS messages"
echo "3. Send test emails with personalized content"
echo ""
