#!/usr/bin/env bash

# Run a tracked hook with the pinned toolchain even when Git starts it from a
# non-interactive shell where mise has not amended PATH. The umask applies to
# the hook and every gate it launches, including ExUnit temporary directories.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/mise-runtime.sh
source "$SCRIPT_DIR/mise-runtime.sh"

TARGET="${1:-}"
[ -n "$TARGET" ] || {
  echo "❌ Hook runtime requires a tracked hook path" >&2
  exit 1
}
shift

umask 0022

if command -v mix >/dev/null 2>&1; then
  exec "$TARGET" "$@"
fi

if ! MISE_EXECUTABLE="$(ptc_mise_executable)"; then
  echo "❌ mix is not on PATH and mise could not be found" >&2
  echo "   Run scripts/worktree.sh init or set MISE_BIN before committing." >&2
  exit 1
fi

exec "$MISE_EXECUTABLE" exec -- "$TARGET" "$@"
