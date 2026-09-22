#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# `mix precommit` and the pre-push hook (through core-static.sh) both run
# this gate. A passing run stamps the tree it checked, and the next run on
# an identical clean tree is skipped, so the documented precommit-then-push
# flow pays the gate once. A dirty tree never stamps and never skips;
# `PTC_QUALITY_FORCE=1` always runs.
stamp_file="_build/test/.core-quality-stamp"

current_tree() {
  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    return 1
  fi
  git rev-parse HEAD^{tree} 2>/dev/null
}

if [ -z "${PTC_QUALITY_FORCE:-}" ] && [ -f "$stamp_file" ]; then
  if tree="$(current_tree)" && [ "$tree" = "$(cat "$stamp_file")" ]; then
    echo "core quality: tree ${tree:0:12} already passed; skipping (PTC_QUALITY_FORCE=1 to rerun)"
    exit 0
  fi
fi
rm -f "$stamp_file"

# One Mix boot for every in-VM check. Each separate `mix` invocation costs
# about three seconds of VM and application start before it does any work;
# chaining them with `mix do` pays that once. The two shell gates below need
# their own processes.
mix do compile --warnings-as-errors + \
  xref graph --format cycles --label compile-connected --fail-above 0 + \
  format --check-formatted + \
  credo --strict + \
  ptc.validate_spec + \
  ptc.gen_docs --check + \
  ptc.conformance_report --check-inventory
scripts/duplication_gate.sh check
scripts/guide_budget.sh check

if tree="$(current_tree)"; then
  mkdir -p "$(dirname "$stamp_file")"
  printf '%s\n' "$tree" > "$stamp_file"
fi
