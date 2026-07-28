#!/usr/bin/env bash

# Classify repository-relative changed paths into independently testable scopes.
# Unknown paths deliberately select every scope so new repository areas cannot
# silently bypass CI. The same classifier is suitable for CI and local hooks.

set -euo pipefail

paths_file="${1:-/dev/stdin}"

core=false
launcher=false
mcp_http=false
mcp_filesystem=false
java=false
viewer=false
docs=false
saw_path=false

select_all() {
  core=true
  launcher=true
  mcp_http=true
  mcp_filesystem=true
  java=true
  viewer=true
  docs=true
}

while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  saw_path=true

  case "$path" in
    docs/plans/*|Plans/*)
      # Disposable plans do not participate in product or documentation gates.
      ;;

    docs/function-reference.md|docs/java-interop.md|docs/conformance/*)
      # These files are generated. The core gate verifies their sources.
      core=true
      docs=true
      ;;

    docs/*|README.md|CHANGELOG.md|LICENSES/*|ptc_runner_launcher/README.md|\
      ptc_runner_launcher/CHANGELOG.md|ptc_viewer/README.md|ptc_viewer/CHANGELOG.md)
      docs=true
      ;;

    ptc_runner_launcher/*)
      launcher=true
      ;;

    ptc_viewer/*)
      viewer=true
      ;;

    examples/mcp/filesystem/*|test/ptc_runner/kernel/filesystem_mcp_e2e_test.exs)
      mcp_filesystem=true
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

    mix.exs|mix.lock)
      select_all
      ;;

    lib/*|test/*|config/*|priv/*)
      core=true
      ;;

    .github/workflows/test.yml|.github/actions/setup-elixir/*|\
      scripts/classify_changes.sh)
      select_all
      ;;

    .github/*|scripts/*|.githooks/*|.formatter.exs|.credo.exs|\
      .dialyzer_ignore.exs|.tool-versions)
      select_all
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
