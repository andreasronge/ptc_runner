# Tracked git hooks

Run `./scripts/install-hooks.sh` once per clone. The installed hooks are small
wrappers around the tracked implementations in this directory, so hook updates
take effect without reinstalling them.

The pre-push hook classifies the pushed and dirty paths, then runs the relevant
root, Viewer, launcher, or documentation gates. Plan-only changes skip the
expensive gate. Unknown paths select every gate, and
`FORCE_FULL_PRE_PUSH=1` explicitly forces the complete gate.

For an ordinary push, run `git push` and let the hook execute the complete gate
once. Run `mix prepush` directly only to diagnose that portion of the gate or
when hooks are unavailable; do not run it immediately before a normal
`git push`.

Fresh clones should run `mix deps.get && mix deps.compile` in the projects they
intend to change before the first push.
