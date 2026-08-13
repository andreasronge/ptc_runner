#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

mix compile --warnings-as-errors
mix xref graph --format cycles --label compile-connected --fail-above 0
mix format --check-formatted
mix credo --strict
scripts/duplication_gate.sh check
mix ptc.validate_spec
mix ptc.gen_docs --check
mix ptc.conformance_report --check-inventory
