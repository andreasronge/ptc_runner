#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

if [ "$#" -gt 1 ]; then
  echo "usage: launcher.sh [ARTIFACT_DIRECTORY]" >&2
  exit 64
fi

artifact_directory="${1:-}"
cleanup_artifacts=false

if [ -z "$artifact_directory" ]; then
  artifact_directory="$(mktemp -d "${TMPDIR:-/tmp}/ptc-launcher-ci.XXXXXX")"
  cleanup_artifacts=true
fi

cleanup() {
  if [ "$cleanup_artifacts" = true ]; then
    rm -rf "$artifact_directory"
  fi
}
trap cleanup EXIT

"$script_dir/launcher-package.sh"
bash ptc_runner_launcher/scripts/verify_precompiled.sh "$artifact_directory"
