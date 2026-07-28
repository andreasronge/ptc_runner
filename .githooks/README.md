# Tracked git hooks

Run `./scripts/install-hooks.sh` once per clone. The pre-push hook runs the root
and `ptc_viewer` tests, then invokes the root `mix prepush` alias for the
upstream audit, Dialyzer, and unused-dependency check. Plan-only changes may
take the documented fast path. Set `FORCE_FULL_PRE_PUSH=1` to force the
complete gate.

For an ordinary push, run `git push` and let the hook execute the complete gate
once. Run `mix prepush` directly only to diagnose that portion of the gate or
when hooks are unavailable; do not run it immediately before a normal
`git push`.

Fresh clones should run `mix deps.get && mix deps.compile` in the root and
`ptc_viewer` before the first push.
