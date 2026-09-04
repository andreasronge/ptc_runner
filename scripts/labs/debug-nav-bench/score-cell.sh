#!/bin/zsh
# usage: score-cell.sh CELL_DIR [SESSION_TRACE_DIR]
# One JSON array: per run id, status, terminal reason, LLM calls, cost in USD microunits, tokens, duration.
C=${1:?cell dir with .ptc}; T=${2:-$C/../analysis-traces}; mkdir -p "$T"
ptc repl --profile private-run-analysis-v2 --private-unattended \
  --resource traces="$C/.ptc/traces" --resource inspection="$C/.ptc/inspection" \
  --session-trace-dir "$T" --format jsonl \
  -e '(mapv (fn [r] (let [c (analysis/counters {"run_id" (get r "run_id")}) u (first (get c "llm_usage"))] {"run_id" (get r "run_id") "status" (get r "status") "terminal" (get r "terminal_reason") "llm_calls" (get r "llm_calls") "cost" (get-in u ["usage" "total_cost" "microunits"]) "in" (get-in u ["usage" "input"]) "out" (get-in u ["usage" "output"]) "ms" (get r "duration_ms")})) (get (analysis/runs {"limit" 10}) "items"))' 2>&1 \
  | grep '"type":"evaluation"' | sed -E 's/.*"value":(\[.*\]),"value_available".*/\1/'
