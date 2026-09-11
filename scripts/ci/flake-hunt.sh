#!/usr/bin/env bash

# Runs the PR test suite repeatedly under GitHub's CPU shape and tabulates
# which tests failed, how often, and with which seeds.
#
# A flake is a test that fails only under load or under a particular seed,
# so a single run says nothing about it. This runs the suite N times with a
# fresh seed each, records every run through the RunRecord formatter
# (`PTC_TEST_RUN_LOG`), and summarises the file. Unlike core-tests.sh it does
# not stop at the first failure: a run that fails twice is two data points.
#
# Exit status is non-zero when any run failed, so the nightly job goes red
# while the flake rate is above zero and the artifact says which tests.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

export CI=1

usage() {
  echo "usage: flake-hunt.sh [RUNS] [--schedulers POSITIVE_INTEGER] [--out DIR]" >&2
  exit 64
}

runs=10
schedulers=4
out=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --schedulers)
      [ "$#" -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] || usage
      schedulers="$2"
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      out="$2"
      shift 2
      ;;
    *)
      [[ "$1" =~ ^[1-9][0-9]*$ ]] || usage
      runs="$1"
      shift
      ;;
  esac
done

if [ -z "$out" ]; then
  out="${TMPDIR:-/tmp}/ptc-flake-hunt/$(date -u +%Y%m%dT%H%M%SZ)"
fi

mkdir -p "$out"
export ERL_FLAGS="+S $schedulers:$schedulers"
export PTC_TEST_RUN_LOG="$out/runs.jsonl"

echo "flake-hunt: $runs runs, $schedulers schedulers, records in $out"

mix compile --warnings-as-errors

failed_runs=0
for ((i = 1; i <= runs; i++)); do
  started=$SECONDS
  if mix test --warnings-as-errors > "$out/run-$i.log" 2>&1; then
    verdict=pass
  else
    verdict=FAIL
    failed_runs=$((failed_runs + 1))
  fi
  echo "run $i/$runs: $verdict ($((SECONDS - started))s)"
done

elixir "$script_dir/flake_hunt_summary.exs" "$PTC_TEST_RUN_LOG" | tee "$out/summary.txt"

[ "$failed_runs" -eq 0 ]
