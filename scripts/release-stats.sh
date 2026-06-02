#!/usr/bin/env bash
#
# release-stats.sh — emit a non-gating release statistics fragment (Markdown).
#
# Reports code/test size, growth since the previous release tag, and a small
# health radar. Used by the `stats` job in .github/workflows/release.yml, but
# safe to run locally:
#
#   scripts/release-stats.sh            # print fragment to stdout
#   scripts/release-stats.sh out.md     # also write to out.md
#
# Requires full git history + tags for the growth section (the CI job uses
# fetch-depth: 0). Degrades gracefully to "n/a" when no previous tag is found.

set -uo pipefail

# ---- helpers ---------------------------------------------------------------

# LOC of tracked files under a pathspec matching an extension (working tree).
loc() { # <dir> <ext>
  git ls-files -- "$1" | grep -E "\.${2}\$" | tr '\n' '\0' \
    | xargs -0 cat 2>/dev/null | wc -l | tr -d ' '
}

# Count tracked files under a pathspec matching an extension (working tree).
nfiles() { # <dir> <ext>
  git ls-files -- "$1" | grep -cE "\.${2}\$"
}

# Count lines matching a regex within a pathspec at a given revision.
# Works without checkout via `git grep <tree-ish>`.
grep_count() { # <rev> <regex> <pathspec...>
  local rev="$1" re="$2"; shift 2
  git grep -hE "$re" "$rev" -- "$@" 2>/dev/null | wc -l | tr -d ' '
}

# Thousands separator, portable across BSD/GNU (awk, no locale assumptions).
commafy() {
  awk '{ n=$0; s=""; while (length(n) > 3) { s="," substr(n, length(n)-2) s; n=substr(n, 1, length(n)-3) } print n s }' <<<"$1"
}

# Net line delta (insertions - deletions) for a pathspec/extension between two
# revisions. Exact change in total line count for those files.
net_delta() { # <base> <head> <dir> <ext>
  git diff --numstat "$1" "$2" -- "$3" 2>/dev/null \
    | awk -v ext="\\.$4\$" '$3 ~ ext { add += $1; del += $2 } END { print (add - del) + 0 }'
}

