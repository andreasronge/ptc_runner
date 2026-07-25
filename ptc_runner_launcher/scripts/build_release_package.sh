#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: build_release_package.sh ARTIFACT_DIRECTORY" >&2
  exit 64
fi

launcher_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
artifact_directory="$(cd "$1" && pwd)"
release_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-launcher-release.XXXXXX")"
checksum_path="$launcher_root/checksum.exs"
checksum_backup="$release_tmp_dir/checksum.exs.backup"
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

  rm -rf "$release_tmp_dir"
}
trap cleanup EXIT

cd "$launcher_root"
if [ -f "$checksum_path" ]; then
  cp "$checksum_path" "$checksum_backup"
fi

elixir scripts/assemble_checksums.exs "$artifact_directory" "$checksum_path"
cp "$checksum_path" "$artifact_directory/checksum.exs"

launcher_version="$(
  elixir -e '
    {config, _bindings} = Code.eval_file("release_config.exs")
    IO.write(config.version)
  '
)"
package_path="$artifact_directory/ptc_runner_launcher-$launcher_version.tar"

mix hex.build --output "$package_path"

mkdir -p "$release_tmp_dir/package" "$release_tmp_dir/source"
tar -xf "$package_path" -C "$release_tmp_dir/package"
tar -xzf "$release_tmp_dir/package/contents.tar.gz" -C "$release_tmp_dir/source"
cmp "$checksum_path" "$release_tmp_dir/source/checksum.exs"

address_file="$release_tmp_dir/server-address"
python3 test/support/artifact_server.py \
  "$artifact_directory" \
  "$address_file" \
  >"$release_tmp_dir/server.log" 2>&1 &
server_pid="$!"

for _attempt in $(seq 1 100); do
  if [ -s "$address_file" ]; then
    break
  fi

  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$release_tmp_dir/server.log" >&2
    exit 1
  fi

  sleep 0.05
done

test -s "$address_file"
base_url="$(tr -d '\r\n' <"$address_file")"

cd "$release_tmp_dir/source"
mix deps.get
PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="$base_url/@{artefact_filename}" \
  ELIXIR_MAKE_CACHE_DIR="$release_tmp_dir/precompiled-cache" \
  MIX_BUILD_PATH="$release_tmp_dir/precompiled-build" \
  MIX_ENV=prod \
  mix compile --force --warnings-as-errors \
  >"$release_tmp_dir/precompiled.log" 2>&1
grep -q "Downloading precompiled NIF" "$release_tmp_dir/precompiled.log"
if grep -q "Attempting to compile ptc_runner_launcher from source" \
  "$release_tmp_dir/precompiled.log"; then
  cat "$release_tmp_dir/precompiled.log" >&2
  exit 1
fi

PTC_RUNNER_LAUNCHER_PRECOMPILED_URL="$base_url/@{artefact_filename}" \
  ELIXIR_MAKE_CACHE_DIR="$release_tmp_dir/precompiled-cache" \
  MIX_BUILD_PATH="$release_tmp_dir/precompiled-build" \
  MIX_ENV=prod \
  mix run --no-compile --no-start -e '
{:ok, path} = PtcRunnerLauncher.executable_path()
true = Path.type(path) == :absolute
true = File.regular?(path)

port =
  Port.open(
    {:spawn_executable, String.to_charlist(path)},
    [:binary, :exit_status, :use_stdio, :stderr_to_stdout, {:packet, 4}]
  )

true = Port.command(port, "")

receive do
  {^port, {:exit_status, status}} when status != 0 -> :ok
after
  2_000 -> raise "packaged precompiled launcher did not execute"
end
'

PTC_RUNNER_LAUNCHER_BUILD_FROM_SOURCE=1 \
  MIX_BUILD_PATH="$release_tmp_dir/source-build" \
  MIX_ENV=prod \
  mix compile --force --warnings-as-errors

kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
server_pid=""

publish_address_file="$release_tmp_dir/publish-address"
publish_receipt_file="$release_tmp_dir/publish-receipt"
python3 "$launcher_root/test/support/hex_publish_server.py" \
  "$package_path" \
  "$publish_address_file" \
  "$publish_receipt_file" \
  >"$release_tmp_dir/publish-server.log" 2>&1 &
server_pid="$!"

for _attempt in $(seq 1 100); do
  if [ -s "$publish_address_file" ]; then
    break
  fi

  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$release_tmp_dir/publish-server.log" >&2
    exit 1
  fi

  sleep 0.05
done

test -s "$publish_address_file"
HEX_API_KEY=test-api-key \
  HEX_API_URL="$(tr -d '\r\n' <"$publish_address_file")" \
  bash "$launcher_root/scripts/publish_release_package.sh" "$package_path"
wait "$server_pid"
server_pid=""
test "$(cat "$publish_receipt_file")" = "accepted"
