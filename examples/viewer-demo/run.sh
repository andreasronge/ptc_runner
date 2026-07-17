#!/usr/bin/env bash
# Runs the five viewer-demo journeys against the trusted `deepseek` alias and
# collects sanitized traces plus private inspection artifacts into one
# directory for exercising `mix ptc.viewer`. Requires OPENROUTER_API_KEY in
# `.env`. Journeys 01/02 must succeed and 04/05 must end in a failing run;
# journey 03's final status depends on how the model reacts to quota
# feedback, but its trace must contain limit-exceeded events. Every journey
# must produce non-empty trace and inspection artifacts, and any deviation
# fails the script.
set -euo pipefail

demo_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$demo_dir/../.." && pwd)"
out="${1:-$repo_root/tmp/viewer-demo}"
mkdir -p "$out"

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
  rm -f "$out/$journey.jsonl" "$out/$journey.inspection.jsonl"
  echo "=== $journey ==="

  local status=0
  mix ptc.run "$demo_dir/$journey.json" \
    --trace "$out/$journey.jsonl" \
    --inspect "$out/$journey.inspection.jsonl" || status=$?

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

  for artifact in "$out/$journey.jsonl" "$out/$journey.inspection.jsonl"; do
    if [ ! -s "$artifact" ]; then
      echo "FAIL: $journey produced no $artifact" >&2
      exit 1
    fi
  done
}

run_journey 01-recovery ok
run_journey 02-bulk ok
run_journey 03-limits any
if ! grep -q '"limit-exceeded"' "$out/03-limits.jsonl"; then
  echo "FAIL: 03-limits produced no limit-exceeded events" >&2
  exit 1
fi
run_journey 04-loop-limit error
run_journey 05-memory error

echo
echo "Traces collected in $out. View one journey's private payloads with e.g.:"
echo "  mix ptc.viewer --trace-dir $out --inspection-file $out/01-recovery.inspection.jsonl"
