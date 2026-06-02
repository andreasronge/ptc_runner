#!/usr/bin/env bash
#
# coverage-stats.sh — turn `mix test --cover` output into a Markdown fragment.
#
# Parses the built-in coverage summary table (rows like `|  78.95% | Module |`
# ending with a `| 78.43% | Total |` line) into a non-gating `## coverage`
# fragment for the release report.
#
#   mix test --cover 2>&1 | tee cover.txt
#   scripts/coverage-stats.sh cover.txt [out.md]
#
# Reads stdin when no input file is given. Always exits 0 — coverage is
# informational and must never fail its (continue-on-error) job.

set -uo pipefail

IN="${1:-/dev/stdin}"
OUT="${2:-}"

# Parse the summary table. Fields are pipe-delimited: "| <pct>% | <Module> |".
read -r TOTAL MODULES LT50 ZERO < <(
  awk -F'|' '
    /\|[[:space:]]*[0-9.]+%[[:space:]]*\|/ {
      pct = $2; gsub(/[ %]/, "", pct)
      mod = $3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", mod)
      if (mod == "Total") { total = pct; next }
      n++
      if (pct + 0 == 0)  zero++
      if (pct + 0 < 50)  lt50++
    }
    END { printf "%s %d %d %d\n", (total == "" ? "n/a" : total), n + 0, lt50 + 0, zero + 0 }
  ' "$IN"
)

fmt_total() {
  [ "$TOTAL" = "n/a" ] && { echo "n/a"; return; }
  awk -v t="$TOTAL" 'BEGIN { printf "%.1f%%", t }'
}

emit() {
  echo "## coverage"
  echo ""
  if [ "$TOTAL" = "n/a" ] && [ "$MODULES" -eq 0 ]; then
    echo "_No coverage summary found in the \`mix test --cover\` output (see logs)._"
    return
  fi
  echo "Built-in \`mix test --cover\` (root app; \`ignore_modules\` applied)."
  echo ""
  echo "| Metric | Value |"
  echo "|---|--:|"
  echo "| Total line coverage | $(fmt_total) |"
  echo "| Modules measured | ${MODULES} |"
  echo "| Modules < 50% | ${LT50} |"
  echo "| Modules at 0% | ${ZERO} |"
}

RESULT=$(emit)
printf '%s\n' "$RESULT"
[ -n "$OUT" ] && printf '%s\n' "$RESULT" > "$OUT"
exit 0
