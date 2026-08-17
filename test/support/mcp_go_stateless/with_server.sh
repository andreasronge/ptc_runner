#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: $0 COMMAND [ARG ...]" >&2
  exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_dir/../../.." && pwd)"
temporary_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
server_dir="$(mktemp -d "$temporary_root/ptc-mcp-http.XXXXXX")"
server="$server_dir/server"
log="$server_dir/server.log"
address_file="$server_dir/address"
ca_file="$server_dir/ca.pem"

cleanup() {
  if [ -n "${server_pid:-}" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$server_dir"
}
trap cleanup EXIT

go -C "$script_dir" build -o "$server" .
server_args=(-host 127.0.0.1 -port 0 -address-file "$address_file")
if [ -n "${PTC_TEST_MCP_BEARER_TOKEN:-}" ]; then
  server_args+=(-bearer-token "$PTC_TEST_MCP_BEARER_TOKEN")
fi
if [ "${PTC_TEST_MCP_OAUTH:-}" = "1" ]; then
  server_args+=(-oauth)
fi
if [ "${PTC_TEST_MCP_TLS:-}" = "1" ]; then
  server_args+=(-tls -ca-file "$ca_file")
fi
"$server" "${server_args[@]}" >"$log" 2>&1 &
server_pid=$!

ready=false
for _attempt in {1..60}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$log"
    exit 1
  fi
  if [ -s "$address_file" ]; then
    PTC_TEST_MCP_2026_ENDPOINT="$(tr -d '\r\n' <"$address_file")"
    export PTC_TEST_MCP_2026_ENDPOINT
    curl_args=(--silent --output /dev/null)
    if [ "${PTC_TEST_MCP_TLS:-}" = "1" ]; then
      PTC_TEST_MCP_CA_FILE="$ca_file"
      export PTC_TEST_MCP_CA_FILE
      curl_args+=(--cacert "$ca_file")
    fi
    ready_url="$PTC_TEST_MCP_2026_ENDPOINT"
    if [ "${PTC_TEST_MCP_OAUTH:-}" = "1" ]; then
      ready_url="$PTC_TEST_MCP_2026_ENDPOINT/oauth/stats"
    fi
    if curl "${curl_args[@]}" "$ready_url"; then
      if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$log"
        exit 1
      fi
      ready=true
      break
    fi
  fi
  sleep 1
done

if [ "$ready" != true ]; then
  cat "$log"
  exit 1
fi

cd -- "$repository_root"
"$@"
