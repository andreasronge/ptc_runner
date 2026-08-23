#!/usr/bin/env bash
#
# Guide budget ratchet. Fails only when a guide grows past its committed
# baseline, so the existing pages never block a build while new prose does.
#
#   scripts/guide_budget.sh check    # CI / mix precommit
#   scripts/guide_budget.sh report   # per-guide table, no exit status
#   scripts/guide_budget.sh bless    # record the current measurements
#
# See docs/maintainers/guide-budget.md for when to move text instead of blessing.

set -euo pipefail

cd "$(dirname "$0")/.."

exec python3 scripts/guide_budget.py "${1:-check}" ".guide-budget-baseline.json"
