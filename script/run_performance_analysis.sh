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

# Create output directory on host
mkdir -p "${OUTPUT_DIR}"

# Run analysis script inside Docker container
echo "Running analysis..."
docker exec postal_web_1 ruby script/analyze_performance_logs.rb --hours "${HOURS}" | tee "${OUTPUT_DIR}/analysis_report.txt"

# Copy CSV files from container to host
echo
echo "Copying CSV files..."
docker cp postal_web_1:/opt/postal/tmp/performance_analysis/. "${OUTPUT_DIR}/"

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
