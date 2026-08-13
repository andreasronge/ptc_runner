#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

"$script_dir/core-quality.sh"
mix ptc.audit_upstream
mix deps.unlock --check-unused
