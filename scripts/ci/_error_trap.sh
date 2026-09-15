#!/usr/bin/env bash

# Shared diagnostics for repository gates that rely on `set -e`. ERR traps are
# not inherited by functions, command substitutions, or subshells unless
# errtrace is enabled.
set -E

ci_report_command_failure() {
  local status="$1"
  local command="$2"
  local source="$3"
  local line="$4"

  # ERR traps remain active under `set +e`; those failures are being handled
  # explicitly by the caller and must stay silent.
  if [[ "$-" != *e* ]]; then
    return 0
  fi

  # Bash also raises ERR for the enclosing function after raising it for the
  # command within that function. Keep the first, most specific diagnostic.
  if [[ "${ci_error_reported:-false}" == true ]]; then
    return 0
  fi
  ci_error_reported=true

  printf 'error: command failed: %s\n  status: %s\n  location: %s:%s\n' \
    "$command" "$status" "$source" "$line" >&2
}

trap 'ci_report_command_failure "$?" "$BASH_COMMAND" "${BASH_SOURCE[0]}" "$LINENO"' ERR
