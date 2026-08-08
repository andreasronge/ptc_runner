#!/usr/bin/env bash
#
# Duplication ratchet. Fails only on clones absent from the committed baseline,
# so the known backlog never blocks a build while new duplication does.
#
#   scripts/duplication_gate.sh check   # CI / mix precommit
#   scripts/duplication_gate.sh bless   # record the current set as accepted
#
# See docs/guides/duplication-gate.md for when to bless versus suppress.

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
EX_DNA_ARGS=(lib/ test/ --format json --max-clones 1000000)

# The opt-in checkout carries ExDNA's unreleased complete-result cache. Keep
# ordinary Hex builds compatible with 1.5.4 until that option is released.
if [ -n "${PTC_EX_DNA_PATH:-}" ]; then
  EX_DNA_ARGS+=(--cache)
fi

mix ex_dna "${EX_DNA_ARGS[@]}" >"$RAW"

# Anything Mix still emits (stale-dep recompiles, deprecation notices) precedes
# the report on stdout, so keep only from the opening brace onwards.
sed -n '/^{/,$p' "$RAW" >"$REPORT"

if [ ! -s "$REPORT" ]; then
  echo "duplication gate: ex_dna produced no JSON report. Raw output:" >&2
  tail -20 "$RAW" >&2
  exit 1
fi

exec python3 scripts/duplication_gate.py "$MODE" "$REPORT" "$BASELINE"
