#!/usr/bin/env bash

# Classify repository-relative changed paths into independently testable scopes.
# Known standing files have explicit arms so the catch-all stays a fail-safe
# for new repository areas, not the default for ordinary tracked paths.
# Unknown paths deliberately select every scope so those new areas cannot
# silently bypass CI. The same classifier is suitable for CI and local hooks.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
executable_guides="${PTC_EXECUTABLE_GUIDES_FILE:-$repo_root/test/support/executable_guides.txt}"
paths_file="${1:-/dev/stdin}"

core=false
launcher=false
mcp_http=false
mcp_filesystem=false
java=false
viewer=false
docs=false
release=false
operator=false
saw_path=false

select_all() {
  core=true
  launcher=true
  mcp_http=true
  mcp_filesystem=true
  java=true
  viewer=true
  docs=true
  release=true
  operator=true
}

# `operator` is not a gate of its own: it widens the core suite from its
# library lane to every module. The modules it adds carry `@moduletag
# :operator` and drive the repository through its Mix tasks, git hooks,
# scripts, Viewer, guides, and examples, so the surfaces below are the ones
# whose edits must run them before a push. Any test file already tagged
# selects itself, so this list only names the sources they exercise.
mark_operator() {
  case "$1" in
    .githooks/*|scripts/*|lib/mix/*|dev/*|ptc_viewer/*|docs/guides/*|\
      examples/*|bench/*|test/githooks/*|test/scripts/*|test/mix/*|\
      test/support/*|mix.exs|mix.lock|\
      lib/ptc_runner/kernel.ex|lib/ptc_runner/repl_frontend.ex|\
      lib/ptc_runner/dotenv.ex|lib/ptc_runner/build_identity.ex|\
      lib/ptc_runner/kernel/command_*|lib/ptc_runner/kernel/repl_*|\
      lib/ptc_runner/kernel/viewer_*|lib/ptc_runner/kernel/mix_command_*|\
      lib/ptc_runner/kernel/standalone_*|lib/ptc_runner/kernel/project_*|\
      lib/ptc_runner/kernel/doctor_*|lib/ptc_runner/kernel/cli_*|\
      lib/ptc_runner/kernel/manifest_repl*|lib/ptc_runner/kernel/inspect_only_repl.ex|\
      lib/ptc_runner/kernel/one_shot_frontend.ex|lib/ptc_runner/kernel/transcript_frontend.ex|\
      lib/ptc_runner/kernel/trace_log.ex|lib/ptc_runner/kernel/inspection_preflight.ex|\
      lib/ptc_runner/kernel/inspection_lab*|lib/ptc_runner/kernel/application.ex|\
      lib/ptc_runner/kernel/example_*|lib/ptc_runner/kernel/tutorial_*|\
      lib/ptc_runner/kernel/prelude_search*|lib/ptc_runner/kernel/*_catalog.ex)
      operator=true
      ;;
    test/*_test.exs)
      if [ -f "$repo_root/$1" ] && grep -q '@moduletag :operator' "$repo_root/$1"; then
        operator=true
      fi
      ;;
  esac
}

# `release` is not a gate of its own either: it decides whether the release
# verification gate runs on a pull request. That gate builds the Hex package
# and assembles the standalone release from cold, and only the packaging
# inputs below can change its verdict in a way the core suite does not already
# catch. It stays unconditional on main and on a `release`-labelled pull
# request, so a pure `lib/` change is still verified before a tag.
mark_release() {
  case "$1" in
    mix.exs|mix.lock|rel/*|priv/*|Dockerfile|.dockerignore|\
      scripts/verify_*.sh|scripts/package_standalone_release.sh|\
      scripts/build_container_image.sh|scripts/macho_closure.py|\
      scripts/ci/core-release.sh)
      release=true
      ;;
  esac
}

registry_valid=true

if [ ! -f "$executable_guides" ] || ! awk '
  /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
  /^[[:space:]]/ || /[[:space:]]$/ || /^\// || /\\/ || /\/\// || /\/$/ || \
    /(^|\/)\.(\/|$)/ || /(^|\/)\.\.(\/|$)/ { exit 1 }
' "$executable_guides"; then
  registry_valid=false
fi

while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  saw_path=true

  if [ "$registry_valid" = false ]; then
    select_all
    continue
  fi

  mark_operator "$path"
  mark_release "$path"

  if grep -Fxq -- "$path" "$executable_guides"; then
    core=true
    docs=true
    operator=true
    continue
  fi

  case "$path" in
    docs/plans/*|Plans/*|.claude/*)
      # Disposable plans and agent tooling do not participate in product or
      # documentation gates.
      ;;

    docs/function-reference.md|docs/java-interop.md|docs/kernel-limits-reference.md|\
      docs/prelude-reference.md|docs/conformance/*)
      # These files are generated. The core gate verifies their sources.
      core=true
      docs=true
      ;;

    site/schemas/mcp-*.schema.json)
      # Published rather than shipped, but not documentation-only: the core
      # suite validates the requests PtcRunner actually sends against these
      # definitions, so an edit here can break `core` and not just the site.
      core=true
      docs=true
      ;;

    docs/*|README.md|CHANGELOG.md|LICENSES/*|ptc_runner_launcher/README.md|\
      ptc_runner_launcher/CHANGELOG.md|ptc_viewer/README.md|ptc_viewer/CHANGELOG.md|\
      AGENTS.md|CLAUDE.md|usage-rules.md|.env.example|.lycheeignore|\
      .gitattributes|cliff.toml|REUSE.toml|site/*|dev/*)
      docs=true
      ;;

    ptc_runner_launcher/*)
      launcher=true
      ;;

    ptc_gateway/*)
      core=true
      ;;

    ptc_viewer/*)
      # The Viewer ships inside the standalone release, and the core release
      # gate starts it and serves a trace through it, so a Viewer change can
      # break `core` and not only its own suite.
      core=true
      viewer=true
      ;;

    test/support/ptc_fs_mcp.ex|\
      test/ptc_runner/kernel/filesystem_mcp_e2e_test.exs|\
      test/ptc_runner/kernel/named_missions_authority_e2e_test.exs|\
      test/ptc_runner/kernel/ptc_fs_mcp_stdio_test.exs)
      mcp_filesystem=true
      ;;

    examples/named-mission-reader-writer/ptc-host.json|\
      scripts/labs/viewer-demo/ptc-host.json|\
      examples/kernel-tutorial/ptc-host.json|\
      scripts/labs/inspection-lab/support/lab.exs)
      core=true
      mcp_filesystem=true
      ;;

    examples/*|scripts/labs/*|bench/*)
      core=true
      ;;

    test/support/mcp_go_stateless/*|test/ptc_runner/kernel/mcp_remote_e2e_test.exs)
      mcp_http=true
      ;;

    lib/ptc_runner/lisp/*|test/ptc_runner/lisp/*|\
      test/ptc_runner/lisp_test.exs|test/support/clojure_test_helpers.ex|\
      test/support/lisp_*|priv/java_*|priv/preludes/*|priv/function_audit.exs|\
      priv/functions.exs)
      core=true
      java=true
      mcp_filesystem=true
      ;;

    lib/ptc_runner/kernel/mcp_*|lib/ptc_runner/kernel/host_*|\
      lib/ptc_runner/kernel/provider*|lib/ptc_runner/kernel/capability.ex|\
      lib/ptc_runner/kernel/manifest.ex|test/ptc_runner/kernel/mcp_*|\
      test/ptc_runner/kernel/host_*|test/ptc_runner/kernel/provider_*|\
      test/ptc_runner/kernel/capability_*|test/ptc_runner/kernel/manifest_test.exs|\
      test/support/mcp_*)
      core=true
      mcp_http=true
      mcp_filesystem=true
      ;;

    priv/schemas/*)
      core=true
      mcp_filesystem=true
      ;;

    mix.exs)
      # The root project file carries the launcher's version requirement and
      # the Java oracle's Mix task wiring, so keep the fail-safe here.
      select_all
      ;;

    mix.lock)
      # A root lockfile change rebuilds the library and everything embedding
      # it, but it cannot reach `ptc_runner_launcher` -- a separate Mix project
      # with its own mix.exs and mix.lock -- nor the Java oracle, a pinned JVM
      # Clojure installed by `mix ptc.install_clojure`. Half the lockfile
      # fan-outs in a fortnight were dependabot bumps of ex_doc, usage_rules
      # and dialyxir, each of which ran the macOS launcher matrix.
      core=true
      viewer=true
      docs=true
      mcp_http=true
      mcp_filesystem=true
      ;;

    lib/*|test/*|config/*|priv/*)
      core=true
      ;;

    .github/workflows/test.yml|.github/actions/setup-elixir/*|\
      scripts/ci/classify-changes.sh|scripts/ci/_common.sh)
      # The PR workflow, the shared Elixir setup, and the classifier itself
      # can change which jobs run. Keep the fail-safe: exercise every scope.
      select_all
      ;;

    .github/workflows/nightly.yml|.github/workflows/soak.yml|\
      .github/workflows/flake-hunt.yml|.github/workflows/e2e.yml|\
      .github/workflows/pages.yml|.github/dependabot.yml)
      # Scheduled or deploy-only workflows are not a per-push product gate.
      # Editing them must not spend minutes on core tests, Dialyzer, or
      # release; GitHub still parses the YAML when that workflow next runs.
      ;;

    .github/workflows/launcher-release.yml|.github/workflows/launcher-publish.yml)
      launcher=true
      ;;

    .github/workflows/release.yml|.github/workflows/container-release.yml|\
      .github/workflows/hex-publish.yml|scripts/build_hex_docs.exs|\
      scripts/hex_docs_artifact.ex)
      core=true
      ;;

    scripts/publish_hex_artifact.sh)
      core=true
      launcher=true
      ;;

    scripts/ci/docs.sh|scripts/build_site.sh)
      docs=true
      ;;

    scripts/ci/launcher.sh|scripts/ci/launcher-package.sh)
      launcher=true
      ;;

    scripts/ci/viewer.sh)
      core=true
      viewer=true
      ;;

    scripts/build_og_cards.py)
      # Renders the link-preview cards under `site/og/` from `site/style.css`
      # and the site mark. Nothing it touches reaches a product gate.
      docs=true
      ;;

    scripts/duplication_gate.py|scripts/guide_budget.py|\
      scripts/macho_closure.py|scripts/project-plt-cache.py)
      # The bodies behind duplication_gate.sh, guide_budget.sh, the packaged
      # macOS closure check, and the Dialyzer PLT cache.
      core=true
      ;;

    scripts/ci/*|scripts/verify_*.sh|scripts/package_standalone_release.sh|\
      scripts/build_container_image.sh|scripts/duplication_gate.sh|\
      scripts/worktree.sh|scripts/install-hooks.sh)
      core=true
      ;;

    .githooks/README.md)
      docs=true
      ;;

    .githooks/*|.formatter.exs|.credo.exs|.dialyzer_ignore.exs)
      core=true
      ;;

    .github/*|scripts/*|.tool-versions|mise.toml)
      select_all
      ;;

    .duplication-baseline.json|.ex_dna.exs|conformance_inventory.json|\
      Dockerfile|.dockerignore|rel/*)
      core=true
      ;;

    .gitignore|LICENSE*)
      docs=true
      ;;

    *)
      select_all
      ;;
  esac
done < "$paths_file"

# An empty diff is unusual (for example, a manually re-run merge commit). Run
# everything instead of treating it like a plan-only change.
if [ "$saw_path" = false ]; then
  select_all
fi

printf 'core=%s\n' "$core"
printf 'launcher=%s\n' "$launcher"
printf 'mcp_http=%s\n' "$mcp_http"
printf 'mcp_filesystem=%s\n' "$mcp_filesystem"
printf 'java=%s\n' "$java"
printf 'viewer=%s\n' "$viewer"
printf 'docs=%s\n' "$docs"
printf 'release=%s\n' "$release"
printf 'operator=%s\n' "$operator"
