#!/usr/bin/env bash
#
# Documentation history ratchet. Fails only when a Markdown page gains an issue
# or pull-request reference, so the existing backlog never blocks a build while
# new history in the docs does.
#
#   scripts/doc_history_gate.sh check   # CI / mix precommit
#   scripts/doc_history_gate.sh bless   # record the current counts
#
# Documentation describes current behavior; the reasons and measurements for a
# change live in its pull request and in git (docs/maintainers/documentation.md).
# Generated pages, plans, and research reports are out of scope. Remove a page's
# references when you next edit it, then run `bless` to tighten its baseline.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

baseline="${PTC_DOC_HISTORY_BASELINE:-.doc-history-baseline}"

# `#1234` not preceded by a word character, `&` (HTML entity), `/` or `#`, and
# GitHub issue or pull-request URLs.
pattern='(^|[^[:alnum:]_&/#])#[0-9]{3,5}([^[:alnum:]_]|$)|/(issues|pull)/[0-9]+'

scope=(
  'README.md' 'docs/*.md' 'ptc_*/README.md' 'ptc_*/docs/*.md'
  ':!docs/plans/*' ':!docs/research/*' ':!docs/conformance/*'
  ':!docs/function-reference.md' ':!docs/java-interop.md'
  ':!docs/kernel-limits-reference.md' ':!docs/prelude-reference.md'
)

# One "path count" row per page that carries a reference.
current="$({ git grep -cE "$pattern" -- "${scope[@]}" || true; } |
  sed 's/:\([0-9]*\)$/ \1/' | LC_ALL=C sort)"

case "${1:-check}" in
  bless)
    printf '%s\n' "$current" | sed '/^$/d' > "$baseline"
    echo "doc history: recorded $(wc -l < "$baseline" | tr -d ' ') pages in $baseline"
    ;;
  check)
    status=0
    while read -r file count; do
      [ -n "$file" ] || continue
      allowed="$(awk -v f="$file" '$1 == f { print $2 }' "$baseline" 2>/dev/null || true)"
      allowed="${allowed:-0}"
      if [ "$count" -gt "$allowed" ]; then
        echo "doc history: $file has $count lines with issue or pull-request references, baseline $allowed"
        git grep -nE "$pattern" -- "$file" | sed 's/^/  /'
        status=1
      elif [ "$count" -lt "$allowed" ]; then
        echo "doc history: $file dropped to $count references (baseline $allowed); run scripts/doc_history_gate.sh bless to tighten"
      fi
    done <<< "$current"
    if [ "$status" -ne 0 ]; then
      echo
      echo "Docs describe current behavior. Put the issue number, the reason for the change,"
      echo "and any before/after measurements in the pull request or commit message instead."
      echo "See docs/maintainers/documentation.md."
      exit 1
    fi
    echo "doc history: no new issue or pull-request references"
    ;;
  *)
    echo "usage: scripts/doc_history_gate.sh [check|bless]" >&2
    exit 2
    ;;
esac
