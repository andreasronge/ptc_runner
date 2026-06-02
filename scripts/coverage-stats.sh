#!/usr/bin/env bash
#
# coverage-stats.sh — turn `mix test --cover` output into a Markdown fragment.
#
# Combines the built-in coverage summaries of one or more projects (rows like
# `|  78.95% | Module |` ending with a `| 78.43% | Total |` line) into a single
# non-gating `## coverage` fragment for the release report.
#
# Each project is measured in isolation: `mix test --cover` only instruments the
# current project's own modules, never its dependencies (so the ptc_runner
# library and the ptc_runner_mcp server are reported as separate rows, not
# merged — a blended percentage across a library and its server would be
# misleading, and Mix cannot credit one project's tests to another anyway).
#
#   mix test --cover 2>&1 | tee cover.txt
#   (cd mcp_server && mix test --cover) 2>&1 | tee cover-mcp.txt
#   scripts/coverage-stats.sh out.md out.json \
#     "ptc_runner (library)" cover.txt  "ptc_runner_mcp (server)" cover-mcp.txt
#
# Always exits 0 — coverage is informational and must never fail its
# (continue-on-error) job.

set -uo pipefail

OUT="${1:-}"
OUT_JSON="${2:-}"
shift 2 2>/dev/null || true

# Parse one cover.txt summary table into "TOTAL MODULES LT50 ZERO".
parse_one() {
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
  ' "$1"
}

fmt_total() { # pct-or-"n/a"
  [ "$1" = "n/a" ] && { echo "n/a"; return; }
  awk -v t="$1" 'BEGIN { printf "%.1f%%", t }'
}

md_escape() { # escape `|` so a label can't break the table
  printf '%s' "${1//|/\\|}"
}

json_escape() { # minimal JSON string escaping (fallback when jq is absent)
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Build the per-project rows once, into parallel arrays.
LABELS=(); TOTALS=(); MODS=(); LT50S=(); ZEROS=()
while [ "$#" -ge 2 ]; do
  label="$1"; file="$2"; shift 2
  if [ -s "$file" ]; then
    read -r t m l z < <(parse_one "$file")
  else
    t="n/a"; m=0; l=0; z=0
  fi
  LABELS+=("$label"); TOTALS+=("$t"); MODS+=("$m"); LT50S+=("$l"); ZEROS+=("$z")
done

emit() {
  echo "## coverage"
  echo ""
  if [ "${#LABELS[@]}" -eq 0 ]; then
    echo "_No coverage inputs provided (see logs)._"
    return
  fi
  echo "Built-in \`mix test --cover\`, measured per project in isolation"
  echo "(\`ignore_modules\` applied where configured)."
  echo ""
  echo "| Project | Total line coverage | Modules measured | Modules < 50% | Modules at 0% |"
  echo "|---|--:|--:|--:|--:|"
  for i in "${!LABELS[@]}"; do
    printf '| %s | %s | %d | %d | %d |\n' \
      "$(md_escape "${LABELS[$i]}")" "$(fmt_total "${TOTALS[$i]}")" \
      "${MODS[$i]}" "${LT50S[$i]}" "${ZEROS[$i]}"
  done
}

# Numeric total (or jq-literal null), reused by both jq and fallback paths.
total_num() { [ "$1" = "n/a" ] && { echo null; return; }; awk -v t="$1" 'BEGIN { printf "%.1f", t }'; }

emit_json() {
  if command -v jq >/dev/null 2>&1; then
    # Build the array via jq so labels are always escaped correctly.
    local args=() filter="[" sep=""
    for i in "${!LABELS[@]}"; do
      args+=(--arg "l$i" "${LABELS[$i]}")
      filter+="${sep}{label:\$l$i,total_pct:$(total_num "${TOTALS[$i]}"),modules_measured:${MODS[$i]},modules_lt50:${LT50S[$i]},modules_zero:${ZEROS[$i]}}"
      sep=","
    done
    filter+="]"
    jq -cn "${args[@]}" "{projects: ${filter}}"
  else
    local sep="" out="{\"projects\":["
    for i in "${!LABELS[@]}"; do
      out+=$(printf '%s{"label":"%s","total_pct":%s,"modules_measured":%d,"modules_lt50":%d,"modules_zero":%d}' \
        "$sep" "$(json_escape "${LABELS[$i]}")" "$(total_num "${TOTALS[$i]}")" \
        "${MODS[$i]}" "${LT50S[$i]}" "${ZEROS[$i]}")
      sep=","
    done
    out+="]}"
    printf '%s\n' "$out"
  fi
}

RESULT=$(emit)
printf '%s\n' "$RESULT"
[ -n "$OUT" ]      && printf '%s\n' "$RESULT" > "$OUT"
[ -n "$OUT_JSON" ] && emit_json > "$OUT_JSON"
exit 0
