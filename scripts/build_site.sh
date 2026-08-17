#!/usr/bin/env bash
#
# Assembles the static ptc-runner.dev site into an output directory.
#
#   scripts/build_site.sh [OUTPUT_DIR]     # default: _site
#
# The site is `site/` plus the generated JSON Schemas copied verbatim out of
# `priv/schemas/`. Nothing regenerates a schema here: `mix ptc.gen_docs` owns
# them and `mix precommit` fails on a stale one, so this path only publishes
# what the repository already proved current. Copying at build time is what
# keeps the hosted document and the runtime validator the same bytes; a second
# copy checked in under `site/` would drift silently.
#
# Every published schema declares its own URL in `$id`, and the runtime hard
# codes those URLs. A renamed or newly added schema would therefore publish to
# a path nobody resolves, so the assembly below verifies that each `$id` still
# matches the address it is being served from, and fails the build when it does
# not.
#
# Serve the result locally with:
#
#   python3 -m http.server -d _site 8000
#
# Absolute links such as `/schemas/...` resolve correctly there, which is why
# the pages use them.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$project_root/_site}"
site_origin="https://ptc-runner.dev"

command -v jq > /dev/null || {
  echo 'jq is required to verify schema identity' >&2
  exit 69
}

rm -rf "$output_dir"
mkdir -p "$output_dir/schemas"

cp -R "$project_root/site/." "$output_dir/"

# Without `nullglob` an unmatched pattern survives as a literal filename, and
# the loop below would report a missing schema as a jq parse failure instead of
# reaching the count check.
shopt -s nullglob
schemas=("$project_root"/priv/schemas/ptc-*.schema.json)
shopt -u nullglob

[ "${#schemas[@]}" -gt 0 ] || {
  echo 'no ptc-*.schema.json found under priv/schemas' >&2
  exit 65
}

published=0
for schema in "${schemas[@]}"; do
  name="$(basename "$schema")"
  expected="$site_origin/schemas/$name"
  declared="$(jq -r '."$id" // empty' "$schema")"

  if [ "$declared" != "$expected" ]; then
    echo "$name declares \$id '${declared:-<none>}' but publishes to '$expected'" >&2
    echo 'Reconcile the schema generator with the site origin before deploying.' >&2
    exit 65
  fi

  cp "$schema" "$output_dir/schemas/$name"
  published=$((published + 1))
done

# Every root-relative reference the pages write by hand -- schema URLs, the
# stylesheet, images. A dangling one is invisible until a reader hits it, so it
# fails the build instead. A reference ending in `/` is served by the index
# document inside that directory.
missing=0
while read -r referenced; do
  case "$referenced" in
    */ | '') target="$output_dir/${referenced}index.html" ;;
    *) target="$output_dir/$referenced" ;;
  esac

  [ -f "$target" ] || {
    echo "site references /$referenced, which is not published" >&2
    missing=$((missing + 1))
  }
done < <(grep -rhoE '(href|src)="/[^"#]*"' "$project_root/site" |
  sed -E 's|^(href\|src)="/||; s|"$||' | sort -u)

[ "$missing" -eq 0 ] || exit 65

echo "Assembled $output_dir ($published schemas)"
