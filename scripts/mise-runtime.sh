#!/usr/bin/env bash

# Shared non-interactive mise resolution for repository lifecycle scripts and
# installed Git-hook wrappers.

ptc_mise_executable() {
  if [ -n "${MISE_BIN:-}" ] && [ -x "$MISE_BIN" ]; then
    printf '%s' "$MISE_BIN"
  elif command -v mise >/dev/null 2>&1; then
    command -v mise
  elif [ -n "${HOME:-}" ] && [ -x "$HOME/.local/bin/mise" ]; then
    printf '%s' "$HOME/.local/bin/mise"
  else
    return 1
  fi
}
