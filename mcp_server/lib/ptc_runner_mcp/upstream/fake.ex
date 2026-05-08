defmodule PtcRunnerMcp.Upstream.Fake do
  @moduledoc """
  In-process implementation of `PtcRunnerMcp.Upstream` for tests and
  Phase 1a wiring.

  Per `Plans/ptc-runner-mcp-aggregator.md` §5.4 + §12.2: this module
  is the only Phase 1a impl; production stdio lifecycle lands in
  Phase 1b. Fakes are registered via the `Upstream.Registry` test
  API (`put_fake/2` or the `:upstreams` start option) — never via
  the JSON config file (§5.4).

  ## Config shape

  The `config` map passed to `start_link/2` (and stored in the
  Registry) supports:

    * `:tools` — `%{tool_name => {schema, fun}}` where `tool_name` is
      a string, `schema` is a `tool_schema()` map (used by
      `list_tools/1`), and `fun` is a 2-arity function
      `(args, call_opts) -> {:ok, json} | {:error, reason, detail}`.
      The function MAY block via `:timer.sleep/1` to test
      `upstream_call_timeout_ms` enforcement.
    * `:init_result` — controls what `start_link/2` returns. Defaults
      to `:ok`. When set to `{:error, reason, detail}`, the GenServer
      stops with that as the init failure (used to test
      `ensure_started/1` failure paths).

  ## Timeout enforcement

  `call/4` runs the configured `fun` in a spawned `Task` and awaits
  with the supplied `:timeout`. On timeout the task is shut down and
  `{:error, :timeout, detail}` is returned. On normal return the
  encoded JSON byte size is checked against `:max_response_bytes`
  before handing the value back; oversized responses become
  `{:error, :response_too_large, detail}`.

  These two checks live in the impl (not the executor) so the
  same enforcement code paths work for the Phase 1b stdio impl —
  the spec invariant in §6.3 is "`call/4` MUST enforce both".
  """

  @behaviour PtcRunnerMcp.Upstream

  use GenServer

  alias PtcRunnerMcp.Upstream

  # Registry-key prefix; combined with the upstream name to produce
  # the `:via` tuple under which the GenServer registers.
  @registry __MODULE__.Names

  @typedoc "Per-tool entry inside the Fake's `:tools` config."
  @type tool_entry :: {Upstream.tool_schema(), (map(), Upstream.call_opts() -> term())}

  @doc """
  Starts a Fake upstream registered under `name`.

  Returns `{:ok, pid}` on success, or `{:error, {:upstream_unavailable, detail}}`
  when the configured `:init_result` simulates a handshake failure.
  Conforms to the `PtcRunnerMcp.Upstream.start_link/2` callback.
  """
  @impl Upstream
  @spec start_link(Upstream.server_name(), map()) :: GenServer.on_start()
  def start_link(name, config) when is_binary(name) and is_map(config) do
    # Briefly enable trap_exit around the inner `GenServer.start_link/3`
    # so that an `init/1` returning `{:stop, _}` produces a clean
    # `{:error, _}` return value rather than an EXIT signal that
    # would crash the caller. Restoring `parent_trap` afterwards
    # leaves the caller's trap-exit setting unchanged.
    #
    # No mailbox-drain receive: `:proc_lib.start_link` internalizes
    # the init-failure link signal under trap_exit, so the caller's
    # mailbox is clean by the time `start_link/3` returns. The
    # earlier catch-all `{:EXIT, _, _}` drain (mirroring Stdio's
    # original pattern) silently consumed unrelated exit messages —
    # see codex review of `46b4466` [P2] #3.
    parent_trap = Process.flag(:trap_exit, true)

    try do
      GenServer.start_link(__MODULE__, {name, config}, name: via(name))
    after
      Process.flag(:trap_exit, parent_trap)
    end
  end

  @doc """
  Returns the list of configured tool schemas for `name`.
  """
  @impl Upstream
  @spec list_tools(Upstream.server_name()) ::
          {:ok, [Upstream.tool_schema()]} | {:error, Upstream.reason(), String.t()}
  def list_tools(name) when is_binary(name) do
    case whereis(name) do
      nil ->
        {:error, :upstream_unavailable, "fake upstream '#{name}' is not running"}

      pid ->
        GenServer.call(pid, :list_tools)
    end
  end

  @doc """
  Invokes the configured tool function for `tool_name` on the Fake
  upstream `name`. Enforces `:timeout` and `:max_response_bytes`
  per the §6.3 invariants.

  Never raises; all failures are returned as `{:error, reason, detail}`.
  """
  @impl Upstream
  @spec call(Upstream.server_name(), Upstream.tool_name(), map(), Upstream.call_opts()) ::
          {:ok, Upstream.json()} | {:error, Upstream.reason(), String.t()}
  def call(name, tool_name, args, opts)
      when is_binary(name) and is_binary(tool_name) and is_map(args) and is_list(opts) do
    case whereis(name) do
      nil ->
        {:error, :upstream_unavailable, "fake upstream '#{name}' is not running"}

      pid ->
        do_call(pid, name, tool_name, args, opts)
    end
  rescue
    # Defense in depth: §6.3 says `call/4` MUST NOT raise.
    e -> {:error, :upstream_error, "fake upstream raised: #{Exception.message(e)}"}
  end

  @doc "Stops the Fake upstream. Idempotent (no-op if not running)."
  @impl Upstream
  @spec stop(Upstream.server_name()) :: :ok
  def stop(name) when is_binary(name) do
    case whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    # If the GenServer crashes mid-stop or was already shutting down,
    # treat as success — `stop/1` is idempotent.
    :exit, _ -> :ok
  end

  # ----------------------------------------------------------------
  # GenServer callbacks
  # ----------------------------------------------------------------

  @impl GenServer
  def init({name, config}) do
    # Optional `:init_attempts` is a 1-slot `:atomics` ref the test
    # suite uses to count `start_link/2` invocations. Bumped here
    # (NOT in the per-call path) because the test invariant is
    # "exactly one ensure_started attempt per program" — each Fake
    # GenServer init corresponds to exactly one such attempt.
    case Map.get(config, :init_attempts) do
      nil ->
        :ok

      counter ->
        :atomics.add(counter, 1, 1)
    end

    # Optional `:init_delay_ms` simulates a slow handshake — useful
    # for exercising race windows in `ensure_started/2` callers
    # (e.g., the leader/follower lock test in
    # `aggregator_phase1a_test.exs`). The delay runs inside the
    # GenServer's own init, so concurrent `start_link/2` callers
    # observe the registry's per-name serialization holding for the
    # full delay.
    case Map.get(config, :init_delay_ms, 0) do
      0 -> :ok
      ms when is_integer(ms) and ms > 0 -> :timer.sleep(ms)
    end

    case Map.get(config, :init_result, :ok) do
      :ok ->
        {:ok, %{name: name, config: config}}

      {:error, reason, detail} ->
        # Per §6.3: `start_link/2` MUST return `:error` on handshake
        # failure with reason `:upstream_unavailable` and a detail
        # string. We surface `{reason, detail}` through `:stop` so
        # the caller of `start_link/2` sees `{:error, {reason, detail}}`.
        {:stop, {reason, detail}}
    end
  end

  @impl GenServer
  def handle_call(:list_tools, _from, state) do
    schemas =
      state.config
      |> Map.get(:tools, %{})
      |> Enum.map(fn {_name, {schema, _fun}} -> schema end)

    {:reply, {:ok, schemas}, state}
  end

  def handle_call({:lookup, tool_name}, _from, state) do
    {:reply, Map.get(Map.get(state.config, :tools, %{}), tool_name), state}
  end

  # ----------------------------------------------------------------
  # Private helpers
  # ----------------------------------------------------------------

  defp do_call(pid, _name, tool_name, args, opts) do
    case GenServer.call(pid, {:lookup, tool_name}) do
      nil ->
        # `call/4` does not classify as world-fault vs programmer-fault;
        # the executor decides per §7.4 using `started_upstreams/0` and
        # the cached `tools/list`. Here we surface a structural answer:
        # the upstream is healthy, the tool is just unknown to it. The
        # caller maps this to `:upstream_error` only if it ever reaches
        # that path (the §7.4 cache check should fire first).
        {:error, :upstream_error,
         "fake upstream '#{tool_name}' lookup failed: tool not configured"}

      {_schema, fun} when is_function(fun, 2) ->
        invoke_with_timeout(fun, args, opts)
    end
  end

  defp invoke_with_timeout(fun, args, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    max_bytes = Keyword.get(opts, :max_response_bytes, 2 * 1024 * 1024)

    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            fun.(args, opts)
          rescue
            e -> {:__fake_raised__, Exception.message(e)}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, {:__fake_raised__, msg}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :upstream_error, "fake call raised: #{msg}"}

      {^ref, {:ok, value}} ->
        Process.demonitor(monitor_ref, [:flush])
        check_response_size(value, max_bytes)

      {^ref, {:error, reason, detail}}
      when reason in [:upstream_unavailable, :upstream_error, :timeout, :response_too_large] ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason, detail}

      {^ref, other} ->
        Process.demonitor(monitor_ref, [:flush])

        {:error, :upstream_error,
         "fake call returned unsupported value: #{inspect(other, limit: 50)}"}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, :upstream_error, "fake call exited: #{inspect(reason, limit: 50)}"}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor_ref, :process, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout, "fake call exceeded timeout (#{timeout}ms)"}
    end
  end

  defp check_response_size(value, max_bytes) do
    case Jason.encode(value) do
      {:ok, encoded} ->
        size = byte_size(encoded)

        if size > max_bytes do
          {:error, :response_too_large,
           "fake response #{size} bytes exceeds max_response_bytes (#{max_bytes})"}
        else
          {:ok, value}
        end

      {:error, %Jason.EncodeError{} = err} ->
        {:error, :upstream_error, "fake response not JSON-encodable: #{Exception.message(err)}"}

      {:error, err} ->
        {:error, :upstream_error, "fake response not JSON-encodable: #{inspect(err, limit: 50)}"}
    end
  end

  defp via(name) do
    {:via, Registry, {@registry, name}}
  end

  defp whereis(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  @spec child_spec_for_registry() :: {module(), keyword()}
  def child_spec_for_registry do
    {Registry, keys: :unique, name: @registry}
  end
end
