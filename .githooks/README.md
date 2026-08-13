# Tracked git hooks

Run `./scripts/install-hooks.sh` once per clone. The installed hooks are small
wrappers around the tracked implementations in this directory, so hook updates
take effect without reinstalling them.

The pre-push hook classifies the pushed and dirty paths, then invokes the same
repository-owned root, Viewer, launcher, release, or documentation entry
points as GitHub Actions. For mixed documentation and code changes, ExDoc runs
before the longer test and Dialyzer stages. Plan-only changes skip the
expensive gate. Unknown paths select every gate, and
`FORCE_FULL_PRE_PUSH=1` explicitly forces the complete gate.

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
