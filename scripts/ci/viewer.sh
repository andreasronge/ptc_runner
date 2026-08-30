#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

ci_fetch_deps ptc_viewer

cd ptc_viewer || exit 1
mix compile --warnings-as-errors
mix test --warnings-as-errors
