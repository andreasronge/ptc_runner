#!/usr/bin/env bash

# Shared process contract for repository-owned deterministic gates.
# This file is sourced by the executable entry points in this directory.

set -euo pipefail

ci_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ci_repo_root"

export MIX_ENV=test
export HEX_SPONSOR=false
