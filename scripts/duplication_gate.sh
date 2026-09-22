#!/usr/bin/env bash
#
# Duplication ratchet. Fails only on clones absent from the committed baseline,
# so the known backlog never blocks a build while new duplication does.
#
#   scripts/duplication_gate.sh check   # CI / mix precommit
#   scripts/duplication_gate.sh bless   # record the current set as accepted
#
# See docs/maintainers/duplication-gate.md for when to bless versus suppress.

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-check}"
BASELINE=".duplication-baseline.json"
# Explicit XXXXXX template: `mktemp -t NAME` without it fails under GNU
# coreutils ("too few X's in template"), which is what CI runs.
REPORT="$(mktemp "${TMPDIR:-/tmp}/ptc-clones.XXXXXX")"
RAW="$(mktemp "${TMPDIR:-/tmp}/ptc-clones-raw.XXXXXX")"
trap 'rm -f "$REPORT" "$RAW"' EXIT

# Compile first, on its own, so build output cannot land in the JSON stream.
mix compile >&2

# Give ExDNA a deliberately unreachable budget so clones still produce JSON and
# an actual detector failure cannot be mistaken for a successful partial report.
#
# `lib/` and `test/` are scanned as two separate detector runs. One run over
# both trees holds every fragment of both in a single BEAM heap (measured
# 4.7 GB RSS, 64 s, nearly all of it garbage collection); two runs peak at
# about 3.5 GB each and finish in a quarter of the time. The baseline has
# never held a clone spanning the two trees, and the ratchet merges both
# reports before comparing, so the accepted set is unchanged.
EX_DNA_ARGS=(--format json --max-clones 1000000)

# The opt-in checkout carries ExDNA's unreleased complete-result cache. Keep
# ordinary Hex builds compatible with 1.5.4 until that option is released.
if [ -n "${PTC_EX_DNA_PATH:-}" ]; then
  EX_DNA_ARGS+=(--cache)
fi

RAW_TEST="$(mktemp "${TMPDIR:-/tmp}/ptc-clones-raw-test.XXXXXX")"
trap 'rm -f "$REPORT" "$RAW" "$RAW_TEST"' EXIT

# Sequential when memory is tight (`PTC_DUPLICATION_SERIAL=1`), concurrent
# otherwise: the two runs only read the compiled build.
if [ -n "${PTC_DUPLICATION_SERIAL:-}" ]; then
  mix ex_dna lib/ "${EX_DNA_ARGS[@]}" >"$RAW"
  mix ex_dna test/ "${EX_DNA_ARGS[@]}" >"$RAW_TEST"
else
  mix ex_dna lib/ "${EX_DNA_ARGS[@]}" >"$RAW" &
  lib_pid=$!
  mix ex_dna test/ "${EX_DNA_ARGS[@]}" >"$RAW_TEST" &
  test_pid=$!
  wait "$lib_pid"
  wait "$test_pid"
fi

# Anything Mix still emits (stale-dep recompiles, deprecation notices) precedes
# the report on stdout, so keep only from the opening brace onwards, then
# merge the two clone lists into the single report the ratchet reads.
python3 - "$RAW" "$RAW_TEST" >"$REPORT" <<'PY'
import json, sys

def report(path):
    with open(path) as handle:
        text = handle.read()
    start = text.find("\n{")
    body = text[start + 1:] if start >= 0 else text
    if not body.lstrip().startswith("{"):
        sys.exit(f"duplication gate: ex_dna produced no JSON report in {path}:\n{text[-2000:]}")
    return json.loads(body)

clones = []
for path in sys.argv[1:]:
    clones.extend(report(path)["clones"])
json.dump({"clones": clones}, sys.stdout)
PY

if [ ! -s "$REPORT" ]; then
  echo "duplication gate: ex_dna produced no JSON report. Raw output:" >&2
  tail -20 "$RAW" >&2
  tail -20 "$RAW_TEST" >&2
  exit 1
fi

exec python3 scripts/duplication_gate.py "$MODE" "$REPORT" "$BASELINE"