signed() { local n="$1"; [ "$n" -ge 0 ] 2>/dev/null && echo "+$(commafy "$n")" || echo "-$(commafy "${n#-}")"; }

# ---- baseline (previous release tag) --------------------------------------

# A tag pointing at HEAD means this run IS a release; baseline is the tag before
# it. Otherwise (e.g. workflow_dispatch on main) baseline is the latest tag.
HEAD_TAG=$(git tag --points-at HEAD --list 'v*' 2>/dev/null | sort -V | tail -1)
if [ -n "$HEAD_TAG" ]; then
  BASE=$(git describe --tags --abbrev=0 --match 'v*' "${HEAD_TAG}^" 2>/dev/null || true)
  HEAD_LABEL="$HEAD_TAG"
else
  BASE=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  HEAD_LABEL="HEAD"
fi

# ---- T1: size --------------------------------------------------------------

LIB_LOC=$(loc lib ex);            LIB_FILES=$(nfiles lib ex)
TEST_LOC=$(loc test exs);         TEST_FILES=$(nfiles test exs)
MODULES=$(grep_count HEAD '^[[:space:]]*defmodule ' lib)
TEST_CASES=$(grep_count HEAD '^[[:space:]]*(test|property) ' test)
DESCRIBES=$(grep_count HEAD '^[[:space:]]*describe ' test)
MCP_LIB_LOC=$(loc mcp_server/lib ex)
RATIO=$(awk -v t="$TEST_LOC" -v l="$LIB_LOC" 'BEGIN { printf (l>0 ? "%.2f" : "n/a"), t/l }')

# ---- T3: health ------------------------------------------------------------

PUB_DEFS=$(grep_count HEAD '^[[:space:]]*def ' lib)
SPECS=$(grep_count HEAD '^[[:space:]]*@spec ' lib)
TODOS=$(grep_count HEAD 'TODO|FIXME' lib)
DEPS=$(awk '/defp deps do/{f=1} f&&/^[[:space:]]*\{:/{c++} /^[[:space:]]*end/{if(f){print c+0; exit}}' mix.exs)
SPEC_COV=$(awk -v s="$SPECS" -v d="$PUB_DEFS" 'BEGIN { printf (d>0 ? "%.0f%%" : "n/a"), 100*s/d }')
LARGEST=$(git ls-files -- lib | grep -E '\.ex$' | tr '\n' '\0' \
  | xargs -0 wc -l 2>/dev/null | awk '$2 != "total"' | sort -rn | head -1 \
  | awk '{ n=$1; $1=""; sub(/^ /,""); printf "%s (%s)", $0, n }')
SPEC_COV_NUM=$(awk -v s="$SPECS" -v d="$PUB_DEFS" 'BEGIN { printf (d>0 ? "%.0f" : "0"), 100*s/d }')

# ---- T2: growth (computed up front so both Markdown and JSON can use it) ----

if [ -n "$BASE" ]; then
  DLIB=$(net_delta "$BASE" HEAD lib ex)
  DTEST=$(net_delta "$BASE" HEAD test exs)
  PREV_CASES=$(grep_count "$BASE" '^[[:space:]]*(test|property) ' test)
  PREV_MODULES=$(grep_count "$BASE" '^[[:space:]]*defmodule ' lib)
  DCASES=$((TEST_CASES - PREV_CASES))
  DMODULES=$((MODULES - PREV_MODULES))
  COMMITS=$(git rev-list --count "${BASE}..HEAD" 2>/dev/null || echo 0)
  SHORTSTAT=$(git diff --shortstat "$BASE" HEAD 2>/dev/null | sed 's/^ *//')
fi

# ---- emit ------------------------------------------------------------------

emit() {
  echo "## stats"
  echo ""
  echo "### Size ($HEAD_LABEL)"
  echo ""
  echo "| Surface | Files | LOC | Modules |"
  echo "|---|--:|--:|--:|"
  echo "| lib (root) | $(commafy "$LIB_FILES") | $(commafy "$LIB_LOC") | $(commafy "$MODULES") |"
  echo "| test (root) | $(commafy "$TEST_FILES") | $(commafy "$TEST_LOC") | — |"
  echo "| mcp_server lib | — | $(commafy "$MCP_LIB_LOC") | — |"
  echo ""
  echo "- **Test : code ratio:** ${RATIO} : 1 ($(commafy "$TEST_LOC") test / $(commafy "$LIB_LOC") lib LOC)"
  echo "- **Test cases:** $(commafy "$TEST_CASES") in $(commafy "$DESCRIBES") describe blocks"
  echo ""

  echo "### Growth"
  echo ""
  if [ -n "$BASE" ]; then
    echo "Since \`$BASE\`:"
    echo ""
    echo "| Metric | Δ |"
    echo "|---|--:|"
    echo "| lib LOC | $(signed "$DLIB") |"
    echo "| test LOC | $(signed "$DTEST") |"
    echo "| test cases | $(signed "$DCASES") |"
    echo "| modules | $(signed "$DMODULES") |"
    echo "| commits | $(commafy "$COMMITS") |"
    echo ""
    echo "- Overall diff: ${SHORTSTAT:-no changes}"
  else
    echo "_No previous \`v*\` tag found — growth section skipped._"
  fi
  echo ""

  echo "### Health"
  echo ""
  echo "| Metric | Value |"
  echo "|---|--:|"
  echo "| @spec coverage (specs / public defs) | ${SPEC_COV} ($(commafy "$SPECS") / $(commafy "$PUB_DEFS")) |"
  echo "| TODO·FIXME in lib | $(commafy "$TODOS") |"
  echo "| Largest lib file | ${LARGEST:-n/a} |"
  echo "| Dependencies (mix.exs) | ${DEPS:-?} |"
}

# Machine-readable sibling for cross-release comparison (no thousands commas).
emit_json() {
  local growth='null'
  if [ -n "$BASE" ]; then
    growth=$(printf '{"baseline":"%s","lib_loc":%d,"test_loc":%d,"test_cases":%d,"modules":%d,"commits":%d}' \
      "$BASE" "$DLIB" "$DTEST" "$DCASES" "$DMODULES" "${COMMITS:-0}")
  fi
  printf '{'
  printf '"ref":"%s",' "$HEAD_LABEL"
  printf '"lib_loc":%d,"lib_files":%d,"test_loc":%d,"test_files":%d,' "$LIB_LOC" "$LIB_FILES" "$TEST_LOC" "$TEST_FILES"
  printf '"mcp_lib_loc":%d,"modules":%d,"test_cases":%d,"describe_blocks":%d,' "$MCP_LIB_LOC" "$MODULES" "$TEST_CASES" "$DESCRIBES"
  printf '"test_code_ratio":%s,' "$RATIO"
  printf '"public_defs":%d,"specs":%d,"spec_coverage_pct":%d,' "$PUB_DEFS" "$SPECS" "$SPEC_COV_NUM"
  printf '"todos":%d,"deps":%d,' "$TODOS" "${DEPS:-0}"
  printf '"growth":%s' "$growth"
  printf '}\n'
}

MD=$(emit)
printf '%s\n' "$MD"
[ "${1:-}" != "" ] && printf '%s\n' "$MD" > "$1"   # Markdown fragment
[ "${2:-}" != "" ] && emit_json > "$2"             # JSON sibling
