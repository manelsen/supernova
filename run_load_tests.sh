#!/bin/bash
set -e

BASE_URL="${SUPERNOVA_BASE_URL:-http://localhost:8080}"
export SUPERNOVA_BASE_URL

echo "=== Supernova Load Tests ==="
echo "Base URL: $BASE_URL"
echo ""

command -v k6 >/dev/null 2>&1 || { echo "k6 not installed. See tests/load/README.md"; exit 1; }

echo "--- Smoke Test ---"
k6 run --quiet tests/load/smoke_test.js

echo ""
echo "--- Concurrency Test ---"
k6 run --quiet tests/load/concurrency_test.js

echo ""
echo "--- Sustained Load Test ---"
k6 run --quiet tests/load/sustained_load.js

echo ""
echo "--- Budget Exhaustion Test ---"
k6 run --quiet tests/load/budget_exhaustion.js

echo ""
echo "=== All load tests passed ==="
