defmodule PtcRunnerMcp.Upstream.Registry do
  @moduledoc """
  Routing/config table for upstream `Connection` workers.

  Per `Plans/ptc-runner-mcp-aggregator.md` §4.4: Phase 1b splits
  the Phase 1a Registry into a thin routing layer (this module) and
  per-name `Upstream.Connection` GenServers. Cold starts for
  different upstream names therefore proceed concurrently — the
  Phase 1a "global serialization through one Registry mailbox"
  anti-pattern is gone.

  ## Responsibilities

    * `name -> {impl, config}` configured-upstreams catalog.
    * `cached_tools/2` and `started_upstreams/0` forwarders to
      Connections (the per-impl state lives in the Connection).
    * `configured?/2` / `configured_count/1` for the static
      aggregator-mode predicate (§4.1).
    * Test API: `put_fake/2` (replaces a Connection in place).

  ## Connection-pid resolution

  Connections are NOT pid-cached in this Registry's state. They are
  registered under `{:via, Registry, {Connection.Names, {self(), name}}}`
  via `Upstream.Connection.start_link/1`. Routing-layer lookups via
  `Connection.whereis(routing_id, name)` always resolve to the live
  pid — INCLUDING after a `DynamicSupervisor` restart. Codex review
  of `46b4466` flagged that the pre-fix Registry cached the
  pre-restart Connection pid; every routed call after a Connection
  crash hit `:noproc`.

  The `routing_id` used in the via key is `self()` (this Registry
  GenServer's pid), so multiple isolated test Registries do not
  collide on the global `Connection.Names` registry — each test
  Registry hosts its own subspace of `{routing_id, upstream_name}`
  keys.
  """

  use GenServer

  alias PtcRunnerMcp.Upstream
  alias PtcRunnerMcp.Upstream.{Connection, Fake}

  @typedoc "Routing entry as returned by `lookup/2`."
  @type upstream_entry :: %{
          impl: module(),
          config: map(),
          connection_pid: pid() | nil,
          status: :not_started | :started,
          cached_tools: [Upstream.tool_schema()] | nil,
          started_at: DateTime.t() | nil,
          pid: pid() | nil
        }

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc """
  Starts the Registry. Accepts `:upstreams` (a list of
  `%{name: ..., impl: ..., config: ...}` entries used to bootstrap
  the routing table; one Connection is started per entry) and
  `:name` (defaults to `__MODULE__`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the routing entry plus a per-Connection snapshot for
  `name`, or `nil` when the upstream is not configured.

  The snapshot fields (`status`, `cached_tools`, `started_at`,
  `pid`, `connection_pid`) are read through the Connection — the
  Registry itself does not hold them.
  """
  @spec lookup(Upstream.server_name(), atom()) :: upstream_entry() | nil
  def lookup(name, server \\ __MODULE__) when is_binary(name) do
    case GenServer.call(server, {:routing, name}) do
      nil ->
        nil

      %{impl: _, config: _, routing_id: routing_id} = routing ->
        conn_pid = Connection.whereis(routing_id, name)

        snap_or_nil =
          case conn_pid do
            nil -> nil
            pid -> safe_snapshot(pid)
          end

        base = Map.drop(routing, [:routing_id])

        Map.merge(base, %{
          connection_pid: conn_pid,
          status: snapshot_field(snap_or_nil, :status, :not_started),
          cached_tools: snapshot_field(snap_or_nil, :cached_tools, nil),
          started_at: snapshot_field(snap_or_nil, :started_at, nil),
          pid: snapshot_field(snap_or_nil, :pid, nil)
        })
    end
  end

  @doc """
  Returns the live Connection pid for `name`, or `nil` if the
  upstream is not configured. Resolves through `Connection.whereis/2`
  every call — survives `DynamicSupervisor` restarts.
  """
  @spec connection_for(Upstream.server_name(), atom()) :: pid() | nil
  def connection_for(name, server \\ __MODULE__) when is_binary(name) do
    case GenServer.call(server, {:routing, name}) do
      nil -> nil
      %{routing_id: routing_id} -> Connection.whereis(routing_id, name)
    end
  end

  @doc """
  Returns the set of upstream names that are currently `:started`
  (per their Connection's snapshot).

  Per §4.1 / §2: "currently healthy" — the set grows on a
  successful `ensure_started/1` and shrinks when a Connection's
  impl crashes (the Connection observes `:DOWN` and transitions to
  `:not_started`).
  """
  @spec started_upstreams(atom()) :: MapSet.t(Upstream.server_name())
  def started_upstreams(server \\ __MODULE__) do
    GenServer.call(server, :all_routings)
    |> Enum.reduce(MapSet.new(), fn {name, %{routing_id: routing_id}}, acc ->
      case Connection.whereis(routing_id, name) do
        nil ->
          acc

        pid ->
          if safe_started?(pid), do: MapSet.put(acc, name), else: acc
      end
    end)
  end

  @doc """
  Returns the cached `tools/list` for `name` if the Connection is
  currently `:started`. Returns `nil` otherwise. Used by §7.4 to
  prove unknown-tool classification.
  """
  @spec cached_tools(Upstream.server_name(), atom()) :: [Upstream.tool_schema()] | nil
  def cached_tools(name, server \\ __MODULE__) when is_binary(name) do
    case GenServer.call(server, {:routing, name}) do
      nil ->
        nil

      %{routing_id: routing_id} ->
        case Connection.whereis(routing_id, name) do
          nil -> nil
          pid -> safe_cached_tools(pid)
        end
    end
  end

  @doc """
  Returns `true` if `name` is currently configured as an upstream.
  Used to drive the §7.2 programmer-fault classification for
  `:server` values that aren't in the upstreams config.
  """
  @spec configured?(Upstream.server_name(), atom()) :: boolean()
  def configured?(name, server \\ __MODULE__) when is_binary(name) do
    GenServer.call(server, {:configured?, name})
  end

  @doc """
  Returns the count of configured upstreams (regardless of started
  status). Used by `Tools.configured_aggregator_mode?/0` to drive
  the static aggregator-mode predicate per §4.1.
  """
  @spec configured_count(atom()) :: non_neg_integer()
  def configured_count(server \\ __MODULE__) do
    GenServer.call(server, :configured_count)
  end

  @doc """
  Synchronously ensures the upstream `name` is `:started` by
  forwarding to its `Connection`.

  Returns `{:ok, %{duration_ms: ms}}` on success, or
  `{:error, :upstream_unavailable, detail, %{duration_ms: ms}}` on
  failure (per §7.1). The Registry GenServer is bypassed for the
  cold-start work itself — callers go directly to the Connection
  mailbox after looking up its pid via the `Connection.Names` via
  registry, so different names cold-start concurrently per §4.4.
  """
  @spec ensure_started(Upstream.server_name(), atom()) :: Connection.ensure_result()
  def ensure_started(name, server \\ __MODULE__) when is_binary(name) do
    case connection_for(name, server) do
      nil ->
        # `:server` value not in the upstreams config (or its
        # Connection is currently between supervisor restarts).
        # The executor classifies missing-config as programmer-fault
        # (§7.2) BEFORE calling `ensure_started/2`; reaching here
        # for a configured upstream means the supervisor's restart
        # is in flight. Callers retry on the next program.
        detail = "upstream '#{name}' is not configured"
        {:error, :upstream_unavailable, detail, %{duration_ms: 0}}

      pid ->
        Connection.ensure_started(pid)
    end
  end

  # ----------------------------------------------------------------
  # Test API (§5.4)
  # ----------------------------------------------------------------

  @doc """
  Test-only: install a Fake upstream under `name` with the given
  `config` map. Replaces any existing entry — the previous
  Connection is stopped and a fresh one is started.

  Production `Application.start/2` MUST NOT call this function
  (§5.4). Calling it from production code defeats the deploy-safety
  guarantee that "no fake configuration leaks via `Application.get_env`".
  """
  @spec put_fake(Upstream.server_name(), map(), atom()) :: :ok
  def put_fake(name, config \\ %{}, server \\ __MODULE__) when is_binary(name) do
    GenServer.call(server, {:put_fake, name, config})
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # Trap exits so the `terminate/2` callback fires on graceful
    # shutdown — we use it to tear down our Connection children so
    # the next Registry instance (production restart, or a fresh
    # test run) starts from a clean DynamicSupervisor.
    Process.flag(:trap_exit, true)

    sup = Keyword.get(opts, :connection_supervisor, default_connection_supervisor())
    routing_id = self()

    upstreams =
      opts
      |> Keyword.get(:upstreams, [])
      |> Enum.into(%{}, fn entry ->
        %{name: name, impl: impl, config: config} = entry
        {:ok, _pid} = start_connection(sup, routing_id, name, impl, config, self())

        {name,
         %{
           impl: impl,
           config: config,
           routing_id: routing_id
         }}
      end)

    {:ok,
     %{
       upstreams: upstreams,
       connection_supervisor: sup,
       routing_id: routing_id
     }}
  end

  @impl GenServer
  def terminate(_reason, %{
        upstreams: upstreams,
        connection_supervisor: sup,
        routing_id: routing_id
      }) do
    Enum.each(upstreams, fn {name, _entry} ->
      case Connection.whereis(routing_id, name) do
        nil -> :ok
        pid -> _ = maybe_terminate_via_supervisor(sup, pid)
      end
    end)

    :ok
  end

  defp default_connection_supervisor, do: PtcRunnerMcp.Upstream.DynamicSupervisor

  @impl GenServer
  def handle_call({:routing, name}, _from, state) do
    case Map.get(state.upstreams, name) do
      nil -> {:reply, nil, state}
      entry -> {:reply, entry, state}
    end
  end

  def handle_call(:all_routings, _from, state) do
    {:reply, state.upstreams, state}
  end

  def handle_call({:configured?, name}, _from, state) do
    {:reply, Map.has_key?(state.upstreams, name), state}
  end

  def handle_call(:configured_count, _from, state) do
    {:reply, map_size(state.upstreams), state}
  end

  def handle_call({:put_fake, name, config}, _from, state) do
    state = stop_existing_connection(state, name)

    {:ok, _pid} =
      start_connection(state.connection_supervisor, state.routing_id, name, Fake, config, self())

    entry = %{impl: Fake, config: config, routing_id: state.routing_id}

    {:reply, :ok, %{state | upstreams: Map.put(state.upstreams, name, entry)}}
  end

  # ----------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------

  defp start_connection(sup, routing_id, name, impl, config, owner) do
    args = %{
      name: name,
      impl: impl,
      config: config,
      routing_id: routing_id,
      owner: owner
    }

    case DynamicSupervisor.start_child(sup, {Connection, args}) do
      {:ok, _pid} = ok ->
        ok

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        # If the supervisor is missing (e.g. a test that started the
        # Registry without the surrounding Upstream.Supervisor),
        # fall back to a plain `start_link`. Tests that exercise
        # `put_fake/2` against an isolated Registry rely on this.
        case Connection.start_link(args) do
          {:ok, _pid} = ok ->
            ok

          err ->
            # Surface the original supervisor reason so
            # misconfigurations are diagnosable without test-path noise.
            {:error, {:start_failed, reason, err}}
        end
    end
  end

  defp stop_existing_connection(state, name) do
    case Map.get(state.upstreams, name) do
      nil ->
        state

      _entry ->
        case Connection.whereis(state.routing_id, name) do
          nil ->
            :ok

          pid ->
            # Tear down the previous Connection cleanly before
            # installing a fresh one. `Connection.stop/1` runs the
            # impl's `stop/1` via terminate/2, so an in-flight Fake
            # impl is also stopped.
            case maybe_terminate_via_supervisor(state.connection_supervisor, pid) do
              :ok -> :ok
              :not_started -> Connection.stop(pid)
            end
        end

        %{state | upstreams: Map.delete(state.upstreams, name)}
    end
  end

  defp maybe_terminate_via_supervisor(sup, pid) do
    case DynamicSupervisor.terminate_child(sup, pid) do
      :ok -> :ok
      {:error, :not_found} -> :not_started
    end
  catch
    :exit, _ -> :not_started
  end

  # ----------------------------------------------------------------
  # Defensive Connection accessors (the routed pid may die between
  # `whereis/2` and the `GenServer.call`; treat that as :not_started
  # rather than letting the call site crash).
  # ----------------------------------------------------------------

  defp safe_snapshot(pid) do
    Connection.snapshot(pid)
  catch
    :exit, _ -> nil
  end

  defp safe_started?(pid) do
    Connection.started?(pid)
  catch
    :exit, _ -> false
  end

  defp safe_cached_tools(pid) do
    Connection.cached_tools(pid)
  catch
    :exit, _ -> nil
  end

  defp snapshot_field(nil, _key, default), do: default
  defp snapshot_field(snap, key, default), do: Map.get(snap, key, default)
end
