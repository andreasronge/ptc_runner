#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# `mix precommit` and the pre-push hook (through core-static.sh) both run
# this gate. A passing run stamps the tree it checked, and the next run on
# the same tree is skipped, so the documented stage-precommit-commit-push
# flow pays the gate once. The checked tree is the index tree: staged changes
# are part of it, and after the commit it equals `HEAD^{tree}`. An unstaged
# tracked change never stamps and never skips, and neither does a run whose
# tree changed while it ran (a rewrite by `mix format`, say);
# `PTC_QUALITY_FORCE=1` always runs.
stamp_file="_build/test/.core-quality-stamp"

current_tree() {
  git diff --quiet 2>/dev/null || return 1
  git write-tree 2>/dev/null
}

checked_tree="$(current_tree)" || checked_tree=""

if [ -z "${PTC_QUALITY_FORCE:-}" ] && [ -n "$checked_tree" ] && [ -f "$stamp_file" ] &&
  [ "$checked_tree" = "$(cat "$stamp_file")" ]; then
  echo "core quality: tree ${checked_tree:0:12} already passed; skipping (PTC_QUALITY_FORCE=1 to rerun)"
  exit 0
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

if [ -n "$checked_tree" ] && tree="$(current_tree)" && [ "$tree" = "$checked_tree" ]; then
  mkdir -p "$(dirname "$stamp_file")"
  printf '%s\n' "$tree" > "$stamp_file"
fi
