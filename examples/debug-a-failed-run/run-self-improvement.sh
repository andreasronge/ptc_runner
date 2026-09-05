#!/bin/sh
# Run from a fresh copy of the example. PTC performs all evidence processing.
set -eu
umask 077
: "${1:?Usage: sh run-self-improvement.sh /absolute/path/to/.env}"
case "$1" in
  /*) credentials_file=$1 ;;
  *) credentials_file=$(cd "$(dirname "$1")" && pwd)/$(basename "$1") ;;
esac
cd "$(dirname "$0")"
results=self-improvement-results
mkdir "$results"
mkdir -p self-improver self-check self-check-workflow self-repair

expect_failure() {
  if ptc run "$1" --env-file "$credentials_file"; then
    echo "Expected the seeded failure from $1" >&2
    exit 1
  else
    status=$?
    if [ "$status" -ne 5 ]; then exit "$status"; fi
  fi
}

echo '1. Capture the application failure and the debugging workflow failure.'
expect_failure target.ptc-project.json
expect_failure self-debugger.ptc-project.json

echo '2. Let the agent inspect and repair its navigation helper.'
ptc run self-improver.ptc-project.json --env-file "$credentials_file" \
  --private-output "$results/helper-proposal.private.json" --progress
ptc materialize self-debugger.ptc-project.json --target-mission evidence \
  --component debug.start --from-result "$results/helper-proposal.private.json" \
  --result-pointer /candidate_source --out "$results/helper"

echo '3. Check the helper on two different frozen applications, without model calls.'
ptc run self-check.ptc-project.json \
  --component-override-descriptor "$results/helper/descriptor.json" \
  --private-output "$results/helper-check.private.json"
expect_failure target-workflow-control.ptc-project.json
ptc run self-check-workflow.ptc-project.json \
  --component-override-descriptor "$results/helper/descriptor.json" \
  --private-output "$results/helper-workflow-check.private.json"

echo '4. Use the improved workflow to navigate the application failure.'
ptc run self-debugger.ptc-project.json --env-file "$credentials_file" \
  --component-override-descriptor "$results/helper/descriptor.json" \
  --private-output "$results/diagnosis.private.json" --progress
ptc repl --project self-debugger.ptc-project.json \
  --profile private-run-analysis-v2 --private-unattended --preview-chars 64 \
  --private-output "$results/repair-input.private.json" \
  -e "$(cat self-debugger/repair-input.clj)"

echo '5. Propose the application repair and check independent inputs.'
ptc run self-repair.ptc-project.json --env-file "$credentials_file" \
  --private-input "$results/repair-input.private.json" \
  --private-output "$results/application-proposal.private.json" --progress
ptc materialize target.ptc-project.json --target-mission pricing \
  --component pricing.rule --from-result "$results/application-proposal.private.json" \
  --result-pointer /candidate_source --out "$results/application"
for input in self-debugger/validation/*.json; do
  ptc run target.ptc-project.json --input "$input" \
    --component-override-descriptor "$results/application/descriptor.json" \
    --private-output "$results/validated-$(basename "$input")"
done
echo "Completed: helper checks, trace navigation, and three application validation cases. Artifacts: $results"
