# Phase 6 integration tests live under `test/integration/` and are
# tagged `:integration` (often with a sub-tag like `:release`,
# `:inspector`, or `:cross_language`). They drive the built release
# binary as an external subprocess and require
# `MIX_ENV=prod mix release --overwrite` to have run first. They are
# excluded from the default `mix test` run; opt in with
# `mix test --only integration` or `--include integration`.
ExUnit.start(exclude: [:integration])

# Default tests to a quiet logger; individual tests that exercise
# stderr emission can `PtcRunnerMcp.Log.set_level/1` themselves.
PtcRunnerMcp.Log.set_level(:error)

# Phase 1a aggregator: the in-process `Upstream.Fake` registers each
# fake GenServer under `{:via, Registry, {PtcRunnerMcp.Upstream.Fake.Names, name}}`.
# Production aggregator-mode startup spins this up via
# `Upstream.Supervisor.init/1`; tests bypass the supervisor (each
# test starts its own `Upstream.Registry` GenServer with a unique
# name) so we start the names Registry once here, globally.
case Process.whereis(PtcRunnerMcp.Upstream.Fake.Names) do
  nil ->
    {:ok, _} = Registry.start_link(keys: :unique, name: PtcRunnerMcp.Upstream.Fake.Names)

  _pid ->
    :ok
end
