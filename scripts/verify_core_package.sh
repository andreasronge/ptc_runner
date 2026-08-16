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

  # The Viewer ships in the assembled release and the container image, not in
  # this package. It is unpublished, so naming it here -- even optionally --
  # would be a requirement on a package Hex cannot resolve.
  nil =
    Enum.find(requirements, fn requirement ->
      Map.new(requirement)[<<"name">>] == <<"ptc_viewer">>
    end)
' "$package_tmp_dir/package/metadata.config"

test ! -e "$package_tmp_dir/source/ptc_runner_launcher"
test ! -e "$package_tmp_dir/source/ptc_viewer"
test -z "$(find "$package_tmp_dir/source" -type f \( -name '*.c' -o -name '*.so' -o -name '*.dylib' \) -print -quit)"
test -x "$package_tmp_dir/source/rel/overlays/bin/ptc"
test -f "$package_tmp_dir/source/priv/schemas/ptc-host-config.schema.json"
test -f "$package_tmp_dir/source/priv/schemas/ptc-application-manifest.schema.json"
test -f "$package_tmp_dir/source/priv/schemas/ptc-project-config.schema.json"
test -f "$package_tmp_dir/source/docs/kernel-limits-reference.md"
test -f "$package_tmp_dir/source/docs/prelude-reference.md"
test -f "$package_tmp_dir/source/examples/mcp/filesystem/dist/server.js"
test -f "$package_tmp_dir/source/examples/mcp/filesystem/NOTICE"
test ! -e "$package_tmp_dir/source/dev"

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

# The packaged source is compiled at `prod` below, so its dependency beams
# must come from the project's own `prod` build — and this script has to build
# that itself. Ambient MIX_ENV must not choose it: `mix precommit` runs at
# `test` and `mix cmd` exports no MIX_ENV, so `_build/${MIX_ENV:-dev}` checked
# whichever environment the caller's shell happened to have compiled, and in a
# worktree that had only ever run the gate it failed with no diagnosis.
# `verify_standalone_release.sh` builds the same tree next, so this is paid
# once.
build_env=prod
MIX_ENV="$build_env" mix deps.compile

active_build_lib="$project_root/_build/$build_env/lib"

if [[ ! -d "$active_build_lib/jason" ]]; then
  echo "no compiled $build_env dependencies at $active_build_lib" >&2
  exit 1
fi

# `ptc_viewer` is excluded for the same reason as the two companions: this
# compile is the only place that proves the packaged source builds without the
# optional Viewer. `verify_standalone_release.sh` leaves a compiled
# `_build/prod/lib/ptc_viewer` behind, so linking everything would make the
# check pass on every run after the first while still failing in a fresh
# worktree.
for dependency in "$active_build_lib"/*; do
  name="$(basename "$dependency")"

  if [[ "$name" != "ptc_runner" && "$name" != "ptc_runner_launcher" && "$name" != "ptc_viewer" ]]; then
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
