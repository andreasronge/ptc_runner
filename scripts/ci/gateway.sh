#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

ci_fetch_deps ptc_gateway
npm --prefix ptc_gateway/test/support/mcp_conformance ci --ignore-scripts
cd ptc_gateway
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors --include nightly
