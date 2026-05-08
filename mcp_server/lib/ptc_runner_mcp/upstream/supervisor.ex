defmodule PtcRunnerMcp.Upstream.Supervisor do
  @moduledoc """
  Top-level supervisor for the upstream subsystem.

  Per `Plans/ptc-runner-mcp-aggregator.md` §4.2 / §4.3 / §4.4:

    * `:rest_for_one` strategy with the inner `DynamicSupervisor`
      listed BEFORE the routing `Registry`. Connections are
      `:one_for_one` children of the inner DynamicSupervisor, so a
      single Connection crash does NOT cascade to siblings. But when
      the inner DynamicSupervisor exhausts its OWN restart-intensity
      budget (e.g. a Connection child crashing in a tight loop),
      `:rest_for_one` restarts the Registry too — the Registry
      then re-bootstraps configured Connection children against
      the fresh DynamicSupervisor. Codex review of `eaaccdc`
      (§16, Phase 1b polish #1) flagged that the previous
      `:one_for_one` outer strategy left Registry alive with stale
      state pointing at the dead DynamicSupervisor; every routed
      lookup after the cascade returned nil.
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

    # `:rest_for_one` so a DynamicSupervisor restart-intensity
    # exhaustion cascades to Registry; Registry's `init/1` then
    # re-bootstraps configured Connection children clean against
    # the fresh DynamicSupervisor (§4.4 / §12.4.1 finding #1).
    # Order matters: DynamicSupervisor MUST be listed before
    # Registry above so Registry is what `:rest_for_one` restarts.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 30)
  end
end
