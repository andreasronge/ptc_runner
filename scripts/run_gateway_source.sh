#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gateway_pid=""

forward_shutdown() {
  if [ -n "$gateway_pid" ]; then
    kill -TERM "$gateway_pid" 2>/dev/null || true
  fi
}

trap forward_shutdown INT TERM

cd "$project_root/ptc_gateway"
ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:+$ELIXIR_ERL_OPTIONS }+Bd" \
  mix ptc.gateway "$@" &
gateway_pid=$!

set +e
wait "$gateway_pid"
status=$?
while kill -0 "$gateway_pid" 2>/dev/null; do
  wait "$gateway_pid"
  status=$?
done
set -e

exit "$status"
