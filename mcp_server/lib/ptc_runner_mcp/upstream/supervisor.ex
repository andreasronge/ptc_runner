defmodule PtcRunnerMcp.Upstream.Supervisor do
  @moduledoc """
  Top-level supervisor for the upstream subsystem.

  Per `Plans/ptc-runner-mcp-aggregator.md` §4.2 / §4.3 / §4.4:

    * `:one_for_one` over per-name `Upstream.Connection` workers.
      Each Connection owns one impl (Fake or Stdio) and serializes
      `ensure_started/1` for ITS name; cross-name cold starts run
      concurrently because each Connection has its own mailbox
      (§4.4).
    * Children are lazy-spawned at the IMPL level: a Connection is
      started up-front in `:not_started` state; the impl
      subprocess / Fake instance starts on the first
      `(tool/mcp-call ...)` invocation that targets it.

  ## Children

    * `Upstream.Fake.child_spec_for_registry/0` — Elixir Registry for
      the Fake impl's named GenServers.
    * `Upstream.Connection.child_spec_for_registry/0` — Elixir
      Registry for per-name Connection lookup (used by the routing
      layer).
    * `DynamicSupervisor` — owns the Connection processes; the
      routing Registry adds/removes children via `start_child/2` /
      `terminate_child/2` for `put_fake/2` and bootstrap.
    * `PtcRunnerMcp.Upstream.Registry` — the routing GenServer; it
      starts each configured upstream's Connection at boot.
  """

  use Supervisor

  alias PtcRunnerMcp.Upstream

  @doc """
  Starts the upstream supervisor.

  Accepts `:upstreams` (forwarded to `Upstream.Registry.start_link/1`).
  Production aggregator-mode startup builds the list from the JSON
  config; tests pass an empty list and use `Registry.put_fake/2`.
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
      Upstream.Stdio.child_spec_for_registry(),
      Upstream.Connection.child_spec_for_registry(),
      {DynamicSupervisor,
       name: PtcRunnerMcp.Upstream.DynamicSupervisor,
       strategy: :one_for_one,
       max_restarts: 5,
       max_seconds: 30},
      {Upstream.Registry, [upstreams: upstreams]}
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 5, max_seconds: 30)
  end
end
