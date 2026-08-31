#!/usr/bin/env bash
# Runs the five viewer-demo journeys against the trusted `deepseek` alias and
# collects sanitized traces plus private inspection artifacts into one
# directory for exercising `mix ptc viewer`. Requires OPENROUTER_API_KEY in
# `.env`, selected explicitly below. Journeys 01/02 must succeed and 04/05 must end in a failing run;
# journey 03's final status depends on how the model reacts to quota
# feedback, but its trace must contain limit-exceeded events. Every journey
# must produce non-empty trace and inspection artifacts, and any deviation
# fails the script.
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to validate private model feedback" >&2
  exit 1
fi

demo_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$demo_dir/../.." && pwd)"
out="${1:-$repo_root/tmp/viewer-demo}"
# The conventional project artifact root: exactly these four children, each
# owner-only, so `ptc viewer` can read the collected journeys directly.
artifacts="$out/artifacts"
mkdir -p "$out"
mkdir -p "$artifacts"
chmod 700 "$artifacts"
for child in envelopes inspection results traces; do
  mkdir -p "$artifacts/$child"
  chmod 700 "$artifacts/$child"
done

# Generated run-reference filenames cannot be rediscovered from journey names.
# Journal only names produced by this script, then remove those exact artifacts
# on the next pass so a rerun still presents exactly five journeys.
run_refs="$out/.viewer-demo-run-refs"
if [ -f "$run_refs" ]; then
  while IFS= read -r previous_run_ref; do
    if [[ "$previous_run_ref" =~ ^cmd-[A-Za-z0-9._-]+$ ]]; then
      rm -f \
        "$artifacts/traces/$previous_run_ref.jsonl" \
        "$artifacts/inspection/$previous_run_ref.ptcins"
    fi
  done < "$run_refs"
fi
: > "$run_refs"

cat > "$out/ptc-project.json" <<'PROJECT'
{
  "$schema": "https://ptc-runner.dev/schemas/ptc-project-config.schema.json",
  "kind": "ptc-project",
  "version": 1,
  "application": {"path": "ptc.json"},
  "artifacts": {"root": "artifacts", "trace": true, "inspection": true},
  "viewer": {"port": 0, "open": false, "repl": false, "private": true}
}
PROJECT

# Generate the granted file root (untracked; regenerated on every run).
mkdir -p "$demo_dir/files"
printf 'alpha line one\nbeta line two\ngamma line three\n' > "$demo_dir/files/notes.txt"
: > "$demo_dir/files/index.txt"
for i in $(seq -w 1 30); do
  printf 'record %s\nvalue %s\n' "$i" "$((10#$i * 7))" > "$demo_dir/files/record-$i.txt"
  printf 'record-%s.txt\n' "$i" >> "$demo_dir/files/index.txt"
done

cd "$repo_root"

run_journey() {
  local journey=$1 expect=$2
  rm -f "$artifacts/traces/$journey.jsonl" "$artifacts/inspection/$journey.ptcins"
  echo "=== $journey ==="
  local marker="$out/.${journey}.started"
  touch "$marker"

  local status=0
  mix ptc run "$demo_dir/$journey.json" \
    --env-file "$repo_root/.env" \
    --host-config "$demo_dir/ptc-host.json" \
    --trace-dir "$artifacts/traces" \
    --inspect "$artifacts/inspection/$journey.ptcins" || status=$?

  local generated_trace
  generated_trace="$(find "$artifacts/traces" -maxdepth 1 -type f -name 'cmd-*.jsonl' -newer "$marker" -print)"
  rm -f "$marker"

  if [ ! -f "$generated_trace" ]; then
    echo "FAIL: $journey did not produce exactly one trace" >&2
    exit 1
  fi

  local run_ref generated_inspection
  run_ref="$(basename "$generated_trace" .jsonl)"
  generated_inspection="$artifacts/inspection/$run_ref.ptcins"
  printf '%s\n' "$run_ref" >> "$run_refs"
  mv "$artifacts/inspection/$journey.ptcins" "$generated_inspection"

  # Directory admission binds canonical trace and inspection artifacts to the
  # generated run reference. Keep that producer-owned filename instead of
  # relabeling the bytes with the human-facing journey name.
  journey_trace="$generated_trace"
  journey_inspection="$generated_inspection"

  case "$expect" in
    ok)
      if [ "$status" -ne 0 ]; then
        echo "FAIL: $journey expected a successful run, exit $status" >&2
        exit 1
      fi
      ;;
    error)
      if [ "$status" -eq 0 ]; then
        echo "FAIL: $journey expected a failing run, exit 0" >&2
        exit 1
      fi
      ;;
    any) ;;
  esac

  for artifact in "$journey_trace" "$journey_inspection"; do
    if [ ! -s "$artifact" ]; then
      echo "FAIL: $journey produced no $artifact" >&2
      exit 1
    fi
  done
}

require_evidence() {
  local journey=$1 file=$2 pattern=$3 label=$4
  if ! grep -q "$pattern" "$file"; then
    echo "FAIL: $journey missing $label in $file" >&2
    exit 1
  fi
}

require_private_feedback() {
  local journey=$1 pattern=$2 label=$3
  local run_ref private_analysis
  run_ref="$(basename "$journey_trace" .jsonl)"

  if ! private_analysis="$(
    mix ptc repl \
      --profile private-run-analysis-v2 \
      --resource "traces=$artifacts/traces" \
      --resource "inspection=$artifacts/inspection" \
      --private-unattended \
      --format jsonl \
      -e "(analysis/read \"$run_ref\" {\"collection\" \"turns\" \"limit\" 100})"
  )"; then
    echo "FAIL: $journey could not query private feedback" >&2
    exit 1
  fi

  if ! jq -s -e --arg pattern "$pattern" \
    'any(.[]
         | select(.type == "evaluation")
         | .result.value.items[]?.feedback[]?.content
         | strings;
         contains($pattern))' <<<"$private_analysis" >/dev/null; then
    echo "FAIL: $journey missing $label in its reconstructed model feedback" >&2
    exit 1
  fi
}

run_journey 01-recovery ok
run_journey 02-bulk ok
run_journey 03-limits any
require_evidence 03-limits "$journey_trace" '"limit-exceeded"' "limit-exceeded events"

# 04/05 must fail for the advertised reason, not from an unrelated
# provider or runtime error: the canonical trace must end in an error
# outcome and a private semantic query must find the intended feedback.
run_journey 04-loop-limit error
require_evidence 04-loop-limit "$journey_trace" '"outcome":"error"' "an error run outcome"
require_private_feedback 04-loop-limit 'loop_limit_exceeded' "loop-limit feedback"
run_journey 05-memory error
require_evidence 05-memory "$journey_trace" '"outcome":"error"' "an error run outcome"
require_private_feedback 05-memory 'mission heap budget' "heap-budget feedback"

# The project document must name an application, and it must be a portable
# path beneath the document -- so one journey manifest is copied next to it.
# It stays outside the artifact root, which admits exactly its four children,
# and `viewer` never opens it: the command reads artifacts, not applications.
cp "$demo_dir/01-recovery.json" "$out/ptc.json"

echo
echo "Traces collected in $artifacts. Browse every journey, including its"
echo "private payloads, with:"
echo "  mix ptc viewer $out/ptc-project.json"
