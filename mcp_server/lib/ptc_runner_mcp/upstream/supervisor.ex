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

  alias PtcRunnerMcp.Log
  alias PtcRunnerMcp.Upstream
  alias PtcRunnerMcp.Upstream.{Catalog, Connection, Registry}

  # §12.5.1 budget-warn threshold for eager-start at boot. Cumulative
  # ensure_started wall-clock above this number logs a warning so
  # operators notice when their upstreams collectively dominate boot
  # time. Boot is not blocked indefinitely — each Connection's own
  # `handshake_timeout_ms` is the per-upstream cap; this just flags
  # the aggregate.
  @eager_start_warn_ms 5_000

  @doc """
  Starts the upstream supervisor.

  Accepts `:upstreams` (forwarded to `Upstream.Registry.start_link/1`).
  Production aggregator-mode startup builds the list from the JSON
  config; tests pass an empty list and use `Registry.put_fake/2`.

  ## Eager catalog fetch (§12.5.1)

  After the Registry and DynamicSupervisor come up, this supervisor
  eagerly calls `Connection.ensure_started/1` against every
  configured upstream so each Connection's `cached_tools` is
  populated before the first `tools/list` request arrives from a
  client (the catalog is rendered from those caches).

  **Deviation from §4.3 lazy-spawn:** §12.5 requires the catalog
  to be populated at boot from each upstream's cached tools/list.
  We eagerly ensure_started here so the description rendered in
  tools/list reflects all configured upstreams. Failures at boot
  are non-fatal — they are rendered as "(unavailable at startup)"
  in the catalog, and the upstream is re-attempted on first call
  per §4.3 backoff.

  Boot is sequential across upstreams (cross-name parallelism is
  available via Connection workers per §4.4, but spawning N
  subprocesses in parallel during boot would amplify resource
  contention if the host is constrained). Total boot wall-clock is
  approximately the sum of each upstream's `handshake_timeout_ms`;
  if the cumulative cost exceeds `#{@eager_start_warn_ms}` ms we
  log a warning so the operator can investigate.

  ## Catalog freeze (§12.5)

  After `eager_start_upstreams/1` completes, the supervisor renders
  the catalog from the now-populated cached_tools snapshots and
  freezes the resulting string into `:persistent_term` via
  `Catalog.freeze/1`. `Tools.tool_entry/0` reads the frozen string
  on every `tools/list` request — it does NOT recompute. This
  satisfies §12.5's "rebuilt only on PtcRunner restart" contract:
  upstream crashes, recoveries, and `put_fake/2` mid-life calls
  do NOT change what `tools/list` returns.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case Supervisor.start_link(__MODULE__, opts, name: name) do
      {:ok, _pid} = ok ->
        eager_start_upstreams(opts)
        freeze_catalog(opts)
        ok

      other ->
        other
    end
  end

  @doc """
  §12.5: render the catalog once and freeze it into
  `:persistent_term`. Called from `start_link/1` immediately after
  `eager_start_upstreams/1` so the rendered text reflects every
  Connection's just-populated `cached_tools` snapshot.

  Public so tests can drive the freeze step against a test-owned
  routing Registry without going through the full production
  supervisor tree.

  Defensive `try/rescue` so a render bug never breaks supervisor
  boot — the worst case is `Catalog.frozen/0` returning `""` and
  the description omitting the catalog block, which
  `Tools.advertised_description/2` already handles cleanly.
  """
  @spec freeze_catalog(keyword()) :: :ok
  def freeze_catalog(opts) do
    upstreams = Keyword.get(opts, :upstreams, [])
    registry = Keyword.get(opts, :registry_name, Registry)

    if upstreams == [] do
      Catalog.freeze("")
    else
      catalog =
        try do
          Catalog.render(registry)
        rescue
          e ->
            Log.log(:warn, "catalog_freeze_render_failed", %{
              error: Exception.message(e)
            })

            ""
        catch
          :exit, reason ->
            Log.log(:warn, "catalog_freeze_render_exit", %{
              reason: inspect(reason, limit: 50)
            })

            ""
        end

      Catalog.freeze(catalog)
    end
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

  @doc """
  §12.5.1: walks the configured upstreams and calls
  `Connection.ensure_started/1` against each one's per-name
  Connection (looked up via the routing Registry). Failures are
  non-fatal and logged at info level — the Connection stays
  `:not_started` and its catalog block renders as
  "(unavailable at startup)".

  Public so tests can exercise the eager-start path against a
  test-owned routing Registry without going through the full
  production supervisor tree (which globally registers the
  `Fake.Names` / `Stdio.Names` / `Connection.Names` Registries that
  `test_helper.exs` already starts once).
  """
  @spec eager_start_upstreams(keyword()) :: :ok
  def eager_start_upstreams(opts) do
    upstreams = Keyword.get(opts, :upstreams, [])
    registry = Keyword.get(opts, :registry_name, Registry)

    if upstreams == [] do
      :ok
    else
      do_eager_start(upstreams, registry)
    end
  end

  defp do_eager_start(upstreams, registry) do
    started_at = System.monotonic_time(:millisecond)

    Enum.each(upstreams, fn %{name: name} ->
      eager_start_one(name, registry)
    end)

    elapsed = System.monotonic_time(:millisecond) - started_at

    if elapsed > @eager_start_warn_ms do
      Log.log(:warn, "upstream_eager_start_slow", %{
        elapsed_ms: elapsed,
        threshold_ms: @eager_start_warn_ms,
        upstream_count: length(upstreams)
      })
    end

    :ok
  end

  defp eager_start_one(name, registry) do
    case Registry.connection_for(name, registry) do
      nil ->
        # Connection failed to register under the routing Registry.
        # This is unusual at boot (Registry.init/1 just started it),
        # but if it happens, log and move on — the catalog will
        # render "(unavailable at startup)".
        Log.log(:warn, "upstream_eager_start_no_connection", %{name: name})
        :ok

      pid ->
        case Connection.ensure_started(pid) do
          {:ok, _meta} ->
            :ok

          {:error, :upstream_unavailable, detail, _meta} ->
            Log.log(:info, "upstream_eager_start_failed", %{
              name: name,
              detail: detail
            })

            :ok
        end
    end
  catch
    # Defensive: if the Connection process dies between `connection_for`
    # and `ensure_started/1` we still want the supervisor to come up.
    # Same fall-through as the {:error, ...} path above.
    :exit, reason ->
      Log.log(:info, "upstream_eager_start_exit", %{
        name: name,
        reason: inspect(reason, limit: 50)
      })

      :ok
  end
end
