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

CC_PRECOMPILER_PRECOMPILE_ONLY_LOCAL=true \
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

test -s "$address_file"
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

PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="$precompiled_url" \
  ELIXIR_MAKE_CACHE_DIR="$download_cache" \
  MIX_BUILD_PATH="$download_build" \
  MIX_ENV=prod \
  env "${clear_proxy[@]}" \
  mix compile --force --warnings-as-errors \
  2>&1 | tee "$verification_tmp_dir/download.log"

grep -q "Downloading precompiled NIF" "$verification_tmp_dir/download.log"
if grep -q "Attempting to compile ptc_runner_launcher from source" \
  "$verification_tmp_dir/download.log"; then
  cat "$verification_tmp_dir/download.log" >&2
  exit 1
fi

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

archive="$(find "$published_directory" -maxdepth 1 -type f -name '*.tar.gz' -print)"
test -n "$archive"
test "$(printf '%s\n' "$archive" | wc -l | tr -d ' ')" -eq 1
cp "$published_directory"/* "$output_directory/"
printf '\0' >>"$archive"

rm -rf "$download_build" "$download_cache"

PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="$precompiled_url" \
  ELIXIR_MAKE_CACHE_DIR="$download_cache" \
  MIX_BUILD_PATH="$download_build" \
  MIX_ENV=prod \
  env "${clear_proxy[@]}" \
  mix compile --force --warnings-as-errors \
  2>&1 | tee "$verification_tmp_dir/tampered.log"

grep -q "does not match its checksum" "$verification_tmp_dir/tampered.log"
grep -q "Attempting to compile ptc_runner_launcher from source" \
  "$verification_tmp_dir/tampered.log"

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
