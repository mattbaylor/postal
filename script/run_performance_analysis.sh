#!/bin/bash
# Helper script to run performance analysis on production server
# Usage: ./run_performance_analysis.sh [hours]

set -e

HOURS=${1:-24}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/opt/postal/performance_analysis_${TIMESTAMP}"

echo "=================================="
echo "Postal Performance Analysis"
echo "=================================="
echo "Analyzing last ${HOURS} hours"
echo "Output directory: ${OUTPUT_DIR}"
echo "=================================="
echo

# Auto-detect container names
WEB_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E '(postal.*web|web.*postal)' | head -1)
WORKER_CONTAINER=$(docker ps --format '{{.Names}}' | grep -E '(postal.*worker|worker.*postal)' | head -1)

if [ -z "$WEB_CONTAINER" ]; then
    echo "ERROR: Could not find web container"
    echo "Available containers:"
    docker ps --format '{{.Names}}'
    exit 1
fi

echo "Using web container: ${WEB_CONTAINER}"
echo "Using worker container: ${WORKER_CONTAINER}"
echo

# Create output directory on host
mkdir -p "${OUTPUT_DIR}"

# Run analysis script inside Docker container
echo "Running analysis..."

# Fetch logs on the host, pipe to Ruby script in container
docker logs --since "${HOURS}h" "${WORKER_CONTAINER}" 2>&1 | \
  grep TIMING | \
  docker exec -i "${WEB_CONTAINER}" ruby script/analyze_performance_logs.rb --hours "${HOURS}" --stdin | \
  tee "${OUTPUT_DIR}/analysis_report.txt"

# Copy CSV files from container to host
echo
echo "Copying CSV files..."
docker cp "${WEB_CONTAINER}:/opt/postal/app/tmp/performance_analysis/." "${OUTPUT_DIR}/"

# List output files
echo
echo "=================================="
echo "Analysis complete!"
echo "=================================="
echo "Files created:"
ls -lh "${OUTPUT_DIR}"

echo
echo "To view the report:"
echo "  cat ${OUTPUT_DIR}/analysis_report.txt"
echo
echo "To copy CSV to your local machine:"
echo "  scp $(hostname):${OUTPUT_DIR}/performance_*.csv ./"
echo
