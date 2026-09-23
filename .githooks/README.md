# Tracked git hooks

Run `./scripts/install-hooks.sh` once per clone. The installed hooks are small
wrappers around the tracked implementations in this directory, so hook updates
take effect without reinstalling them.

The pre-commit hook is the fast path: it runs format, compile, and credo
only when staged Elixir, config, or Mix files belong to a project, and it
passes those staged `.ex`/`.exs` paths to format and credo so a one-file
commit does not analyze the whole tree. Nested launcher sources are kept off
the root format and credo argument lists — those configs never included them,
and an explicit path would apply the wrong rules — while a staged
`.formatter.exs` or `.credo.exs` still runs that checker unscoped. Credo
consistency checks that compare the whole project therefore wait for
`mix precommit` and pre-push unless the Credo config itself changed. Compile
stays project-wide because Mix is incremental and `--warnings-as-errors` has
to see the build.
Scoped tests run only for staged `*_test.exs` files, with `:slow` excluded.
The Viewer and gateway each use their own project formatter and compiler.

The pre-push hook classifies the pushed and dirty paths, then invokes the
repository-owned root, Viewer, launcher, or documentation entry points. The
required pull-request CI also runs release-package verification in parallel;
ordinary local pushes leave that production build to CI. The core static gate
also runs the sibling gateway format, compile, and test gate, including its
short startup CLI smoke test.
Plan-only changes skip the
expensive gate. Scheduled workflows (`nightly.yml`, `soak.yml`, `e2e.yml`,
`pages.yml`) and other paths that cannot break a product gate select none.
Unknown paths select every path-routed local gate.
`FORCE_FULL_PRE_PUSH=1` explicitly adds release verification and forces all
path scopes; release preparation uses this mode.

The suite runs in one of two lanes. A push that touches none of the
operator surfaces (Mix tasks, hooks, scripts, Viewer, guides, examples, and
the command and REPL front ends that drive them) runs the library lane,
`mix test --exclude operator`; the excluded modules carry
`@moduletag :operator` and select themselves when edited. Any operator
surface, a forced full run, or an unknown path runs every module, as CI
always does.

After the test suite, the deterministic local gates run as concurrent lanes,
because they own disjoint build trees: core static analysis followed by
Dialyzer (`_build/test`), the Viewer (`ptc_viewer/_build/test`), and ExDoc
(`_build/dev`). A forced full run adds release verification (`_build/prod`)
as another lane. Core static analysis begins with the same quality gate as
`mix precommit`; a clean tree that gate has already passed is stamped under
`_build/test` and skipped, so running `mix precommit` before `git push` costs
the gate once (`PTC_QUALITY_FORCE=1` reruns it). Each lane's
output is buffered and replayed under its own heading once it finishes, so a
concurrent run reads like a serial one and every lane is reported even when an
earlier one fails.

The test suite and the launcher gate deliberately do not share the machine.
Both own load-sensitive assertions, and a gate that flakes costs more than a
gate that is slow. Set `PTC_PRE_PUSH_SERIAL=1` to run every gate serially when
diagnosing a failure or pushing from a machine too small to overlap them. A
managed push (`PTC_MANAGED_OPERATION_CONTEXT` set) runs its memory-bounded
operation serially by default; `PTC_PRE_PUSH_SERIAL=0` restores concurrent
lanes there.

For an ordinary push, run `git push` and let the hook execute the local gate
once. Root `:nightly` tests, which spawn Mix/OS processes or wait on
multi-second deadlines, run in the `Nightly` workflow; release-package
verification runs in required pull-request CI. `mix precommit` is the quality
gate (nested fetch plus format, compile, credo, duplication, spec, and
generated-artifact checks). It does not run the suite, Viewer, launcher,
Dialyzer, or ExDoc — those belong here. Do not run `mix precommit` and then
`git push --no-verify`: pre-push still adds Dialyzer and ExDoc. `git push --no-verify` skips this
hook entirely (Git never execs it). `git push --dry-run` still runs the hook
— dry-run only skips sending refs. Run `mix prepush` directly only to
diagnose static analysis or Dialyzer, or when hooks are unavailable; do not
run it immediately before a normal `git push`.

Fresh clones and worktrees should follow the bootstrap commands in `AGENTS.md`.
Linked worktrees share installed hook wrappers but keep their own build and
Dialyzer PLT directories.

The core test entry point sets `CI=1` but uses the project's scheduler-count
ExUnit concurrency. Do not reduce that pressure to make a failing push pass;
reproduce the reported seed and fix the load-sensitive test instead. For a
second, lower-concurrency signal, run `scripts/ci/core-tests.sh --schedulers 4`.

PtcManager owns managed worktree lifetimes. Managed pre-push runs retain every
quality gate and skip the final advisory worktree garbage collection.
