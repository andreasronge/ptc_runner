#!/usr/bin/env bash

# Shared process contract for repository-owned deterministic gates.
# This file is sourced by the executable entry points in this directory.

set -euo pipefail

ci_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ci_repo_root"

export MIX_ENV=test
export HEX_SPONSOR=false

# A gate fetches what it is about to compile.
#
# `ptc_viewer` and `ptc_runner_launcher` are separate Mix projects: the root's
# `deps/` says nothing about whether theirs were ever fetched. GitHub supplies
# each from the setup action's `project-directory`
# (.github/actions/setup-elixir), so a gate that assumes them is green in CI
# and fails only locally -- in a fresh worktree, after the multi-minute suites
# that run ahead of it. `--check-locked` is the flag CI uses: an unfetched
# project is repaired, a lockfile that diverged from its `mix.exs` fails here
# exactly as it would there. About a second per project once warm.
ci_fetch_deps() {
  (cd "$ci_repo_root/$1" && mix deps.get --check-locked)
}
