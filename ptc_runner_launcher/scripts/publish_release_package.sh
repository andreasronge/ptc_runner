#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: publish_release_package.sh PACKAGE_TARBALL" >&2
  exit 64
fi

package_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
test -f "$package_path"

if [ -z "${HEX_API_KEY:-}" ]; then
  echo "HEX_API_KEY is required" >&2
  exit 64
fi

hex_api_url="${HEX_API_URL:-https://hex.pm/api}"
response_file="$(mktemp "${TMPDIR:-/tmp}/ptc-runner-launcher-hex-response.XXXXXX")"

cleanup() {
  rm -f "$response_file"
}
trap cleanup EXIT

status="$(
  curl \
    --silent \
    --show-error \
    --output "$response_file" \
    --write-out '%{http_code}' \
    --request POST \
    --header "authorization: $HEX_API_KEY" \
    --header "content-type: application/octet-stream" \
    --data-binary "@$package_path" \
    "$hex_api_url/packages/ptc_runner_launcher/releases?replace=false"
)"

case "$status" in
  2??)
    printf 'published %s to Hex (%s)\n' "$(basename "$package_path")" "$status"
    ;;

  *)
    cat "$response_file" >&2
    exit 1
    ;;
esac
