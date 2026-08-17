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

command -v python3 > /dev/null || {
  echo 'python3 is required to verify schema identity and page references' >&2
  exit 69
}

# The output directory is deleted, so a mistyped argument is destructive:
# `build_site.sh site` would erase the pages this script exists to publish.
#
# The rule is that this script only ever deletes a directory it created
# itself, proven by the marker file it leaves behind. Anything else that
# already exists is refused, so the guard fails closed on every input it does
# not positively recognise.
#
# Asking git whether the target holds tracked files is *not* sufficient, and
# was the first attempt here. Two false negatives sink it: this filesystem is
# case-insensitive, so `SITE` deletes tracked `site/` while `git ls-files`
# reports nothing for that spelling; and for any path outside the repository
# git exits 128 with empty output, which reads identically to "nothing tracked
# here" -- so a repository *ancestor* looked safest of all.
marker=".build-site-artifact"

case "$output_dir" in
  '' | '/') echo "refusing to build into '$output_dir'" >&2; exit 64 ;;
esac

output_parent="$(cd "$(dirname "$output_dir")" 2> /dev/null && pwd -P)" || {
  echo "parent directory of '$output_dir' does not exist" >&2
  exit 64
}
output_dir="$output_parent/$(basename "$output_dir")"

# `-L` is tested before `-e`, which follows the link and so reports false for a
# dangling one -- letting the guard fall through and delete a symlink this
# script never created.
if [ -L "$output_dir" ]; then
  echo "refusing to delete '$output_dir': it is a symlink" >&2
  exit 64
fi

if [ -e "$output_dir" ]; then
  [ -d "$output_dir" ] || {
    echo "'$output_dir' exists and is not a directory" >&2
    exit 64
  }

  [ -f "$output_dir/$marker" ] || {
    echo "refusing to delete '$output_dir': it was not created by this script" >&2
    echo "Remove it by hand if that is really the intended output directory." >&2
    exit 64
  }
fi

rm -rf -- "$output_dir"
mkdir -p "$output_dir/schemas"
: > "$output_dir/$marker"

cp -R "$project_root/site/." "$output_dir/"

# Without `nullglob` an unmatched pattern survives as a literal filename, and
# the loop below would report a missing schema as a JSON decode failure instead
# of reaching the count check.
shopt -s nullglob
schemas=("$project_root"/priv/schemas/ptc-*.schema.json)
shopt -u nullglob

[ "${#schemas[@]}" -gt 0 ] || {
  echo 'no ptc-*.schema.json found under priv/schemas' >&2
  exit 65
}

published=0
for schema in "${schemas[@]}"; do
  cp "$schema" "$output_dir/schemas/$(basename "$schema")"
  published=$((published + 1))
done

# Identity is checked against the assembled artifact, not against the sources
# copied into it. Validating only `priv/schemas/` would leave any schema that
# arrived some other way -- a stray `site/**/*.schema.json`, say -- published
# unchecked while this guard still claimed to cover the site.
python3 - "$output_dir" "$site_origin" <<'IDENTITY' || exit 65
import json
import pathlib
import sys

output_dir = pathlib.Path(sys.argv[1])
site_origin = sys.argv[2]
failed = False

for schema in sorted(output_dir.rglob("*.schema.json")):
    served_at = "%s/%s" % (site_origin, schema.relative_to(output_dir).as_posix())

    try:
        declared = json.loads(schema.read_text(encoding="utf-8")).get("$id", "")
    except ValueError as error:
        sys.stderr.write("%s: not valid JSON (%s)\n" % (schema.name, error))
        failed = True
        continue

    if declared != served_at:
        sys.stderr.write(
            "%s declares $id '%s' but publishes to '%s'\n"
            % (schema.name, declared or "<none>", served_at)
        )
        failed = True

if failed:
    sys.stderr.write("Reconcile the schema generator with the site origin before deploying.\n")
    sys.exit(65)
IDENTITY

# Every root-relative reference the pages write by hand -- schema URLs, the
# stylesheet, images. A dangling one is invisible until a reader hits it, so it
# fails the build instead. A reference ending in `/` is served by the index
# document inside that directory.
#
# Extraction is a real HTML parse rather than a regex. A pattern matching only
# `href="..."` silently ignores `href = "..."`, single quotes, uppercase tags,
# and attributes wrapped across lines -- all valid HTML that a later edit could
# introduce, and every one of them a reference this guard would then wave
# through while still appearing to check it.
#
# The extractor's output is captured before the loop rather than piped into it.
# Through a process substitution its exit status is invisible, so an unreadable
# or non-UTF-8 page would print an error, yield no references, and leave the
# loop reporting zero dangling links -- publishing unvalidated.
references="$(python3 - "$project_root/site" <<'EXTRACT'
import pathlib
import posixpath
import sys
from html.parser import HTMLParser


class References(HTMLParser):
    """Collects every href and src value in a document."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = set()

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src") and value:
                self.found.add(value)


root = pathlib.Path(sys.argv[1])
references = set()

for page in sorted(root.rglob("*.html")):
    parser = References()
    parser.feed(page.read_text(encoding="utf-8"))
    parser.close()
    references |= parser.found

for reference in sorted(references):
    # Browsers strip leading and trailing ASCII whitespace from a URL attribute
    # before resolving it, so `href=" /missing"` is a root-relative request that
    # an unstripped comparison would classify as external and never check.
    reference = reference.strip("\t\n\f\r ")

    if not reference.startswith("/"):
        continue

    # Site-root-relative. Drop the fragment and query the server ignores when
    # resolving it to a file, then collapse dot segments the way a browser
    # does before it asks for the path: `/../README.md` is requested as
    # `/README.md`, so checking the literal string would test a file outside
    # the artifact and pass on something the server will 404.
    path = reference.split("#", 1)[0].split("?", 1)[0]
    directory = path.endswith("/")
    path = posixpath.normpath(path)

    if directory and not path.endswith("/"):
        path += "/"

    print(path[1:])
EXTRACT
)" || {
  echo 'failed to extract references from the site pages' >&2
  exit 65
}

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
done <<< "$references"

[ "$missing" -eq 0 ] || exit 65

echo "Assembled $output_dir ($published schemas)"
