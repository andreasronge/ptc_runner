#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: verify_precompiled.sh OUTPUT_DIRECTORY" >&2
  exit 64
fi

launcher_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_directory="$(mkdir -p "$1" && cd "$1" && pwd)"
verification_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-launcher-precompiled.XXXXXX")"
checksum_path="$launcher_root/checksum.exs"
checksum_backup="$verification_tmp_dir/checksum.exs.backup"
server_pid=""

fail_with_log() {
  message=$1
  log=$2

  echo "$message" >&2
  if [ -f "$log" ]; then
    cat "$log" >&2
  fi
  exit 1
}

require_log_text() {
  text=$1
  log=$2
  message=$3

  if ! grep -q "$text" "$log"; then
    fail_with_log "$message" "$log"
  fi
}

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi

  if [ -f "$checksum_backup" ]; then
    cp "$checksum_backup" "$checksum_path"
  else
    rm -f "$checksum_path"
  fi

  rm -rf "$verification_tmp_dir"
}
trap cleanup EXIT

cd "$launcher_root"
if [ -f "$checksum_path" ]; then
  cp "$checksum_path" "$checksum_backup"
fi

published_directory="$verification_tmp_dir/published"
mkdir -p "$published_directory"

case "$(uname -s):$(uname -m)" in
  Darwin:arm64) precompile_target="aarch64-apple-darwin" ;;
  Darwin:x86_64) precompile_target="x86_64-apple-darwin" ;;
  Linux:aarch64 | Linux:arm64) precompile_target="aarch64-linux-gnu" ;;
  Linux:x86_64) precompile_target="x86_64-linux-gnu" ;;
  *)
    echo "unsupported precompile host: $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac

PTC_RUNNER_LAUNCHER_PRECOMPILE_TARGET="$precompile_target" \
  ELIXIR_MAKE_CACHE_DIR="$published_directory" \
  MIX_ENV=prod \
  mix elixir_make.precompile

address_file="$verification_tmp_dir/server-address"
elixir test/support/artifact_server.exs \
  "$published_directory" \
  "$address_file" \
  >"$verification_tmp_dir/server.log" 2>&1 &
server_pid="$!"

for _attempt in $(seq 1 100); do
  if [ -s "$address_file" ]; then
    break
  fi

  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$verification_tmp_dir/server.log" >&2
    exit 1
  fi

  sleep 0.05
done

if [ ! -s "$address_file" ]; then
  fail_with_log \
    "artifact server did not publish its listening address" \
    "$verification_tmp_dir/server.log"
fi

base_url="$(tr -d '\r\n' <"$address_file")"
precompiled_url="$base_url/@{artefact_filename}"

download_build="$verification_tmp_dir/download-build"
download_cache="$verification_tmp_dir/download-cache"

# ElixirMake's :httpc downloader honors HTTP_PROXY but not NO_PROXY. GitHub's
# macOS runners define a proxy, which would route this loopback-only fixture
# through the proxy and make the download fail after its network timeout.
clear_proxy=(
  HTTP_PROXY=
  HTTPS_PROXY=
  http_proxy=
  https_proxy=
)

# BUILD_FROM_SOURCE=0 overrides the repository-checkout force-build default
# in mix.exs: this script runs from the checkout but must exercise the
# precompiled download path that default would bypass.
PTC_RUNNER_LAUNCHER_BUILD_FROM_SOURCE=0 \
  PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="$precompiled_url" \
  ELIXIR_MAKE_CACHE_DIR="$download_cache" \
  MIX_BUILD_PATH="$download_build" \
  MIX_ENV=prod \
  env "${clear_proxy[@]}" \
  mix compile --force --warnings-as-errors \
  2>&1 | tee "$verification_tmp_dir/download.log"

if grep -q "Attempting to compile ptc_runner_launcher from source" \
  "$verification_tmp_dir/download.log"; then
  fail_with_log \
    "precompiled verification silently fell back to a source build" \
    "$verification_tmp_dir/download.log"
