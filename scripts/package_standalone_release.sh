#!/usr/bin/env bash
#
# Builds, closes, verifies, and compresses the standalone macOS artifact.
#
#   scripts/package_standalone_release.sh [OUTPUT_DIRECTORY]
#
# `mix release` copies the Erlang runtime but not the libraries that runtime
# links against, so the assembled tree records absolute paths into whatever
# prefix built it -- a Homebrew OpenSSL, typically. That tree runs on the build
# host and nowhere else. This script vendors every non-system dependency into
# the release, rewrites the references to loader-relative paths, re-signs what
# it rewrote, and fails if any absolute foreign reference survives.
#
# The result is ad-hoc signed. It is not Developer ID signed and not notarized.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$project_root/_build/artifacts}"

package_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-package.XXXXXX")"
cleanup() {
  rm -rf "$package_tmp_dir"
}
trap cleanup EXIT

release_root="$package_tmp_dir/ptc"
vendor_dir="$release_root/lib/vendor"
license_dir="$vendor_dir/licenses"

case "$(uname -s)" in
  Darwin) ;;
  *)
    echo "this packaging path is macOS-only; Linux ships as a container image" >&2
    exit 64
    ;;
esac

for tool in otool install_name_tool codesign shasum; do
  command -v "$tool" > /dev/null || {
    echo "$tool is required to package the release" >&2
    exit 69
  }
done

cd "$project_root"
MIX_ENV=prod mix release ptc_runner --overwrite --path "$release_root"

version="$("$release_root/bin/ptc" --version)"
architecture="$(uname -m)"

# The origin map is packaging bookkeeping, not part of the artifact.
vendor_manifest="$package_tmp_dir/vendor-origins"
mkdir -p "$vendor_dir" "$vendor_manifest"

# Mach-O files are found by inspection, not by a list of names: a runtime bump
# can add a NIF, and a list would keep passing while the new library stayed
# foreign.
mach_o_files() {
  find "$release_root" -type f ! -name '*.beam' ! -name '*.app' -print0 |
    while IFS= read -r -d '' candidate; do
      case "$(file -b "$candidate" 2> /dev/null)" in
        *Mach-O*) printf '%s\0' "$candidate" ;;
      esac
    done
}

# macOS guarantees these; everything else has to travel with the artifact.
# `@`-prefixed references are already loader-relative.
is_system_dependency() {
  case "$1" in
    /usr/lib/* | /System/Library/* | @*) return 0 ;;
    *) return 1 ;;
  esac
}

dependencies_of() {
  otool -L "$1" | tail -n +2 | awk '{print $1}'
}

relative_load_path() {
  python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"
}

sign() {
  codesign --force --sign - "$1" 2> /dev/null
}

# Vendoring is transitive: a vendored library carries its own foreign
# dependencies, and each one has to be resolved before the artifact is closed.
vendor_dependency() {
  local source="$1"
  local name
  name="$(basename "$source")"
  local vendored="$vendor_dir/$name"

  # Vendored files are keyed by basename, so two libraries that share one would
  # collapse into whichever arrived first while both dependents were rewritten
  # to it -- and the closure check would still pass. Record the origin of each
  # name and refuse the second one.
  local origin_record="$vendor_manifest/$name"
  if [ -f "$origin_record" ] && [ "$(cat "$origin_record")" != "$source" ]; then
    echo "two different libraries are named $name:" >&2
    echo "  already vendored from $(cat "$origin_record")" >&2
    echo "  now required from $source" >&2
    exit 1
  fi
  printf '%s' "$source" > "$origin_record"

  if [ ! -f "$vendored" ]; then
    cp "$source" "$vendored"
    chmod u+w "$vendored"
    install_name_tool -id "@loader_path/$name" "$vendored"

    local nested
    for nested in $(dependencies_of "$vendored"); do
      is_system_dependency "$nested" && continue
      [ "$(basename "$nested")" = "$name" ] && continue

      vendor_dependency "$nested"
      install_name_tool -change "$nested" "@loader_path/$(basename "$nested")" "$vendored"
    done

    sign "$vendored"
    capture_license "$source" "$name"
    echo "vendored $name"
  fi
}

# The license lives with the library's own installation, which is only known
# here, while the original absolute path is still in hand.
capture_license() {
  local source="$1"
  local name="$2"
  local prefix
  prefix="$(dirname "$(dirname "$source")")"

  # `-L`: a package manager's stable prefix is usually a symlink into a
  # versioned directory, and the license sits in the target.
  local license
  license="$(find -L "$prefix" -maxdepth 2 \( -name 'LICENSE*' -o -name 'COPYING*' \) -print -quit 2> /dev/null || true)"

  if [ -n "$license" ]; then
    mkdir -p "$license_dir"
    cp "$license" "$license_dir/$name.license"
  else
    echo "note: no license file found beside $source" >&2
  fi
}

close_dependencies() {
  local file="$1"
  local rewritten=0
  local dependency

  for dependency in $(dependencies_of "$file"); do
    is_system_dependency "$dependency" && continue

    vendor_dependency "$dependency"

    local name relative
    name="$(basename "$dependency")"
    relative="$(relative_load_path "$vendor_dir/$name" "$(dirname "$file")")"

    chmod u+w "$file"
    install_name_tool -change "$dependency" "@loader_path/$relative" "$file"
    rewritten=1
  done

  [ "$rewritten" -eq 1 ] && sign "$file"
  return 0
}

while IFS= read -r -d '' mach_o; do
  close_dependencies "$mach_o"
done < <(mach_o_files)

# The closure is only proven by re-reading the tree: a rewrite that silently
# failed, or a library reached only through another vendored library, shows up
# here and nowhere else. The checker resolves `@rpath` through each file's
# `LC_RPATH` entries and `@loader_path` against its directory, because a
# loader-relative reference is not the same thing as a contained one.
if ! mach_o_files | python3 scripts/macho_closure.py "$release_root"; then
  echo 'the packaged release still references libraries outside the artifact' >&2
  exit 1
fi

# The gate runs against the packaged tree, not a rebuild of it.
PTC_RELEASE_ROOT="$release_root" scripts/verify_standalone_release.sh

mkdir -p "$output_dir"
artifact="$output_dir/ptc-$version-macos-$architecture.tar.gz"
tar czf "$artifact" -C "$package_tmp_dir" ptc
(cd "$output_dir" && shasum -a 256 "$(basename "$artifact")" > "$(basename "$artifact").sha256")

echo "packaged $artifact"
