# Tracked git hooks

Run `./scripts/install-hooks.sh` once per clone. The installed hooks are small
wrappers around the tracked implementations in this directory, so hook updates
take effect without reinstalling them.

The pre-commit hook is the fast path: it runs format, compile, and credo
only when staged Elixir, config, or Mix files belong to a project, and it
passes those staged `.ex`/`.exs` paths to format and credo so a one-file
commit does not analyze the whole tree. Credo consistency checks that compare
the whole project therefore wait for `mix precommit` and pre-push. Compile
stays project-wide because Mix is incremental and `--warnings-as-errors` has
to see the build.
Scoped tests run only for staged `*_test.exs` files, with `:slow` excluded.

The pre-push hook classifies the pushed and dirty paths, then invokes the same
repository-owned root, Viewer, launcher, release, or documentation entry
points as GitHub Actions. For mixed documentation and code changes, ExDoc runs
before the longer test and Dialyzer stages. Plan-only changes skip the
expensive gate. Unknown paths select every gate, and
`FORCE_FULL_PRE_PUSH=1` explicitly forces the complete gate.

After the test suite, the deterministic gates run as concurrent lanes, because
they own disjoint build trees: core static analysis followed by Dialyzer
(`_build/test`), release verification (`_build/prod`), and the Viewer
(`ptc_viewer/_build/test`). Each lane's output is buffered and replayed under
its own heading once it finishes, so a concurrent run reads like a serial one
and every lane is reported even when an earlier one fails.

The test suite and the launcher gate deliberately do not share the machine.
Both own load-sensitive assertions, and a gate that flakes costs more than a
gate that is slow. Set `PTC_PRE_PUSH_SERIAL=1` to run every gate serially when
diagnosing a failure or pushing from a machine too small to overlap them.

For an ordinary push, run `git push` and let the hook execute the complete gate
once. "Complete" excludes `:nightly` tests, which cost tens of seconds each and
run in the `Nightly` workflow instead; everything else runs. Run `mix prepush` directly only to diagnose that portion of the gate or
when hooks are unavailable; do not run it immediately before a normal
`git push`.

Fresh clones and worktrees should follow the bootstrap commands in `AGENTS.md`.
Linked worktrees share installed hook wrappers but keep their own build and
Dialyzer PLT directories.

The core test entry point sets `CI=1` but uses the project's scheduler-count
ExUnit concurrency. Do not reduce that pressure to make a failing push pass;
reproduce the reported seed and fix the load-sensitive test instead. For a
second, lower-concurrency signal, run `scripts/ci/core-tests.sh --schedulers 4`.