fi

require_log_text \
  "Downloading precompiled NIF" \
  "$verification_tmp_dir/download.log" \
  "precompiled verification did not download an artifact"

PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="$precompiled_url" \
  ELIXIR_MAKE_CACHE_DIR="$download_cache" \
  MIX_BUILD_PATH="$download_build" \
  MIX_ENV=prod \
  mix run --no-compile --no-start -e '
case PtcRunnerLauncher.executable_path() do
  {:ok, path} ->
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(path)},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:packet, 4}]
      )

    true = Port.command(port, "")

    receive do
      {^port, {:exit_status, status}} when status != 0 -> :ok
    after
      2_000 -> raise "downloaded launcher did not execute and reject an empty bootstrap"
    end

  {:error, reason} ->
    raise "downloaded launcher unavailable: #{inspect(reason)}"
end
'

shopt -s nullglob
archives=("$published_directory"/*.tar.gz)
shopt -u nullglob

if [ "${#archives[@]}" -ne 1 ]; then
  echo "expected exactly one precompiled archive, found ${#archives[@]}" >&2
  find "$published_directory" -maxdepth 1 -type f -print >&2
  exit 1
fi

archive="${archives[0]}"
cp "$published_directory"/* "$output_directory/"
printf '\0' >>"$archive"

rm -rf "$download_build" "$download_cache"

PTC_RUNNER_LAUNCHER_BUILD_FROM_SOURCE=0 \
  PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="$precompiled_url" \
  ELIXIR_MAKE_CACHE_DIR="$download_cache" \
  MIX_BUILD_PATH="$download_build" \
  MIX_ENV=prod \
  env "${clear_proxy[@]}" \
  mix compile --force --warnings-as-errors \
  2>&1 | tee "$verification_tmp_dir/tampered.log"

require_log_text \
  "does not match its checksum" \
  "$verification_tmp_dir/tampered.log" \
  "tampered artifact was not rejected by its checksum"
require_log_text \
  "Attempting to compile ptc_runner_launcher from source" \
  "$verification_tmp_dir/tampered.log" \
  "checksum rejection did not fall back to an audited source build"

source_build="$verification_tmp_dir/source-build"
PTC_RUNNER_LAUNCHER_BUILD_FROM_SOURCE=1 \
  PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="http://127.0.0.1:1/@{artefact_filename}" \
  MIX_BUILD_PATH="$source_build" \
  MIX_ENV=prod \
  mix compile --force --warnings-as-errors \
  >"$verification_tmp_dir/source.log" 2>&1

if grep -q "Downloading precompiled NIF" "$verification_tmp_dir/source.log"; then
  echo "explicit source fallback attempted an artifact download" >&2
  exit 1
fi

unlisted_build="$verification_tmp_dir/unlisted-build"
TARGET_ARCH=unlisted \
  TARGET_OS=linux \
  TARGET_ABI=gnu \
  PTC_RUNNER_LAUNCHER_BUILD_FROM_SOURCE=0 \
  PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="http://127.0.0.1:1/@{artefact_filename}" \
  MIX_BUILD_PATH="$unlisted_build" \
  MIX_ENV=prod \
  mix compile --force --warnings-as-errors \
  >"$verification_tmp_dir/unlisted.log" 2>&1

if grep -q "Downloading precompiled NIF" "$verification_tmp_dir/unlisted.log"; then
  echo "unlisted target attempted an artifact download" >&2
  exit 1
fi

TARGET_ARCH=unlisted \
  TARGET_OS=linux \
  TARGET_ABI=gnu \
  PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="http://127.0.0.1:1/@{artefact_filename}" \
  MIX_BUILD_PATH="$unlisted_build" \
  MIX_ENV=prod \
  mix run --no-compile --no-start -e '
{:ok, path} = PtcRunnerLauncher.executable_path()
true = File.regular?(path)
'
