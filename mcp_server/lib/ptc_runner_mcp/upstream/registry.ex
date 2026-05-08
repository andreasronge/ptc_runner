defmodule PtcRunnerMcp.Upstream.Registry do
  @moduledoc """
  Routes upstream names to `PtcRunnerMcp.Upstream` implementations and
  serializes `ensure_started/1` per name.

  Per `Plans/ptc-runner-mcp-aggregator.md` §4.1 and §5.4:

    * The Registry is the single per-name lock for `ensure_started/1`.
      Concurrent `pmap` branches calling `(tool/mcp-call ...)` against
      the same not-yet-started upstream observe exactly one spawn
      attempt; the second arrival sees the cached result.
    * Test fakes are registered exclusively through this module's
      test API (`put_fake/2` or the `:upstreams` start option). The
      JSON config file MUST NOT carry a `"fake"` field; production
      `Application.start/2` MUST NOT call `put_fake/2`.

  ## State shape

      %{
        upstreams: %{
          name => %{
            impl:         module,
            config:       map(),
            status:       :not_started | :started,
            started_at:   DateTime.t() | nil,
            cached_tools: [tool_schema()] | nil,
            pid:          pid() | nil,
            monitor_ref:  reference() | nil
          }
        },
        monitors: %{reference() => name}
      }

  Per §4.3 third bullet "a started upstream that crashes is removed
  from `started_upstreams`": when an entry transitions to `:started`
  the registry monitors the upstream pid; on `:DOWN` (clean
  `stop/1` or crash) the entry is reset to `:not_started`,
  `cached_tools` is cleared, and the next `ensure_started/2` will
  attempt a fresh spawn.

  Per §4.3 first bullet "no automatic retry of `ensure_started/1`
  within a single program; the next program is a fresh attempt":
  the registry does **NOT** cache failures across programs. The
  per-program failure dedup lives in
  `PtcRunnerMcp.UpstreamCalls.call_context.failure_cache` (an
  ETS table owned by the request worker, auto-cleaned on worker
  death). The registry simply attempts each `ensure_started/2`;
  the call site (`AggregatorTools`) handles the within-program
  short-circuit.
  """

  use GenServer

  alias PtcRunnerMcp.Upstream
  alias PtcRunnerMcp.Upstream.Fake

  @type upstream_entry :: %{
          impl: module(),
          config: map(),
          status: :not_started | :started,
          started_at: DateTime.t() | nil,
          cached_tools: [Upstream.tool_schema()] | nil,
          pid: pid() | nil,
          monitor_ref: reference() | nil
        }

  # ----------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------

  @doc """
  Starts the Registry. Accepts `:upstreams` (a list of
  `%{name: ..., impl: ..., config: ...}` entries used to bootstrap
  the routing table) and `:name` (defaults to `__MODULE__`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the configured upstream `name`'s entry, or `nil` if the
  upstream is not registered.
  """
  @spec lookup(Upstream.server_name(), atom()) :: upstream_entry() | nil
  def lookup(name, server \\ __MODULE__) when is_binary(name) do
    GenServer.call(server, {:lookup, name})
  end

  @doc """
  Returns the set of upstream names that are currently in the
  `:started` state — i.e. `start_link/2` and `list_tools/1` have
  succeeded and the upstream's `tools/list` is cached.

  Used by §7.4 unknown-tool classification and by diagnostics.
  Per §4.1 and §8.2, advertised description / annotations /
  outputSchema are driven by `configured_aggregator_mode?/0`,
  not by this set.
  """
  @spec started_upstreams(atom()) :: MapSet.t(Upstream.server_name())
  def started_upstreams(server \\ __MODULE__) do
    GenServer.call(server, :started_upstreams)
  end

  @doc """
  Returns the cached `tools/list` for `name` if the upstream is
  currently `:started`. Returns `nil` otherwise. Used by §7.4 to
  prove unknown-tool classification.
  """
  @spec cached_tools(Upstream.server_name(), atom()) :: [Upstream.tool_schema()] | nil
  def cached_tools(name, server \\ __MODULE__) when is_binary(name) do
    GenServer.call(server, {:cached_tools, name})
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
  Synchronously ensures the upstream `name` is `:started`.

  Returns `:ok` on success, or `{:error, :upstream_unavailable,
  detail}` on failure (subprocess spawn error, `initialize` error,
  `notifications/initialized` rejected, or `tools/list` failure —
  per §7.1). The result includes a `:duration_ms` field measuring
  the wall-clock time spent attempting the operation, so the
  executor can report it on the `upstream_calls` entry per §8.5.
  """
  @spec ensure_started(Upstream.server_name(), atom()) ::
          {:ok, %{duration_ms: non_neg_integer()}}
          | {:error, :upstream_unavailable, String.t(), %{duration_ms: non_neg_integer()}}
  def ensure_started(name, server \\ __MODULE__) when is_binary(name) do
    GenServer.call(server, {:ensure_started, name}, :infinity)
  end

  # ----------------------------------------------------------------
  # Test API (§5.4)
  # ----------------------------------------------------------------

  @doc """
  Test-only: install a Fake upstream under `name` with the given
  `config` map. Replaces any existing entry for `name`. Always uses
  `PtcRunnerMcp.Upstream.Fake` as the implementation module.

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
    # Trap exits so an upstream impl whose `init/1` returns `{:stop, _}`
    # surfaces as `{:error, _}` from `safe_start_link/3` rather than
    # crashing this Registry. Per §6.3 the impl's `start_link/2` is
    # expected to "complete the handshake before returning, or return
    # `:error` with reason `:upstream_unavailable`" — that contract is
    # only satisfiable when the linked spawn does not propagate the
    # exit to us.
    Process.flag(:trap_exit, true)

    upstreams =
      opts
      |> Keyword.get(:upstreams, [])
      |> Enum.into(%{}, fn entry ->
        %{name: name, impl: impl, config: config} = entry
        {name, fresh_entry(impl, config)}
      end)

    {:ok, %{upstreams: upstreams, monitors: %{}}}
  end

  defp fresh_entry(impl, config) do
    %{
      impl: impl,
      config: config,
      status: :not_started,
      started_at: nil,
      cached_tools: nil,
      pid: nil,
      monitor_ref: nil
    }
  end

  @impl GenServer
  def handle_call({:lookup, name}, _from, state) do
    {:reply, Map.get(state.upstreams, name), state}
  end

  def handle_call({:configured?, name}, _from, state) do
    {:reply, Map.has_key?(state.upstreams, name), state}
  end

  def handle_call(:configured_count, _from, state) do
    {:reply, map_size(state.upstreams), state}
  end

  def handle_call({:cached_tools, name}, _from, state) do
    case Map.get(state.upstreams, name) do
      %{status: :started, cached_tools: tools} -> {:reply, tools, state}
      _ -> {:reply, nil, state}
    end
  end

  def handle_call(:started_upstreams, _from, state) do
    started =
      state.upstreams
      |> Enum.filter(fn {_name, entry} -> entry.status == :started end)
      |> Enum.map(fn {name, _entry} -> name end)
      |> MapSet.new()

    {:reply, started, state}
  end

  def handle_call({:put_fake, name, config}, _from, state) do
    # If a previous Fake under the same name was already started,
    # stop it cleanly and demonitor so the resulting `:DOWN` does
    # not race with the new entry. Then install a fresh
    # `:not_started` entry — the next `ensure_started/2` will
    # re-spawn against the new config.
    state = demonitor_existing(state, name)
    stop_existing_fake(Map.get(state.upstreams, name), name)
    entry = fresh_entry(Fake, config)

    {:reply, :ok, %{state | upstreams: Map.put(state.upstreams, name, entry)}}
  end

  def handle_call({:ensure_started, name}, _from, state) do
    case Map.get(state.upstreams, name) do
      nil ->
        # `:server` value not in the upstreams config. The executor
        # classifies this as programmer-fault (§7.2) BEFORE calling
        # `ensure_started/2`, so reaching here means a misconfigured
        # call site. Return a clear error so the bug is visible.
        detail = "upstream '#{name}' is not configured"

        {:reply, {:error, :upstream_unavailable, detail, %{duration_ms: 0}}, state}

      %{status: :started} = _entry ->
        {:reply, {:ok, %{duration_ms: 0}}, state}

      %{impl: impl, config: config} = entry ->
        # No registry-level failure cache: per §4.3 first bullet,
        # within-program retry suppression lives in the call
        # context's `failure_cache` (owned by the request worker).
        # Across programs the registry MUST attempt fresh — a
        # transient startup failure cannot poison subsequent
        # `tools/call` requests.
        #
        # TODO(phase 1b): `attempt_start/3` runs inside the
        # GenServer mailbox, so a slow cold start for one upstream
        # blocks `ensure_started` for every other upstream. Phase 1a's
        # only impl is the in-process `Upstream.Fake` whose
        # production paths have no slow spawn, so this is benign.
        # With Phase 1b's `Upstream.Stdio` impl a slow subprocess
        # spawn becomes a real concern: the per-name lock + spawn
        # should move outside the GenServer mailbox (per-name lock
        # + caller-process spawn, or task supervisor) so cross-name
        # `ensure_started` calls run in parallel. See spec §4.1.
        start_at = System.monotonic_time(:millisecond)
        result = attempt_start(impl, name, config)
        duration = System.monotonic_time(:millisecond) - start_at

        case result do
          {:ok, pid, tools} ->
            monitor_ref = Process.monitor(pid)

            updated = %{
              entry
              | status: :started,
                started_at: DateTime.utc_now(),
                cached_tools: tools,
                pid: pid,
                monitor_ref: monitor_ref
            }

            new_state = %{
              state
              | upstreams: Map.put(state.upstreams, name, updated),
                monitors: Map.put(state.monitors, monitor_ref, name)
            }

            {:reply, {:ok, %{duration_ms: duration}}, new_state}

          {:error, reason, detail} ->
            {:reply, {:error, reason, detail, %{duration_ms: duration}}, state}
        end
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # §4.3 third bullet: "a started upstream that crashes is
    # removed from `started_upstreams`." This handler is the single
    # invalidation point — clean `Fake.stop/1` and a forcible kill
    # both arrive here, so `started_upstreams/0` and `cached_tools/2`
    # never return stale values for a dead process.
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {name, monitors} ->
        upstreams =
          case Map.get(state.upstreams, name) do
            nil ->
              state.upstreams

            entry ->
              Map.put(state.upstreams, name, %{
                entry
                | status: :not_started,
                  started_at: nil,
                  cached_tools: nil,
                  pid: nil,
                  monitor_ref: nil
              })
          end

        {:noreply, %{state | upstreams: upstreams, monitors: monitors}}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # We trap_exit to absorb init-time failures from upstream impls
    # whose `init/1` returns `{:stop, ...}`. The `:DOWN` handler
    # above owns the started-upstream invalidation path; this
    # clause is just here to silence unsolicited `:EXIT` messages.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ----------------------------------------------------------------
  # Private
  # ----------------------------------------------------------------

  defp stop_existing_fake(%{impl: Fake, status: :started}, name), do: :ok = Fake.stop(name)
  defp stop_existing_fake(_other, _name), do: :ok

  # Demonitor any existing monitor for `name`, drop the monitor
  # entry, and flush any pending `:DOWN` so it cannot race with
  # the new entry installation.
  defp demonitor_existing(state, name) do
    case Map.get(state.upstreams, name) do
      %{monitor_ref: ref} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, ref)}

      _ ->
        state
    end
  end

  # Run `impl.start_link/2` and `impl.list_tools/1` to satisfy the
  # §6.3 invariant that `start_link/2` completes the handshake
  # before returning. Any failure collapses to `:upstream_unavailable`
  # (the world-fault reason for ensure-started failures, §7.1).
  # On success returns `{:ok, pid, tools}` so the caller can monitor
  # the upstream process for §4.3 crash-invalidation.
  defp attempt_start(impl, name, config) do
    case safe_start_link(impl, name, config) do
      {:ok, pid} ->
        case safe_list_tools(impl, name) do
          {:ok, tools} ->
            {:ok, pid, normalize_tools(tools)}

          {:error, _reason, detail} ->
            # Tear down the half-started upstream so a future
            # ensure_started attempt starts fresh.
            _ = safe_stop(impl, name)
            {:error, :upstream_unavailable, detail}
        end

      {:error, {reason, detail}} when is_atom(reason) and is_binary(detail) ->
        {:error, :upstream_unavailable, detail}

      {:error, reason} ->
        {:error, :upstream_unavailable, "start_link failed: #{inspect(reason, limit: 50)}"}
    end
  end

  defp safe_start_link(impl, name, config) do
    impl.start_link(name, config)
  rescue
    e -> {:error, "start_link raised: #{Exception.message(e)}"}
  catch
    :exit, reason -> {:error, "start_link exited: #{inspect(reason, limit: 50)}"}
  end

  defp safe_list_tools(impl, name) do
    impl.list_tools(name)
  rescue
    e -> {:error, :upstream_unavailable, "list_tools raised: #{Exception.message(e)}"}
  catch
    :exit, reason ->
      {:error, :upstream_unavailable, "list_tools exited: #{inspect(reason, limit: 50)}"}
  end

  defp safe_stop(impl, name) do
    impl.stop(name)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp normalize_tools(tools) when is_list(tools), do: tools
  defp normalize_tools(_), do: []
end
