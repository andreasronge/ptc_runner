#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "$script_dir/../../scripts/publish_hex_artifact.sh" \
  "$@" \
  "packages/ptc_runner_launcher/releases?replace=false"
