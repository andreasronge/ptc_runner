defmodule PtcRunnerMcp.Upstream.Connection do
  @moduledoc """
  Per-name worker GenServer that owns the lifecycle of a single
  upstream impl (`PtcRunnerMcp.Upstream.Fake` or
  `PtcRunnerMcp.Upstream.Stdio`).

  Per `Plans/ptc-runner-mcp-aggregator.md` §4.4: Phase 1b splits the
  Phase 1a `Upstream.Registry` into a thin routing layer
  (`name -> connection_pid`) and per-name `Connection` processes that
  serialize `ensure_started/1` for THEIR name only. Cold starts for
  different upstream names therefore proceed concurrently — the
  Phase 1a "global serialization through one Registry mailbox"
  anti-pattern is gone.

  The Connection mailbox is the per-name lock: concurrent
  `ensure_started/1` callers from `pmap` branches that target the
  same not-yet-started upstream queue at this mailbox, see exactly
  one impl `start_link/2` attempt, and replay the result. The
  per-program ETS leader/follower lock in `AggregatorTools` /
  `UpstreamCalls` is unchanged — it provides per-program
  short-circuiting orthogonal to the per-name lock.

  ## State

      %{
        name:               String.t(),
        impl:               module(),
        config:             map(),
        status:             :not_started | :started,
        impl_pid:           pid() | nil,
        monitor_ref:        reference() | nil,
        cached_tools:       [tool_schema()] | nil,
        started_at:         DateTime.t() | nil,
        backoff_initial_ms: pos_integer(),
        backoff_max_ms:     pos_integer(),
        backoff_current_ms: pos_integer(),
        backoff_until_ms:   integer() | nil
      }

  `:backoff_until_ms` is a monotonic-time deadline (set via
  `System.monotonic_time(:millisecond)`); when a fresh
  `ensure_started/1` arrives before that deadline it is rejected with
  `{:error, :upstream_unavailable, "in recovery"}` without attempting
  a new spawn. After a successful start the backoff window resets to
  `:backoff_initial_ms`. Per §4.3 the maximum backoff is 30s.

  Tests can fast-forward the backoff window by setting a small
  `:backoff_initial_ms` in the config (e.g. `5`), making the
  recovery-window assertion deterministic without wall-clock sleep.

  ## Crash detection

  When the impl is `:started`, the Connection monitors its
  `impl_pid`. On `:DOWN` (clean stop or crash) the Connection
  transitions back to `:not_started`, clears `cached_tools`, and
  arms the backoff window. `started_upstreams/0` (in the Registry)
  immediately reflects the loss because it derives from each
  Connection's snapshot.
  """

  use GenServer

  alias PtcRunnerMcp.Upstream

  @default_backoff_initial_ms 100
  @default_backoff_max_ms 30_000

  @typedoc "Snapshot returned by `snapshot/1` for the routing layer."
  @type snapshot :: %{
          name: Upstream.server_name(),
          impl: module(),
          config: map(),
          status: :not_started | :started,
          started_at: DateTime.t() | nil,
          cached_tools: [Upstream.tool_schema()] | nil,
          pid: pid() | nil
        }

  @typedoc "Result returned by `ensure_started/1`."
  @type ensure_result ::
          {:ok, %{duration_ms: non_neg_integer()}}
          | {:error, :upstream_unavailable, String.t(), %{duration_ms: non_neg_integer()}}

  # ----------------------------------------------------------------
  # Child spec & start_link
  # ----------------------------------------------------------------

  @doc """
  Builds a child spec for this Connection. The argument is
  `{name, impl, config}`.

  Setting `:id` to the upstream name allows the
  `Upstream.Supervisor` to start one Connection per configured
  upstream under `:one_for_one`.
  """
  @spec child_spec(
          map()
          | {Upstream.server_name(), module(), map()}
          | {Upstream.server_name(), module(), map(), pid() | nil}
        ) :: Supervisor.child_spec()
  def child_spec(%{name: name} = args) when is_binary(name) do
    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [args]},
      type: :worker,
      # `:transient` lets DynamicSupervisor restart only on abnormal
      # exit (a code bug); a normal/`:shutdown` exit (e.g. when the
      # routing Registry calls `terminate_child/2` for `put_fake/2`
      # replacement) does NOT trigger a restart. The Registry is the
      # owner of the Connection lifecycle, but on abnormal Connection
      # death DynamicSupervisor restarts under the same `:via` name
      # so Registry's `connection_for/2` lookups always resolve to
      # the live pid (codex review of `46b4466` [P2] #2 — pre-fix
      # the routing Registry cached the pre-restart pid, and every
      # routed call after restart hit `:noproc`).
      restart: :transient,
      shutdown: 5_000
    }
  end

  # Tuple-form `child_spec/1` for tests that supervise a Connection
  # outside the routing Registry. The caller pid (`self()` at
  # `child_spec/1` invocation time) becomes the routing_id — see
  # the tuple-form `start_link/1` for the same convention.
  def child_spec({name, _impl, _config} = arg) when is_binary(name) do
    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [arg]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  def child_spec({name, _impl, _config, _owner} = arg) when is_binary(name) do
    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [arg]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  @doc """
  Starts a Connection process.

  Required keys:

    * `:name` — the upstream string name (e.g. `"github"`).
    * `:impl` — the `PtcRunnerMcp.Upstream` behaviour module
      (`Upstream.Fake` or `Upstream.Stdio`).
    * `:config` — impl config map (atom-keyed; see
      `PtcRunnerMcp.Application.normalize_stdio_config/1`).
    * `:routing_id` — opaque id (typically the routing Registry
      pid) that scopes the `:via` registration. Different routing
      Registries may host Connections for the same upstream name
      without colliding on a global `Connection.Names` key.

  Optional:

    * `:owner` — a pid the Connection monitors; on owner DOWN the
      Connection stops itself (used for test cleanup and to ensure
      the impl's `Fake.Names` / `Stdio.Names` registration is
      released).

  The Connection registers under `{:via, Registry, {Connection.Names,
  {routing_id, name}}}`. Routing-layer lookups via the same key
  always resolve to the live pid, INCLUDING after a DynamicSupervisor
  restart.
  """
  @spec start_link(
          map()
          | {Upstream.server_name(), module(), map()}
          | {Upstream.server_name(), module(), map(), pid() | nil}
        ) :: GenServer.on_start()
  def start_link(%{name: name, impl: impl, config: config, routing_id: routing_id} = args)
      when is_binary(name) and is_atom(impl) and is_map(config) do
    owner = Map.get(args, :owner)
    via = via_tuple(routing_id, name)

    GenServer.start_link(
      __MODULE__,
      {name, impl, config, owner},
      name: via
    )
  end

  # Tuple-form `start_link/1` for tests that drive the Connection
  # in isolation (no routing Registry). The caller pid is used as
  # the routing_id so multiple test callers don't collide on the
  # global `Connection.Names` registry.
  def start_link({name, impl, config})
      when is_binary(name) and is_atom(impl) and is_map(config) do
    start_link(%{name: name, impl: impl, config: config, routing_id: self()})
  end

  def start_link({name, impl, config, owner})
      when is_binary(name) and is_atom(impl) and is_map(config) and
             (is_pid(owner) or is_nil(owner)) do
    start_link(%{
      name: name,
      impl: impl,
      config: config,
      routing_id: self(),
      owner: owner
    })
  end

  @doc """
  Returns the `:via` tuple a Connection registers under for
  `{routing_id, name}`. Use this to look up or call the Connection
  by its stable name, surviving DynamicSupervisor restarts.
  """
  @spec via_tuple(term(), Upstream.server_name()) ::
          {:via, module(), {atom(), {term(), Upstream.server_name()}}}
  def via_tuple(routing_id, name) when is_binary(name) do
    {:via, Registry, {__MODULE__.Names, {routing_id, name}}}
  end

  @doc """
  Returns the live Connection pid for `{routing_id, name}`, or
  `nil` if no Connection is currently registered. Always reflects
  the most-recent restart's pid because the underlying
  `Connection.Names` Registry is updated on registration.
  """
  @spec whereis(term(), Upstream.server_name()) :: pid() | nil
  def whereis(routing_id, name) when is_binary(name) do
    case Registry.lookup(__MODULE__.Names, {routing_id, name}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  @spec child_spec_for_registry() :: {module(), keyword()}
  def child_spec_for_registry do
    {Registry, keys: :unique, name: __MODULE__.Names}
  end

  # ----------------------------------------------------------------
  # Public API (called by AggregatorTools / Registry)
  # ----------------------------------------------------------------

  @doc """
  Synchronously ensures the Connection's impl is `:started`.

  Returns `{:ok, %{duration_ms: ms}}` on success, or
  `{:error, :upstream_unavailable, detail, %{duration_ms: ms}}` on
  failure. The wall-clock duration is the time spent inside this
  call — for callers waiting on a leader's spawn the duration
  reflects only their wait, not the spawn itself; that is the same
  shape as Phase 1a's Registry.ensure_started/2 returned.

  The Connection mailbox is the per-name lock per §4.4: concurrent
  callers for the same name observe exactly one impl
  `start_link/2` attempt; the second arrival sees the cached
  `:started` state and returns immediately.
  """
  @spec ensure_started(pid()) :: ensure_result()
  def ensure_started(connection) when is_pid(connection) do
    GenServer.call(connection, :ensure_started, :infinity)
  end

  @doc """
  Dispatches `Upstream.call/4` against the Connection's impl.

  The Connection holds the impl module and name in its state, so the
  caller only supplies `tool`, `args`, and `opts`. Per the §6.3
  `Upstream` behaviour invariant, `call/4` MUST NOT raise; the
  Connection forwards the result directly without classification.
  """
  @spec call(pid(), Upstream.tool_name(), map(), Upstream.call_opts()) ::
          {:ok, Upstream.json()} | {:error, Upstream.reason(), String.t()}
  def call(connection, tool, args, opts)
      when is_pid(connection) and is_binary(tool) and is_map(args) and is_list(opts) do
    # Fetch the impl + name once; do the impl.call/4 from the caller
    # process so multiple in-flight `tools/call` invocations against
    # the same upstream can proceed in parallel. The impl is
    # responsible for any per-call serialization it requires (Stdio
    # serializes via the Port's correlation id; Fake is stateless).
    {impl, name} = GenServer.call(connection, :impl_and_name)

    impl.call(name, tool, args, opts)
  rescue
    e -> {:error, :upstream_error, "impl.call/4 raised: #{Exception.message(e)}"}
  catch
    :exit, reason ->
      {:error, :upstream_error, "impl.call/4 exited: #{inspect(reason, limit: 50)}"}
  end

  @doc """
  Returns the cached `tools/list` for this Connection if `:started`,
  or `nil` otherwise. Used by §7.4 unknown-tool classification.
  """
  @spec cached_tools(pid()) :: [Upstream.tool_schema()] | nil
  def cached_tools(connection) when is_pid(connection) do
    GenServer.call(connection, :cached_tools)
  end

  @doc """
  Returns `true` iff the Connection's impl is currently `:started`.
  """
  @spec started?(pid()) :: boolean()
  def started?(connection) when is_pid(connection) do
    GenServer.call(connection, :started?)
  end

  @doc """
  Returns a snapshot of the Connection's externally-visible state.
  Used by the Registry to derive `started_upstreams/0` and
  `lookup/1`.
  """
  @spec snapshot(pid()) :: snapshot()
  def snapshot(connection) when is_pid(connection) do
    GenServer.call(connection, :snapshot)
  end

  @doc """
  Stops the Connection (and any running impl) cleanly.
  Idempotent — a `:noproc` exit is treated as success.
  """
  @spec stop(pid()) :: :ok
  def stop(connection) when is_pid(connection) do
    GenServer.stop(connection, :normal, 5_000)
  catch
    :exit, _ -> :ok
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl GenServer
  def init({name, impl, config, owner}) do
    # Trap exits so an impl whose `init/1` returns `{:stop, _}` does
    # NOT propagate to us. The impl is expected to either complete
    # the handshake before returning OR return `:error` per §6.3 —
    # but a buggy impl that stops with a non-handshake exit must not
    # take this Connection down.
    Process.flag(:trap_exit, true)

    # Snapshot the OTP parent pid (the DynamicSupervisor in production,
    # or the test caller in the standalone fallback path). Codex review
    # of `3c2754d` flagged that the catch-all `:EXIT` handler was
    # swallowing supervisor shutdown — `terminate/2` then never ran
    # `impl.stop/1`, the subprocess didn't see stdin EOF, and the
    # supervisor's 5 s `:shutdown` timeout had to escalate to `:kill`.
    #
    # Use `$ancestors`, not `Process.info(self(), :links)`: a process can
    # have multiple links and their order is not an ownership contract.
    # Picking the first link made owner-down tests flaky because a
    # transient linked process could be mistaken for the parent; when it
    # exited, the Connection stopped before the test installed its
    # monitor.
    parent_pid = otp_parent_pid()

    owner_ref =
      case owner do
        nil -> nil
        pid when is_pid(pid) -> Process.monitor(pid)
      end

    backoff_initial =
      Map.get(config, :backoff_initial_ms, @default_backoff_initial_ms)

    backoff_max =
      Map.get(config, :backoff_max_ms, @default_backoff_max_ms)

    state = %{
      name: name,
      impl: impl,
      config: config,
      status: :not_started,
      impl_pid: nil,
      monitor_ref: nil,
      owner_pid: owner,
      owner_ref: owner_ref,
      parent_pid: parent_pid,
      cached_tools: nil,
      started_at: nil,
      backoff_initial_ms: backoff_initial,
      backoff_max_ms: backoff_max,
      backoff_current_ms: backoff_initial,
      backoff_until_ms: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:ensure_started, _from, %{status: :started} = state) do
    {:reply, {:ok, %{duration_ms: 0}}, state}
  end

  def handle_call(:ensure_started, _from, state) do
    case in_backoff?(state) do
      true ->
        detail = "in recovery"
        {:reply, {:error, :upstream_unavailable, detail, %{duration_ms: 0}}, state}

      false ->
        do_ensure_started(state)
    end
  end

  def handle_call(:cached_tools, _from, %{status: :started, cached_tools: tools} = state) do
    {:reply, tools, state}
  end

  def handle_call(:cached_tools, _from, state), do: {:reply, nil, state}

  def handle_call(:started?, _from, state) do
    {:reply, state.status == :started, state}
  end

  def handle_call(:snapshot, _from, state) do
    snap = %{
      name: state.name,
      impl: state.impl,
      config: state.config,
      status: state.status,
      started_at: state.started_at,
      cached_tools: state.cached_tools,
      pid: state.impl_pid
    }

    {:reply, snap, state}
  end

  def handle_call(:impl_and_name, _from, state) do
    {:reply, {state.impl, state.name}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state)
      when is_reference(ref) do
    # The owner (typically the routing Registry) died. Stop ourselves
    # cleanly so `terminate/2` runs `safe_stop` on the impl,
    # releasing the global `Upstream.Fake.Names` registration. No
    # restart — DynamicSupervisor children are `:transient`, and
    # `:normal` is the non-restart reason.
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{monitor_ref: ref} = state) do
    # §4.3 third bullet: when the upstream impl dies, transition back
    # to :not_started and clear cached_tools. `started_upstreams/0`
    # (Registry-derived) immediately reflects the loss.
    #
    # The recovery-backoff window is armed ONLY on abnormal exits —
    # the spec language ("the supervisor restarts the underlying
    # process with exponential backoff") describes recovery from a
    # crash, not a clean shutdown. A clean `:normal` / `:shutdown`
    # exit (e.g. `Fake.stop/1` during a test, or stdin EOF on Stdio)
    # represents intentional teardown; the next `ensure_started/1`
    # MUST attempt fresh without waiting on a backoff window.
    state = invalidate(state)

    state =
      if abnormal_exit?(reason),
        do: arm_backoff_after_failure(state),
        else: state

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Stale :DOWN for a previously-monitored impl that has been
    # replaced. Ignore — the current monitor_ref is what matters.
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, %{parent_pid: parent} = state)
      when is_pid(pid) and pid == parent do
    # Parent (DynamicSupervisor in production; test caller in the
    # standalone fallback) is shutting us down. Stop cleanly so
    # `terminate/2` runs `impl.stop/1` — the subprocess sees
    # stdin EOF (Stdio) or `Fake.stop/1` (Fake) before the
    # supervisor's `:shutdown` timeout escalates to `:kill`.
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    # Trap-exit absorbs init-time stops from the impl's start_link/2
    # (which we already classified into the {:error, _} return) plus
    # any other non-parent linked process. The impl's RUNTIME
    # death is observed via the `:DOWN` monitor handler above —
    # which is why this clause is safe to no-op.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{status: :started, impl: impl, name: name}) do
    # On graceful shutdown (supervisor stop or :normal exit), tell the
    # impl to stop. `stop/1` is idempotent per §6.3.
    safe_stop(impl, name)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ----------------------------------------------------------------
  # Private helpers
  # ----------------------------------------------------------------

  defp otp_parent_pid do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp do_ensure_started(state) do
    start_at = System.monotonic_time(:millisecond)

    case attempt_start(state.impl, state.name, state.config) do
      {:ok, pid, tools} ->
        duration = System.monotonic_time(:millisecond) - start_at
        monitor_ref = Process.monitor(pid)

        new_state = %{
          state
          | status: :started,
            impl_pid: pid,
            monitor_ref: monitor_ref,
            cached_tools: tools,
            started_at: DateTime.utc_now(),
            backoff_current_ms: state.backoff_initial_ms,
            backoff_until_ms: nil
        }

        {:reply, {:ok, %{duration_ms: duration}}, new_state}

      {:error, :upstream_unavailable, detail} ->
        duration = System.monotonic_time(:millisecond) - start_at

        # §4.3 first bullet: "no automatic retry of `ensure_started/1`
        # within a single program; the next program is a fresh attempt."
        # Init-time failures DO NOT arm the recovery-backoff window —
        # within-program suppression is owned by `AggregatorTools`'s
        # per-program ETS failure cache, and across-program retries
        # are required (a transient subprocess failure cannot poison
        # subsequent `tools/call` requests). The backoff window is
        # armed ONLY on `:DOWN` of a previously-`:started` impl per
        # §4.3 third bullet ("a started upstream that crashes is
        # removed from `started_upstreams`. The supervisor restarts
        # the underlying process with exponential backoff.").
        {:reply, {:error, :upstream_unavailable, detail, %{duration_ms: duration}}, state}
    end
  end

  defp attempt_start(impl, name, config) do
    case safe_start_link(impl, name, config) do
      {:ok, pid} ->
        case safe_list_tools(impl, name) do
          {:ok, tools} ->
            {:ok, pid, normalize_tools(tools)}

          {:error, _reason, detail} ->
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

  defp invalidate(state) do
    if is_reference(state.monitor_ref) do
      Process.demonitor(state.monitor_ref, [:flush])
    end

    %{
      state
      | status: :not_started,
        impl_pid: nil,
        monitor_ref: nil,
        cached_tools: nil,
        started_at: nil
    }
  end

  defp arm_backoff_after_failure(state) do
    now = System.monotonic_time(:millisecond)
    window = min(state.backoff_current_ms, state.backoff_max_ms)
    next_window = min(state.backoff_current_ms * 2, state.backoff_max_ms)

    %{
      state
      | backoff_until_ms: now + window,
        backoff_current_ms: next_window
    }
  end

  defp in_backoff?(%{backoff_until_ms: nil}), do: false

  defp in_backoff?(%{backoff_until_ms: until}) do
    System.monotonic_time(:millisecond) < until
  end

  defp abnormal_exit?(:normal), do: false
  defp abnormal_exit?(:shutdown), do: false
  defp abnormal_exit?({:shutdown, _}), do: false
  defp abnormal_exit?(_), do: true
end
