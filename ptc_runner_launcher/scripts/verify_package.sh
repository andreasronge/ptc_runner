#!/usr/bin/env bash
set -euo pipefail

launcher_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-launcher-package.XXXXXX")"

cleanup() {
  rm -rf "$package_tmp_dir"
}
trap cleanup EXIT

cd "$launcher_root"
mix hex.build --unpack --output "$package_tmp_dir/source"

cd "$package_tmp_dir/source"
mix deps.get
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix run --no-start -e '
case PtcRunnerLauncher.executable_path() do
  {:ok, path} ->
    unless Path.type(path) == :absolute and File.regular?(path) do
      raise "packaged launcher was not restored as a regular absolute executable"
    end

  {:error, reason} ->
    raise "packaged launcher unavailable: #{inspect(reason)}"
end
'
