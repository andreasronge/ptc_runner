#!/bin/zsh
# usage: ENV_FILE=/path/.env run-cell.sh EXAMPLE_DIR OUT_DIR CELL [SAMPLES]
# Runs SAMPLES (default 3) sequential samples of one cell, appends one line per run to OUT_DIR/log.txt,
# and copies each run's report to OUT_DIR/CELL-N.result.json.
E=${1:?example dir}; O=${2:?out dir}; cell=${3:?cell}; n=${4:-3}
: ${ENV_FILE:?set ENV_FILE to the environment file holding OPENROUTER_API_KEY}
mkdir -p "$O"
for i in $(seq 1 $n); do
  before=$(ls "$E/$cell/.ptc/results" 2>/dev/null | sort)
  start=$(date +%s)
  ptc run "$E/$cell.ptc-project.json" --env-file "$ENV_FILE" --envelope "$O/$cell-$i.envelope.json" > "$O/$cell-$i.stdout" 2>&1
  rc=$?
  end=$(date +%s)
  after=$(ls "$E/$cell/.ptc/results" 2>/dev/null | sort)
  new=$(comm -13 <(echo "$before") <(echo "$after") | head -1)
  [ -n "$new" ] && cp "$E/$cell/.ptc/results/$new" "$O/$cell-$i.result.json"
  echo "$cell $i exit=$rc wall=$((end-start))s result=${new:-none} :: $(head -c 200 "$O/$cell-$i.stdout" | tr '\n' ' ')" >> "$O/log.txt"
done
