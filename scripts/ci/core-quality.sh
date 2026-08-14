#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# One BEAM boot for every check that can share one. A `mix` invocation in this
# project costs ~0.9 s before it does any work -- boot, dependency resolution,
# and the launcher path dependency's `make` probe -- and seven invocations paid
# that seven times. `mix do` keeps the semantics: it runs tasks in order and
# stops at the first one that raises or halts, which is how every task here
# reports failure.
#
# Order is cheapest-first so the quickest fix surfaces first. `credo` is last
# because it costs more than the rest of the chain combined.
mix do \
  compile --warnings-as-errors + \
  xref graph --format cycles --label compile-connected --fail-above 0 + \
  format --check-formatted + \
  ptc.validate_spec + \
  ptc.gen_docs --check + \
  ptc.conformance_report --check-inventory + \
  credo --strict

# Stays a separate invocation: the duplication gate parses `mix ex_dna`'s JSON
# report off a stdout that no other task may have written to.
scripts/duplication_gate.sh check
