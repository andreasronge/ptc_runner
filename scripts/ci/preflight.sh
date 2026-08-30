#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# Fail-fast admission for the local gate.
#
# Every gate already fetches the project it compiles, so this changes no
# outcome -- only when you learn it. `mix precommit` is quality-only; git
# push still reaches the Viewer and the launcher after the suite. A worktree
# that never fetched them, or a branch whose nested lockfile diverged from
# its `mix.exs`, should cost seconds at the start of `mix precommit` rather
# than a failed Viewer or launcher gate after minutes of tests.
#
# The root project is deliberately absent: the gate that runs next opens with
# `mix compile`, which reports the root's own dependency state before anything
# long-running starts. GitHub does not run this script -- there each job gets
# the same fetch from the setup action, and each job is already independent.
ci_fetch_deps ptc_viewer
ci_fetch_deps ptc_runner_launcher
