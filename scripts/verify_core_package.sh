#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-core-package.XXXXXX")"

cleanup() {
  rm -rf "$package_tmp_dir"
}
trap cleanup EXIT

cd "$project_root"
MIX_ENV=prod mix hex.build --output "$package_tmp_dir/ptc_runner.tar"

mkdir -p "$package_tmp_dir/package" "$package_tmp_dir/source"
tar -xf "$package_tmp_dir/ptc_runner.tar" -C "$package_tmp_dir/package"
tar -xzf "$package_tmp_dir/package/contents.tar.gz" -C "$package_tmp_dir/source"

elixir -e '
  metadata_path = hd(System.argv())
  {:ok, metadata} = :file.consult(String.to_charlist(metadata_path))
  requirements = metadata |> Map.new() |> Map.fetch!(<<"requirements">>)

  launcher =
    Enum.find(requirements, fn requirement ->
      Map.new(requirement)[<<"name">>] == <<"ptc_runner_launcher">>
    end)

  true =
    Map.new(launcher) == %{
      <<"app">> => <<"ptc_runner_launcher">>,
      <<"name">> => <<"ptc_runner_launcher">>,
      <<"optional">> => true,
      <<"repository">> => <<"hexpm">>,
      <<"requirement">> => <<"~> 0.1.0">>
    }
' "$package_tmp_dir/package/metadata.config"

test ! -e "$package_tmp_dir/source/ptc_runner_launcher"
test -z "$(find "$package_tmp_dir/source" -type f \( -name '*.c' -o -name '*.so' -o -name '*.dylib' \) -print -quit)"
test -f "$package_tmp_dir/source/priv/schemas/ptc-host-config.schema.json"
test -f "$package_tmp_dir/source/priv/schemas/ptc-application-manifest.schema.json"

for mix_env in dev test; do
  (
    cd "$package_tmp_dir/source"
    MIX_ENV="$mix_env" elixir -e '
      Mix.start()
      Code.compile_file("mix.exs")

      dependency =
        PtcRunner.MixProject.project()
        |> Keyword.fetch!(:deps)
        |> Enum.find(&(elem(&1, 0) == :ptc_runner_launcher))

      {:ptc_runner_launcher, "~> 0.1.0", options} = dependency
      true = options[:optional]
      false = Keyword.has_key?(options, :path)
    '
  )
done

cp "$project_root/mix.lock" "$package_tmp_dir/source/mix.lock"
mkdir -p "$package_tmp_dir/build/lib"

active_build_lib="$project_root/_build/${MIX_ENV:-dev}/lib"
test -d "$active_build_lib"
test -d "$active_build_lib/jason"

for dependency in "$active_build_lib"/*; do
  name="$(basename "$dependency")"

  if [[ "$name" != "ptc_runner" && "$name" != "ptc_runner_launcher" ]]; then
    ln -s "$dependency" "$package_tmp_dir/build/lib/$name"
  fi
done

(
  cd "$package_tmp_dir/source"
  MIX_ENV=prod \
    MIX_DEPS_PATH="$project_root/deps" \
    MIX_BUILD_PATH="$package_tmp_dir/build" \
    mix compile --no-deps-check --no-optional-deps --warnings-as-errors
)
