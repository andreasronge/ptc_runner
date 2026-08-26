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

  mv "$generated_trace" "$artifacts/traces/$journey.jsonl"

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

  for artifact in "$artifacts/traces/$journey.jsonl" "$artifacts/inspection/$journey.ptcins"; do
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

run_journey 01-recovery ok
run_journey 02-bulk ok
run_journey 03-limits any
require_evidence 03-limits "$artifacts/traces/03-limits.jsonl" '"limit-exceeded"' "limit-exceeded events"

# 04/05 must fail for the advertised reason, not from an unrelated
# provider or runtime error: the canonical trace must end in an error
# outcome and the private feedback must carry the intended error code.
run_journey 04-loop-limit error
require_evidence 04-loop-limit "$artifacts/traces/04-loop-limit.jsonl" '"outcome":"error"' "an error run outcome"
require_evidence 04-loop-limit "$artifacts/inspection/04-loop-limit.ptcins" 'loop_limit_exceeded' "loop-limit feedback"
run_journey 05-memory error
require_evidence 05-memory "$artifacts/traces/05-memory.jsonl" '"outcome":"error"' "an error run outcome"
require_evidence 05-memory "$artifacts/inspection/05-memory.ptcins" 'memory_exceeded' "heap-budget feedback"

# The project document must name an application, and it must be a portable
# path beneath the document -- so one journey manifest is copied next to it.
# It stays outside the artifact root, which admits exactly its four children,
# and `viewer` never opens it: the command reads artifacts, not applications.
cp "$demo_dir/01-recovery.json" "$out/ptc.json"

echo
echo "Traces collected in $artifacts. Browse every journey, including its"
echo "private payloads, with:"
echo "  mix ptc viewer $out/ptc-project.json"
