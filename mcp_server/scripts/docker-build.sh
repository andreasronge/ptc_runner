#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/docker-build.sh --image IMAGE --tag TAG [--tag TAG ...] [--platform PLATFORM[,PLATFORM...]] [--load|--push] [--dry-run]

Builds the ptc_runner_mcp Docker image from the repository root.

Options:
  --image IMAGE       Image name, for example ghcr.io/andreasronge/ptc-runner-mcp
  --tag TAG           Image tag to build. May be repeated.
  --platform LIST     Optional buildx platform list
  --load              Load a local single-platform image into Docker
  --push              Push the image to the registry
  --dry-run           Print the docker buildx command without running it
  -h, --help          Show this help
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

image=""
tags=()
platforms=""
output_flag=""
dry_run=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image)
      image="${2:-}"
      shift 2
      ;;
    --tag)
      tags+=("${2:-}")
      shift 2
      ;;
    --platform)
      platforms="${2:-}"
      shift 2
      ;;
    --load|--push)
      output_flag="$1"
      shift
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

if [ -z "$image" ] || [ "${#tags[@]}" -eq 0 ]; then
  echo "--image and at least one --tag are required" >&2
  usage >&2
  exit 2
fi

if [ -z "$output_flag" ]; then
  output_flag="--load"
fi

args=(
  buildx build
  --file "$repo_root/mcp_server/Dockerfile"
)

for tag in "${tags[@]}"; do
  args+=(--tag "$image:$tag")
done

if [ -n "$platforms" ]; then
  args+=(--platform "$platforms")
fi

args+=("$output_flag" "$repo_root")

if [ "$dry_run" = true ]; then
  printf 'docker'
  printf ' %q' "${args[@]}"
  printf '\n'
else
  docker "${args[@]}"
fi
