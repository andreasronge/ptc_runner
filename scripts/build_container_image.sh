#!/usr/bin/env bash
#
# Builds the local Linux container scaffolding and proves the release inside it.
#
#   scripts/build_container_image.sh [IMAGE_TAG]
#
# This is not a publication path. The container contract in
# `docs/plans/lisp-kernel/stable-cli-contract.md` also requires the launcher
# companion and per-architecture evidence; until those exist the image is a way
# to exercise the assembled release on Linux, and nothing here tags, pushes, or
# documents it as an install route.
#
# The build runs the standalone verification inside the image, so a failure
# here is a failure of the release, not of the packaging.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image_tag="${1:-ptc:dev}"
[ "$#" -gt 0 ] && shift

command -v docker > /dev/null || {
  echo 'docker is required to build the container scaffolding' >&2
  exit 69
}

docker buildx version > /dev/null 2>&1 || {
  echo 'docker buildx is required: the Dockerfile uses a multi-stage verify target' >&2
  exit 69
}

cd "$project_root"

# Extra arguments are forwarded to buildx, but not these two: choosing another
# target or another Dockerfile skips the in-image gate while the probes below
# still pass, and the script would report a verification that never ran.
for argument in "$@"; do
  case "$argument" in
    --target | --target=* | -f | --file | --file=*)
      echo "$argument is not accepted: it would bypass the in-image verification" >&2
      exit 64
      ;;
  esac
done

# `--load` keeps the result in the local daemon, which only works for one
# platform at a time. Multi-architecture manifests belong to the publication
# increment, not to local scaffolding.
docker buildx build \
  --tag "$image_tag" \
  --load \
  "$@" \
  --target released \
  .

# The in-image gate installs `expect` and `diffutils` to run, and an installed
# package can drag in a library the shipped image lacks -- verification that
# supplies its own dependencies can pass for an image that would fail in a
# user's hands. These probes drive the finished image with nothing added, so a
# missing runtime library shows up as the broken output it would really be.
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-image-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

cat > "$probe_dir/main.clj" <<'EOF'
(ns smoke.main)

(defn run [input]
  (return input))
EOF

cat > "$probe_dir/ptc.json" <<'EOF'
{
  "version": 1,
  "workflow": {
    "components": [{"id": "smoke.main", "path": "main.clj"}],
    "entry": "smoke.main/run"
  },
  "input": {"value": {"city": "Malmö"}},
  "providers": {"workflow": [], "mission": []}
}
EOF

docker run --rm --volume "$probe_dir:/work" "$image_tag" --version > "$probe_dir/version.stdout"
grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' "$probe_dir/version.stdout"

# Standard output carries a machine contract: a runtime that writes a startup
# warning there corrupts it, and only an untouched image can prove it does not.
docker run --rm --volume "$probe_dir:/work" "$image_tag" run /work/ptc.json \
  > "$probe_dir/run.stdout" 2> /dev/null
printf '%s\n' '{"city":"Malmö"}' > "$probe_dir/run.expected"
cmp "$probe_dir/run.expected" "$probe_dir/run.stdout"

test "$(docker run --rm --entrypoint id "$image_tag" --user)" != "0"

echo
echo "built $image_tag; the standalone verification passed inside it,"
echo "and the finished image answers correctly with nothing added to it"
echo "try: docker run --rm -it -v \"\$PWD:/work\" $image_tag repl"
