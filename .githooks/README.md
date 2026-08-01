# Tracked git hooks

Run `./scripts/install-hooks.sh` once per clone. The installed hooks are small
wrappers around the tracked implementations in this directory, so hook updates
take effect without reinstalling them.

The pre-push hook classifies the pushed and dirty paths, then runs the relevant
root, Viewer, launcher, or documentation gates. For mixed documentation and
code changes, ExDoc runs before the longer test and Dialyzer stages. Plan-only
changes skip the expensive gate. Unknown paths select every gate, and
`FORCE_FULL_PRE_PUSH=1` explicitly forces the complete gate.

For an ordinary push, run `git push` and let the hook execute the complete gate
once. Run `mix prepush` directly only to diagnose that portion of the gate or
when hooks are unavailable; do not run it immediately before a normal
`git push`.

Fresh clones and worktrees should follow the bootstrap commands in `AGENTS.md`.
Linked worktrees share installed hook wrappers but keep their own build and
Dialyzer PLT directories.

If the full suite is starved by local scheduler pressure, use a positive
integer concurrency limit without skipping any gate:

```console
PTC_PRE_PUSH_MAX_CASES=2 git push
```

The hook rejects invalid limits. A test that still fails at lower concurrency
is a real failure to diagnose, not a reason to bypass the hook.
