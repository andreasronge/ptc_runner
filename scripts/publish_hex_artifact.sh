#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: publish_hex_artifact.sh ARTIFACT API_PATH" >&2
  exit 64
fi

artifact_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
api_path="$2"
test -f "$artifact_path"

if [ -z "${HEX_API_KEY:-}" ]; then
  echo "HEX_API_KEY is required" >&2
  exit 64
fi

case "$api_path" in
  /*|*..*)
    echo "API_PATH must be relative and cannot contain '..'" >&2
    exit 64
    ;;
esac

hex_api_url="${HEX_API_URL:-https://hex.pm/api}"
response_file="$(mktemp "${TMPDIR:-/tmp}/ptc-runner-hex-response.XXXXXX")"

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
    --data-binary "@$artifact_path" \
    "$hex_api_url/$api_path"
)"

case "$status" in
  2??)
    printf 'published %s to Hex (%s)\n' "$(basename "$artifact_path")" "$status"
    ;;

  *)
    cat "$response_file" >&2
    exit 1
    ;;
esac
