#!/bin/zsh
# usage: turns.sh CELL_DIR RUN_ID [CHARS]   — one line per model turn: the program the model wrote (prefix).
C=${1:?cell dir}; RID=${2:?run id}; N=${3:-100}; T=$C/../analysis-traces; mkdir -p "$T"
ptc repl --profile private-run-analysis-v2 --private-unattended --run "$RID" \
  --resource traces="$C/.ptc/traces" --resource inspection="$C/.ptc/inspection" \
  --session-trace-dir "$T" --format jsonl \
  -e "(mapv (fn [t] (str (get t \"turn\") \": \" (subs (str (get-in t [\"generated\" 0 \"source\"])) 0 (min $N (count (str (get-in t [\"generated\" 0 \"source\"]))))))) (get (analysis/read \"$RID\" {\"collection\" \"turns\" \"limit\" 64}) \"items\"))" 2>&1 \
  | grep '"type":"evaluation"' | sed -E 's/.*"value":(\[.*\]),"value_available".*/\1/' | sed 's/","/"\n"/g'
