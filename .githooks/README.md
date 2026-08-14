# Tracked git hooks

Run `./scripts/install-hooks.sh` once per clone. The installed hooks are small
wrappers around the tracked implementations in this directory, so hook updates
take effect without reinstalling them.

The pre-push hook classifies the pushed and dirty paths, then invokes the same
repository-owned root, Viewer, launcher, release, or documentation entry
points as GitHub Actions. Plan-only changes skip the expensive gate. Unknown
paths select every gate, and `FORCE_FULL_PRE_PUSH=1` explicitly forces the
complete gate.

The selected gates run concurrently, so a push costs the slowest gate rather
than the sum of all of them. Every gate still runs exactly the same commands;
only their scheduling differs. On four cores a warm tree measured 311 s
sequentially and 201 s concurrently.

This is safe because no two gates write the same artifact, and the one thing
several of them share — `_build/test` — is guarded by Mix, which serialises
concurrent builds of a build directory behind its own lock. It is also cheap,
because no gate saturates a developer machine: three quarters of the core
suite is `async: false`, so the longest gate runs at little more than one core
while the rest idle.

How many run at once is budgeted against RAM rather than cores — roughly one
gate per 4 GB, never more than one per core — because Dialyzer, the release
build and the clone detector each hold gigabytes and a swapping BEAM is slower
than a gate that waited its turn. A machine too small for two gates runs them
one at a time, exactly as before. Gates are queued longest-first, since the
last one to start decides when the push ends.

Concurrent output would be unreadable interleaved, so each gate's output is
captured and replayed in full the moment that gate fails; passes and failures
are announced as they happen and summarised as phase timings at the end. A
failing gate does not cancel the others — killing a release assembly or a
Dialyzer PLT write mid-flight would leave broken build state behind — so one
push reports every failure it found instead of one per attempt.

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
