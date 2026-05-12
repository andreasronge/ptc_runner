# Phase 6 integration tests live under `test/integration/` and are
# tagged `:integration` (often with a sub-tag like `:release`,
# `:inspector`, or `:cross_language`). They drive the built release
# binary as an external subprocess and require
# `MIX_ENV=prod mix release --overwrite` to have run first. They are
# excluded from the default `mix test` run; opt in with
# `mix test --only integration` or `--include integration`.
#
# Phase 2.2 (`Plans/ptc-runner-mcp-aggregator.md` §12.4.2) adds
# `:real_upstream` for tests that spawn an actual upstream MCP server
# subprocess (e.g. `@modelcontextprotocol/server-filesystem` via
# `npx`). Excluded by default; opt in with
# `MCP_REAL_UPSTREAM=1 mix test --include real_upstream`.
ExUnit.start(exclude: [:integration, :real_upstream, :real_remote_upstream])

# Default tests to a quiet logger; individual tests that exercise
# stderr emission can `PtcRunnerMcp.Log.set_level/1` themselves.
PtcRunnerMcp.Log.set_level(:error)

# Most historical MCP tests assert the original verbose envelope shape.
# New response-profile tests opt into `:slim` / `:structured` explicitly.
PtcRunnerMcp.ResponseProfile.set(:debug)

# Phase 1a aggregator: the in-process `Upstream.Fake` registers each
# fake GenServer under `{:via, Registry, {PtcRunnerMcp.Upstream.Fake.Names, name}}`.
# Phase 1b adds:
#   * `PtcRunnerMcp.Upstream.Stdio.Names` — global `Registry` for
#     stdio impl GenServers.
#   * `PtcRunnerMcp.Upstream.Connection.Names` — global `Registry`
#     keyed by `{routing_id, upstream_name}` for Connection lookup
#     (codex review of `46b4466` [P2] #2 — Connection pids must
#     resolve via `:via` registration so DynamicSupervisor restarts
#     are observable to the routing layer without pid caching).
#   * `PtcRunnerMcp.Upstream.DynamicSupervisor` for Connection
#     workers.
#
# Production aggregator-mode startup spins all three up via
# `Upstream.Supervisor.init/1`; tests bypass the supervisor (each
# test starts its own `Upstream.Registry` GenServer with a unique
# name) so we start them once here, globally.
case Process.whereis(PtcRunnerMcp.Upstream.Fake.Names) do
  nil ->
    {:ok, _} = Registry.start_link(keys: :unique, name: PtcRunnerMcp.Upstream.Fake.Names)

  _pid ->
    :ok
end

case Process.whereis(PtcRunnerMcp.Upstream.Stdio.Names) do
  nil ->
    {:ok, _} = Registry.start_link(keys: :unique, name: PtcRunnerMcp.Upstream.Stdio.Names)

  _pid ->
    :ok
end

case Process.whereis(PtcRunnerMcp.Upstream.Http.Names) do
  nil ->
    {:ok, _} = Registry.start_link(keys: :unique, name: PtcRunnerMcp.Upstream.Http.Names)

  _pid ->
    :ok
end

case Process.whereis(PtcRunnerMcp.Upstream.Connection.Names) do
  nil ->
    {:ok, _} =
      Registry.start_link(keys: :unique, name: PtcRunnerMcp.Upstream.Connection.Names)

  _pid ->
    :ok
end

case Process.whereis(PtcRunnerMcp.Upstream.DynamicSupervisor) do
  nil ->
    {:ok, _} =
      DynamicSupervisor.start_link(
        name: PtcRunnerMcp.Upstream.DynamicSupervisor,
        strategy: :one_for_one
      )

  _pid ->
    :ok
end
