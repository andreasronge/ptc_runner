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

  # PtcLlmHttp is an exact optional Hex dependency. Downstream hosts that
  # select `PtcRunner.LLM.PtcLlmHttpAdapter` install it explicitly. Ordinary
  # packaged builds compile without it.
  llm_http =
    Enum.find(requirements, fn requirement ->
      Map.new(requirement)[<<"name">>] == <<"ptc_llm_http">>
    end)

  true =
    Map.new(llm_http) == %{
      <<"app">> => <<"ptc_llm_http">>,
      <<"name">> => <<"ptc_llm_http">>,
      <<"optional">> => true,
      <<"repository">> => <<"hexpm">>,
      <<"requirement">> => <<"== 0.1.0">>
    }
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
test ! -e "$package_tmp_dir/source/dev"

for mix_env in dev test prod; do
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

      llm_http =
        PtcRunner.MixProject.project()
        |> Keyword.fetch!(:deps)
        |> Enum.find(&(elem(&1, 0) == :ptc_llm_http))

      {:ptc_llm_http, "== 0.1.0", llm_http_options} = llm_http
      true = llm_http_options[:optional]
      false = llm_http_options[:runtime]
      false = Keyword.has_key?(llm_http_options, :only)
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

# Optional provider packages may compile into this checkout's prod build when
# they are locked. The packaged-source compile below is the proof that ordinary
# Hex consumers are not forced to install them.
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
#
# Optional LLM packages are excluded here so `--no-optional-deps` compiles the
# stub adapter rather than the real `PtcLlmHttp` module that happens to exist
# in this checkout's prod build.
skip_optional="ptc_runner ptc_runner_launcher ptc_viewer ptc_llm_http req_llm llm_db"

for dependency in "$active_build_lib"/*; do
  name="$(basename "$dependency")"

  if [[ " $skip_optional " != *" $name "* ]]; then
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

(
  cd "$package_tmp_dir/source"
  MIX_ENV=prod \
    MIX_DEPS_PATH="$project_root/deps" \
    MIX_BUILD_PATH="$package_tmp_dir/build" \
    mix run --no-deps-check --no-start --no-compile -e '
      false = Code.ensure_loaded?(PtcLlmHttp)
      {:error, error} =
        PtcRunner.LLM.PtcLlmHttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash")
      :internal = error.kind
      true = is_binary(error.details)
      false = String.contains?(error.details, "sk-")
    '
)

optional_build="$package_tmp_dir/optional-build"
mkdir -p "$optional_build/lib"

for dependency in "$active_build_lib"/*; do
  name="$(basename "$dependency")"

  if [[ "$name" != "ptc_runner" && "$name" != "ptc_runner_launcher" && "$name" != "ptc_viewer" ]]; then
    ln -s "$dependency" "$optional_build/lib/$name"
  fi
done

(
  cd "$package_tmp_dir/source"
  MIX_ENV=prod \
    MIX_DEPS_PATH="$project_root/deps" \
    MIX_BUILD_PATH="$optional_build" \
    mix compile --no-deps-check --warnings-as-errors
)

(
  cd "$package_tmp_dir/source"
  MIX_ENV=prod \
    MIX_DEPS_PATH="$project_root/deps" \
    MIX_BUILD_PATH="$optional_build" \
    mix run --no-deps-check --no-start --no-compile -e '
      true = Code.ensure_loaded?(PtcLlmHttp)
      {:ok, _prepared, :unavailable} =
        PtcRunner.LLM.PtcLlmHttpAdapter.prepare_model("openrouter:deepseek/deepseek-v4-flash")
    '
)
