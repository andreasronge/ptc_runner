#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

"$script_dir/core-quality.sh"
mix do ptc.audit_upstream + deps.unlock --check-unused
