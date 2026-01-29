#!/usr/bin/env bash
# Run a suite of RLM benchmarks at increasing scale.
# Results are stored in results/<timestamp>/ with one log per run.
#
# Usage:
#   ./run_benchmarks.sh              # Run all benchmarks
#   ./run_benchmarks.sh counting     # Run only counting benchmarks
#   ./run_benchmarks.sh pairs        # Run only pairs benchmarks

set -euo pipefail
cd "$(dirname "$0")"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="results/${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"

echo "═══════════════════════════════════════════════════════"
echo " RLM Benchmark Suite — $(date)"
echo " Results: ${RESULTS_DIR}/"
echo "═══════════════════════════════════════════════════════"
echo ""

run_one() {
  local name="$1"
  local benchmark="$2"
  local profiles="$3"
  local logfile="${RESULTS_DIR}/${name}.log"

  echo "▶ ${name} (benchmark=${benchmark}, profiles=${profiles})"
  if mix run run.exs --benchmark "$benchmark" --profiles "$profiles" --trace --progress 2>&1 | tee "$logfile"; then
    echo "  ✅ Done — ${logfile}"
  else
    echo "  ❌ Failed — see ${logfile}"
  fi
  echo ""
}

FILTER="${1:-all}"

# --- Counting: expect no recursion at any scale ---
if [[ "$FILTER" == "all" || "$FILTER" == "counting" ]]; then
  echo "━━━ Counting (O(n) — should NOT recurse) ━━━"
  run_one "counting_500"  counting 500
  run_one "counting_5000" counting 5000
fi

# --- Pairs: expect recursion at larger scales ---
if [[ "$FILTER" == "all" || "$FILTER" == "pairs" ]]; then
  echo "━━━ Pairs (O(n²) — recursion essential at scale) ━━━"
  run_one "pairs_50"  pairs 50
  run_one "pairs_100" pairs 100
  run_one "pairs_200" pairs 200
fi

# --- Summary ---
echo "═══════════════════════════════════════════════════════"
echo " All runs complete. Results in: ${RESULTS_DIR}/"
echo "═══════════════════════════════════════════════════════"

# Extract key metrics from logs
echo ""
echo "Summary:"
echo "────────────────────────────────────────────────────────"
printf "%-20s %-10s %-10s %s\n" "Run" "Expected" "Actual" "Correct"
echo "────────────────────────────────────────────────────────"
for logfile in "${RESULTS_DIR}"/*.log; do
  name=$(basename "$logfile" .log)
  expected=$(sed -n 's/.*Expected: \([^ ]*\).*/\1/p' "$logfile" | tail -1)
  actual=$(sed -n 's/.*Actual: \([^ ]*\).*/\1/p' "$logfile" | tail -1)
  correct=$(sed -n 's/.*Correct: \([^ ]*\).*/\1/p' "$logfile" | tail -1)
  expected=${expected:-?}; actual=${actual:-?}; correct=${correct:-?}
  printf "%-20s %-10s %-10s %s\n" "$name" "$expected" "$actual" "$correct"
done
