#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/docker-publish.sh --image IMAGE [--ref REF] [--sha SHA] [--platform PLATFORM[,PLATFORM...]] [--dry-run]

Builds and pushes GHCR tags for ptc_runner_mcp.

Stable mcp-vX.Y.Z refs push:
  mcp-vX.Y.Z, X.Y.Z, sha-<short-sha>

Main refs push:
  snapshot, main, sha-<short-sha>

Options:
  --image IMAGE       Image name, for example ghcr.io/andreasronge/ptc-runner-mcp
  --ref REF           Git ref. Defaults to GITHUB_REF or current git ref.
  --sha SHA           Commit SHA. Defaults to GITHUB_SHA or current git SHA.
  --platform LIST     Buildx platform list. Defaults to linux/amd64,linux/arm64
  --dry-run           Print the docker buildx command without running it
  -h, --help          Show this help
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

image=""
ref="${GITHUB_REF:-}"
sha="${GITHUB_SHA:-}"
platforms="linux/amd64,linux/arm64"
dry_run=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      image="${2:-}"
      shift 2
      ;;
    --ref)
      ref="${2:-}"
      shift 2
      ;;
    --sha)
      sha="${2:-}"
      shift 2
      ;;
    --platform)
      platforms="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$image" ]; then
  echo "--image is required" >&2
  usage >&2
  exit 2
fi

if [ -z "$ref" ]; then
  ref="$(git symbolic-ref -q HEAD || git describe --tags --exact-match)"
fi

if [ -z "$sha" ]; then
  sha="$(git rev-parse HEAD)"
fi

short_sha="${sha:0:12}"
tags=()

case "$ref" in
  refs/tags/mcp-v*)
    release_tag="${ref#refs/tags/}"
    version="${release_tag#mcp-v}"
    tags+=("$release_tag" "$version" "sha-$short_sha")
    ;;
  refs/heads/main)
    tags+=("snapshot" "main" "sha-$short_sha")
    ;;
  *)
    echo "Ref $ref is not a publish ref; nothing to push." >&2
    exit 0
    ;;
esac

build_args=(
  --image "$image"
  --platform "$platforms"
  --push
)

if [ "$dry_run" = true ]; then
  build_args+=(--dry-run)
fi

for tag in "${tags[@]}"; do
  build_args+=(--tag "$tag")
done

"$script_dir/docker-build.sh" "${build_args[@]}"
