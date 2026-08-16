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

# `--load` keeps the result in the local daemon, which only works for one
# platform at a time. Multi-architecture manifests belong to the publication
# increment, not to local scaffolding.
docker buildx build \
  --tag "$image_tag" \
  --load \
  "$@" \
  .

echo
echo "built $image_tag; the standalone verification passed inside it"
echo "try: docker run --rm -it -v \"\$PWD:/work\" $image_tag repl"
