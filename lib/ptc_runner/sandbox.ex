defmodule PtcRunner.Sandbox do
  @moduledoc """
  Executes programs in isolated BEAM processes with resource limits.

  Spawns isolated processes with configurable timeout and memory limits,
  ensuring safe program execution.

  ## Resource Limits

  | Resource | Default | Option |
  |----------|---------|--------|
  | Timeout | 1,000 ms | `:timeout` |
  | Max Heap | ~10 MB (1,250,000 words) | `:max_heap` |

  The `:max_heap` limit is enforced via BEAM's `:max_heap_size` process flag
  with `include_shared_binaries: true`, so it accounts for both process-local
  heap terms and shared (refc) binaries referenced by the process. This prevents
  binary-heavy programs from exceeding the memory budget via off-heap allocations.

  Note that this is a per-process BEAM budget, not a whole-node or container
  memory limit. For adversarial multi-tenant deployments, back this with an
  OS/container memory limit around the VM or an isolated worker process.

  ## Configuration

  Limits can be set per-call:

      PtcRunner.Lisp.run(program, timeout: 5000, max_heap: 5_000_000)

  Or as application-level defaults in `config.exs`:

      config :ptc_runner,
        default_timeout: 2000,
        default_max_heap: 2_500_000
  """

  alias PtcRunner.Context
  alias PtcRunner.TraceContext

  # Default resource limits
  @default_timeout 1000
  @default_max_heap 1_250_000

  @typedoc """
  Execution metrics for a program run.
  """
  @type metrics :: %{
          duration_ms: integer(),
          memory_bytes: integer()
        }

  @typedoc """
  Evaluator function that takes AST and context and returns result with memory.
  """
  @type eval_fn :: (any(), Context.t() ->
                      {:ok, any(), map()}
                      | {:error, {atom(), String.t()} | {atom(), String.t(), any()}})

  @doc """
  Executes an AST in an isolated sandbox process.

  ## Arguments
    - ast: The AST to execute
    - context: The execution context
    - opts: Options (timeout, max_heap, eval_fn)
      - `:eval_fn` - Evaluator function (required)
      - `:timeout` - Timeout in milliseconds (default: 1000, configurable via `:default_timeout`)
      - `:max_heap` - Max heap size in words (default: 1_250_000, configurable via `:default_max_heap`)

  ## Returns
    - `{:ok, result, metrics, memory}` on success
    - `{:error, reason}` on failure
  """
  @spec execute(any(), Context.t(), keyword()) ::
          {:ok, any(), metrics(), map()}
          | {:error,
             {atom(), non_neg_integer()} | {atom(), String.t()} | {atom(), String.t(), any()}}

  def execute(ast, context, opts \\ []) do
    default_timeout = Application.get_env(:ptc_runner, :default_timeout, @default_timeout)
    default_max_heap = Application.get_env(:ptc_runner, :default_max_heap, @default_max_heap)

    timeout = Keyword.get(opts, :timeout, default_timeout)
    max_heap = Keyword.get(opts, :max_heap, default_max_heap)
    eval_fn = Keyword.fetch!(opts, :eval_fn)
    # When `link: true`, the spawned sandbox process is linked to the
    # caller in addition to monitored. Used by the MCP server's
    # per-call worker (Phase 4): if the worker is killed (e.g. by
    # `notifications/cancelled`), the link signal propagates and the
    # sandbox child terminates promptly rather than running orphaned
    # until its own heap/timeout limit fires. Default `false` preserves
    # the legacy behavior used by SubAgent and text-mode callers.
    link? = Keyword.get(opts, :link, false)

    # Capture trace context for propagation into sandbox process
    trace_ctx = TraceContext.capture()

    # Spawn isolated process with resource limits
    start_time = System.monotonic_time(:millisecond)

    parent = self()

    spawn_opts =
      [
        {:max_heap_size,
         %{size: max_heap, kill: true, error_logger: false, include_shared_binaries: true}},
        :monitor
      ] ++
        if link?, do: [:link], else: []

    # When linking, the parent must trap exits so that an abnormal
    # child termination (heap_kill, eval_fn raise, etc.) is delivered
    # as a `{:EXIT, _, _}` message — already handled by the existing
    # `{:DOWN, ...}` monitor clause — instead of taking the parent
    # down via the link. We restore the prior trap-exit flag before
    # returning so this is invisible to non-linking callers.
    prior_trap_exit =
      if link?, do: Process.flag(:trap_exit, true), else: nil

    {pid, ref} =
      Process.spawn(
        fn ->
          # Re-attach trace context for tool telemetry capture
          TraceContext.attach(trace_ctx)

          # Set process priority to normal within the process
          Process.flag(:priority, :normal)
          result = eval_fn.(ast, context)
          memory = get_process_memory()
          send(parent, {:result, self(), result, memory})
        end,
        spawn_opts
      )

    try do
      # Wait for result with timeout
      receive do
        {:result, ^pid, result, memory} ->
          end_time = System.monotonic_time(:millisecond)
          duration = end_time - start_time

          Process.demonitor(ref, [:flush])

          case result do
            {:ok, value, eval_memory} ->
              {:ok, value, %{duration_ms: duration, memory_bytes: memory}, eval_memory}

            {:error, reason, eval_ctx} ->
              # Error with eval_ctx (e.g., from tool execution error with recorded tool_calls)
              # Return as a 4-tuple success with error tagged in the value
              {:ok, {:error_with_ctx, reason}, %{duration_ms: duration, memory_bytes: memory},
               eval_ctx}

            {:error, reason} ->
              {:error, reason}
          end

        {:DOWN, ^ref, :process, ^pid, :killed} ->
          {:error, {:memory_exceeded, max_heap * 8}}

        {:DOWN, ^ref, :process, ^pid, reason} ->
          {:error, {:execution_error, "Process terminated: #{inspect(reason)}"}}
      after
        timeout ->
          # Timeout path: kill the child WITHOUT letting its link signal
          # race with the trap_exit restore (codex review of 0fe4c78).
          # `Process.unlink/1` atomically discards any pending exit
          # signal from `pid` on the link, so the EXIT message cannot
          # reach our mailbox after we restore the prior `trap_exit`.
          Process.demonitor(ref, [:flush])
          if link?, do: Process.unlink(pid)
          Process.exit(pid, :kill)

          receive do
            {:result, ^pid, _result, _memory} -> :ok
          after
            0 -> :ok
          end

          {:error, {:timeout, timeout}}
      end
    after
      if link? do
        # Defense-in-depth: even with `unlink/1` above, we may have
        # been linked but not yet killed (success / DOWN paths). Flush
        # any straggler `{:EXIT, pid, _}` signal that may have arrived
        # before we restore `trap_exit`.
        receive do
          {:EXIT, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        Process.flag(:trap_exit, prior_trap_exit)
      end
    end
  end

  @doc """
  Runs an arbitrary function in an isolated process with resource limits.

  Unlike `execute/3` which is specialized for Lisp evaluation, this function
  runs any zero-arity function under the same process isolation primitives
  (timeout, `max_heap_size`, monitored child).

  ## Options

    * `:timeout` - Timeout in milliseconds (default: 1000)
    * `:max_heap` - Max heap size in words (default: 1_250_000)

  ## Returns

    * `{:ok, result}` — the function returned `result`
    * `{:error, {:timeout, ms}}` — killed after timeout
    * `{:error, {:memory_exceeded, bytes}}` — heap limit hit
    * `{:error, {:execution_error, message}}` — process crashed

  ## Examples

      iex> PtcRunner.Sandbox.run_bounded(fn -> 1 + 1 end)
      {:ok, 2}

      iex> PtcRunner.Sandbox.run_bounded(fn -> :timer.sleep(:infinity) end, timeout: 50)
      {:error, {:timeout, 50}}
  """
  @spec run_bounded((-> term()), keyword()) ::
          {:ok, term()}
          | {:error,
             {:timeout, non_neg_integer()}
             | {:memory_exceeded, non_neg_integer()}
             | {:execution_error, String.t()}}
  def run_bounded(fun, opts \\ []) when is_function(fun, 0) do
    default_timeout = Application.get_env(:ptc_runner, :default_timeout, @default_timeout)
    default_max_heap = Application.get_env(:ptc_runner, :default_max_heap, @default_max_heap)

    timeout = Keyword.get(opts, :timeout, default_timeout)
    max_heap = Keyword.get(opts, :max_heap, default_max_heap)

    parent = self()

    {pid, ref} =
      Process.spawn(
        fn ->
          Process.flag(:priority, :normal)
          result = fun.()
          send(parent, {:bounded_result, self(), result})
        end,
        [
          {:max_heap_size,
           %{size: max_heap, kill: true, error_logger: false, include_shared_binaries: true}},
          :monitor
        ]
      )

    receive do
      {:bounded_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error, {:memory_exceeded, max_heap * 8}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:execution_error, "Process terminated: #{inspect(reason)}"}}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)

        receive do
          {:bounded_result, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        {:error, {:timeout, timeout}}
    end
  end

  defp get_process_memory do
    case Process.info(self(), :memory) do
      {:memory, bytes} -> bytes
      nil -> 0
    end
  end
end
