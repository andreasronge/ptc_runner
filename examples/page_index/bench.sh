#!/usr/bin/env bash
# Benchmark script: runs each question 5 times and collects results
# Usage: cd examples/page_index && bash bench.sh

set -euo pipefail

RUNS=5
PDF="data/3M_2022_10K.pdf"
RESULTS_DIR="bench_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SUMMARY_FILE="${RESULTS_DIR}/summary_${TIMESTAMP}.txt"

mkdir -p "$RESULTS_DIR"

# Questions from data/questions.json (3M_2022_10K only)
declare -a QUESTIONS=(
  "Is 3M a capital-intensive business based on FY2022 data?"
  "What drove operating margin change as of FY2022 for 3M?"
  "If we exclude the impact of M&A, which segment has dragged down 3M's overall growth in 2022?"
)

declare -a DIFFICULTY=(
  "medium"
  "hard"
  "hard"
)

declare -a EXPECTED=(
  "No. CAPEX to Revenue ratio ~5.1%, efficient capital management"
  "Operating margin decreased ~1.7pp from higher costs, litigation, restructuring"
  "Consumer segment, organic sales decline ~0.9%"
)

echo "========================================" | tee "$SUMMARY_FILE"
echo "PlanRunner Benchmark — $(date)" | tee -a "$SUMMARY_FILE"
echo "Model: bedrock:haiku" | tee -a "$SUMMARY_FILE"
echo "Runs per question: $RUNS" | tee -a "$SUMMARY_FILE"
echo "========================================" | tee -a "$SUMMARY_FILE"
echo "" | tee -a "$SUMMARY_FILE"

total_pass=0
total_fail=0
total_runs=0

for q_idx in "${!QUESTIONS[@]}"; do
  question="${QUESTIONS[$q_idx]}"
  diff="${DIFFICULTY[$q_idx]}"
  expected="${EXPECTED[$q_idx]}"
  q_num=$((q_idx + 1))

  echo "────────────────────────────────────────" | tee -a "$SUMMARY_FILE"
  echo "Q${q_num} [${diff}]: ${question}" | tee -a "$SUMMARY_FILE"
  echo "Expected: ${expected}" | tee -a "$SUMMARY_FILE"
  echo "────────────────────────────────────────" | tee -a "$SUMMARY_FILE"

  pass=0
  fail=0

  for run in $(seq 1 "$RUNS"); do
    run_file="${RESULTS_DIR}/q${q_num}_run${run}_${TIMESTAMP}.txt"
    echo -n "  Run ${run}/${RUNS}... "

    start_time=$SECONDS
    if mix run run.exs --query "$question" --pdf "$PDF" --planner --trace > "$run_file" 2>&1; then
      elapsed=$((SECONDS - start_time))

      # Extract answer and replan count
      answer=$(grep -A 50 "^ANSWER" "$run_file" | grep -v "^ANSWER\|^====\|^$\|^Sources:" | head -5)
      replans=$(grep -o 'after [0-9]* replans' "$run_file" | grep -o '[0-9]*' || echo "?")
      tasks=$(grep -o '[0-9]* tasks)' "$run_file" | grep -o '[0-9]*' || echo "?")

      echo "OK (${elapsed}s, ${replans} replans, ${tasks} tasks)" | tee -a "$SUMMARY_FILE"
      echo "    Answer: $(echo "$answer" | head -1 | cut -c1-120)" | tee -a "$SUMMARY_FILE"
      pass=$((pass + 1))
    else
      elapsed=$((SECONDS - start_time))
      error=$(grep -E "^Error:" "$run_file" | head -1)
      echo "FAIL (${elapsed}s)" | tee -a "$SUMMARY_FILE"
      echo "    Error: ${error:-unknown}" | tee -a "$SUMMARY_FILE"
      fail=$((fail + 1))
    fi
  done

  echo "  Result: ${pass}/${RUNS} passed, ${fail}/${RUNS} failed" | tee -a "$SUMMARY_FILE"
  echo "" | tee -a "$SUMMARY_FILE"

  total_pass=$((total_pass + pass))
  total_fail=$((total_fail + fail))
  total_runs=$((total_runs + RUNS))
done

echo "========================================" | tee -a "$SUMMARY_FILE"
echo "TOTAL: ${total_pass}/${total_runs} passed, ${total_fail}/${total_runs} failed" | tee -a "$SUMMARY_FILE"
echo "Results in: ${RESULTS_DIR}/" | tee -a "$SUMMARY_FILE"
echo "Summary: ${SUMMARY_FILE}" | tee -a "$SUMMARY_FILE"
echo "========================================" | tee -a "$SUMMARY_FILE"
