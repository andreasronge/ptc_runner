#!/usr/bin/env bash
set -euo pipefail

launcher_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-launcher-package.XXXXXX")"
checksum_path="$launcher_root/checksum.exs"
checksum_backup="$package_tmp_dir/checksum.exs.backup"

cleanup() {
  if [ -f "$checksum_backup" ]; then
    cp "$checksum_backup" "$checksum_path"
  else
    rm -f "$checksum_path"
  fi
  rm -rf "$package_tmp_dir"
}
trap cleanup EXIT

cd "$launcher_root"
if [ -f "$checksum_path" ]; then
  cp "$checksum_path" "$checksum_backup"
fi

CC_PRECOMPILER_PRECOMPILE_ONLY_LOCAL=true \
  ELIXIR_MAKE_CACHE_DIR="$package_tmp_dir/cache" \
  MIX_ENV=prod \
  mix elixir_make.precompile

mix hex.build --unpack --output "$package_tmp_dir/source"
test -f "$package_tmp_dir/source/checksum.exs"

cd "$package_tmp_dir/source"
mix deps.get
PTC_RUNNER_LAUNCHER_BUILD_FROM_SOURCE=1 \
  MIX_ENV=test \
  mix compile --warnings-as-errors
PTC_RUNNER_LAUNCHER_BUILD_FROM_SOURCE=1 \
  MIX_ENV=test \
  mix run --no-start -e '
case PtcRunnerLauncher.executable_path() do
  {:ok, path} ->
    unless Path.type(path) == :absolute and File.regular?(path) do
      raise "packaged launcher was not restored as a regular absolute executable"
    end

  {:error, reason} ->
    raise "packaged launcher unavailable: #{inspect(reason)}"
end
'
