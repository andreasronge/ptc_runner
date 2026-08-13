#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

export MIX_ENV=dev

mix deps.get --check-locked
mix docs --warnings-as-errors
