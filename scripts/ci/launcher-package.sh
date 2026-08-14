#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# The launcher's own `precommit` alias fetches, but with a bare `deps.get`:
# a lockfile that diverged from its `mix.exs` is silently rewritten there and
# rejected by CI's `--check-locked`. Establish the locked fetch here so this
# gate answers the same way in both places, however it was entered.
ci_fetch_deps ptc_runner_launcher

cd ptc_runner_launcher || exit 1
mix clean
mix precommit
