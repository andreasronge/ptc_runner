# Tracked git hooks

Run `./scripts/install-hooks.sh` once per clone. The pre-push hook runs tests
and Dialyzer for the root project and `ptc_viewer`; plan-only changes may take
the documented fast path. Set `FORCE_FULL_PRE_PUSH=1` to force the complete
gate.

Fresh clones should run `mix deps.get && mix deps.compile` in the root and
`ptc_viewer` before the first push.
