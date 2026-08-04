#!/usr/bin/env bash
# One (incident, arm) run. Appends one JSONL row to results.jsonl.
# Re-invoke to add repeats; nothing is overwritten.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXP="${PTC_EXP_DIR:-$REPO/incident_compiler/experiments/runs}"
INCIDENT="$1"; ARM="$2"; REP="${3:-1}"
TAG="${ARM}-${INCIDENT}-${REP}"
# The condition this run belongs to. A tag is (arm, incident, rep) only, so two
# conditions produce colliding tags; the results file distinguishes them by
# `set`, and that has to come from the harness rather than be added afterwards.
SET="${PTC_EXP_SET:-$(basename "$EXP")}"
# Artifacts are keyed by tag, so two conditions sharing one PTC_EXP_DIR would
# delete each other's traces. Fold the set into the tag when it is not the
# directory name it defaults to.
if [ "$SET" != "$(basename "$EXP")" ]; then
  TAG="$(printf %s "$SET" | tr -c "A-Za-z0-9._-" "-")-${TAG}"
fi

case "$ARM" in
  fast) MANIFEST=exp-single-pass.json ;;
  loop) MANIFEST=exp-loop.json ;;
  authored) MANIFEST=exp-authored.json ;;
  *) echo "unknown arm $ARM" >&2; exit 2 ;;
esac

# ptc.run refuses to overwrite a result, trace, or inspection artifact, so a
# re-run needs a clean slate. Clearing per-tag also stops a failed run being
# scored against the previous run's report.
rm -rf "$EXP/traces/$TAG" "$EXP/inspect/$TAG"
rm -f "$EXP/reports/$TAG.json" "$EXP/reports/$TAG.err"
mkdir -p "$EXP/traces/$TAG" "$EXP/inspect/$TAG" "$EXP/reports"
cd "$REPO" || exit 2

python3 - "$MANIFEST" "$INCIDENT" <<'PY'
import json, collections, sys
m, incident = sys.argv[1], sys.argv[2]
p = f"incident_compiler/{m}"
d = json.load(open(p), object_pairs_hook=collections.OrderedDict)
d["input"]["value"]["incident_id"] = incident
json.dump(d, open(p, "w"), indent=2)
PY

START=$(date +%s)
timeout 900 mix ptc.run "incident_compiler/$MANIFEST" \
  --host-config incident_compiler/ptc-host.json \
  --trace "$EXP/traces/$TAG/run.jsonl" \
  --inspect "$EXP/inspect/$TAG/run.inspection.jsonl" \
  --output "$EXP/reports/$TAG.json" >/dev/null 2>"$EXP/reports/$TAG.err"
STATUS=$?
END=$(date +%s)

mix run "$REPO/incident_compiler/experiments/collect.exs" "$TAG" "$INCIDENT" "$ARM" "$REP" "$STATUS" "$((END-START))" \
  "$EXP/traces/$TAG/run.jsonl" "$EXP/reports/$TAG.json" \
  "$EXP/inspect/$TAG/run.inspection.jsonl" "$SET" >> "$EXP/results.jsonl"
tail -1 "$EXP/results.jsonl"
