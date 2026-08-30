#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ptc-runner-core-package.XXXXXX")"
dependency_build=""

cleanup() {
  rm -rf "$package_tmp_dir"

  if [[ -n "$dependency_build" ]]; then
    rm -rf "$dependency_build"
  fi
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

  # PtcLlmHttp is published, but it is compatibility coverage only: exact Hex
  # `0.1.0` in dev/test, never a production runtime requirement, and never
  # selected for ordinary requests.
  nil =
    Enum.find(requirements, fn requirement ->
      Map.new(requirement)[<<"name">>] == <<"ptc_llm_http">>
    end)
' "$package_tmp_dir/package/metadata.config"

test ! -e "$package_tmp_dir/source/ptc_runner_launcher"
test ! -e "$package_tmp_dir/source/ptc_viewer"
test -z "$(find "$package_tmp_dir/source" -type f \( -name '*.c' -o -name '*.so' -o -name '*.dylib' \) -print -quit)"
test -x "$package_tmp_dir/source/rel/overlays/bin/ptc"
test -f "$package_tmp_dir/source/priv/schemas/ptc-host-config.schema.json"
test -f "$package_tmp_dir/source/priv/schemas/ptc-application-manifest.schema.json"
test -f "$package_tmp_dir/source/priv/schemas/ptc-project-config.schema.json"
grep -Eq '^[0-9a-f]{40}$' "$package_tmp_dir/source/priv/source_revision"
grep -Eq '^(true|false)$' "$package_tmp_dir/source/priv/source_dirty"
cmp "$project_root/site/schemas/mcp-2026-07-28.schema.json" \
  "$package_tmp_dir/source/site/schemas/mcp-2026-07-28.schema.json"
cmp "$project_root/THIRD_PARTY_NOTICES.md" "$package_tmp_dir/source/THIRD_PARTY_NOTICES.md"
cmp "$project_root/LICENSES/Apache-2.0.txt" "$package_tmp_dir/source/LICENSES/Apache-2.0.txt"
cmp "$project_root/LICENSES/MIT.txt" "$package_tmp_dir/source/LICENSES/MIT.txt"
test -f "$package_tmp_dir/source/docs/kernel-limits-reference.md"
test -f "$package_tmp_dir/source/docs/prelude-reference.md"
test ! -e "$package_tmp_dir/source/dev"

# Hex expands the packaged directories from the working tree rather than from
# git, so an ignored-but-present entry publishes with the release: a `.ptc`
# directory left by a tutorial walk carries run traces and private inspection
# records, and a `.env` beside an example carries a credential. A clean CI
# checkout has neither, so only a build from a working tree can catch this --
# which is exactly the build that publishes. `.formatter.exs` is the sole
# dot-entry the package names.
unexpected_dot_entries="$(
  cd "$package_tmp_dir/source" \
    && find . -name '.*' -not -name '.' -not -path './.formatter.exs'
)"

if [[ -n "$unexpected_dot_entries" ]]; then
  echo "packaged source carries dot-entries beyond .formatter.exs:" >&2
  echo "$unexpected_dot_entries" >&2
  exit 1
fi

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

      llm_http =
        PtcRunner.MixProject.project()
        |> Keyword.fetch!(:deps)
        |> Enum.find(&(elem(&1, 0) == :ptc_llm_http))

      {:ptc_llm_http, "== 0.1.0", llm_http_options} = llm_http
      true = llm_http_options[:only] == [:dev, :test]
      false = llm_http_options[:runtime]
    '
  )
done

cp "$project_root/mix.lock" "$package_tmp_dir/source/mix.lock"
mkdir -p "$package_tmp_dir/build/lib"

# The packaged source is compiled at `prod` below, so this script builds its
# dependency beams in an isolated path. Reusing `_build/prod` is incorrect: an
# earlier `mix release` activates the local Viewer and leaves Plug there, while
# an ordinary production dependency graph excludes both. Req can then observe
# Plug during conditional compilation just before Mix removes the stale app,
# producing a checkout-history-dependent compile failure.
build_env=prod
dependency_build="$(mktemp -d "$project_root/_build/ptc-core-package-deps.XXXXXX")"
MIX_ENV="$build_env" MIX_BUILD_PATH="$dependency_build" mix deps.compile

active_build_lib="$dependency_build/lib"

if [[ ! -d "$active_build_lib/jason" ]]; then
  echo "no compiled $build_env dependencies at $active_build_lib" >&2
  exit 1
fi

if [[ -d "$active_build_lib/ptc_llm_http" ]]; then
  echo "ptc_llm_http must not compile into $build_env" >&2
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
