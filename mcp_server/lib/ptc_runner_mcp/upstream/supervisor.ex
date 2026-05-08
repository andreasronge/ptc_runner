defmodule PtcRunnerMcp.Upstream.Supervisor do
  @moduledoc """
  Top-level supervisor for the upstream subsystem.

  Per `Plans/ptc-runner-mcp-aggregator.md` §4.2 / §4.3:

    * `:one_for_one` over Connection processes; exponential backoff
      cap 30 s on restart. Phase 1a uses `:permanent` Fake GenServers
      under a `DynamicSupervisor`; Phase 1b will swap in stdio
      `Port`-driven Connection processes against the same shape.
    * Children are lazy-spawned: a configured upstream is started
      on the first `(tool/mcp-call ...)` invocation that targets
      it, not at MCP server startup.

  ## Children

    * `Registry` — Elixir's standard Registry, used by
      `Upstream.Fake` to register named GenServers under
      `PtcRunnerMcp.Upstream.Fake.Names`.
    * `DynamicSupervisor` — owns the upstream Connection processes
      (Fake GenServers in Phase 1a, Stdio Ports in Phase 1b).
    * `PtcRunnerMcp.Upstream.Registry` — the routing GenServer
      (per-name `ensure_started/1` lock).
  """

  use Supervisor

  alias PtcRunnerMcp.Upstream

  @doc """
  Starts the upstream supervisor.

  Accepts `:upstreams` to bootstrap the routing table (forwarded to
  `Upstream.Registry.start_link/1`). Production aggregator-mode
  startup builds the list from the JSON config; tests pass an empty
  list and use the Registry test API.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    upstreams = Keyword.get(opts, :upstreams, [])

    children = [
      Upstream.Fake.child_spec_for_registry(),
      {DynamicSupervisor, name: PtcRunnerMcp.Upstream.DynamicSupervisor, strategy: :one_for_one},
      {Upstream.Registry, [upstreams: upstreams]}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
  end
end
