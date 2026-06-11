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
  | Worker Max Heap | = `:max_heap` | `:worker_max_heap` |
  | Max Parallel Workers | 8 | `:max_parallel_workers` |

  `:max_heap` is the **program's allocation headroom above the granted
  environment**, not the process's absolute size. `execute/3` spawns the
  sandbox under a hard `:setup_max_heap` ceiling (default `4 × max_heap`)
  while the host-provided environment (context, `memory:`, tool closures,
  the parsed program) is copied in, then garbage-collects, measures that
  **pre-eval sandbox baseline**, and re-arms the `max_heap_size` flag at
  `baseline + max_heap`. Host-granted data is therefore excluded from the
  program's bill; memory the *program* acquires stays fail-closed. Two
  caveats (see `docs/plans/sandbox-heap-rebaseline.md`):

  - the baseline is a *sandbox* baseline — it includes the parsed user
    program (bounded by `:max_program_bytes`) and eval plumbing, not just
    grants;
  - per OTP, the `max_heap_size` check runs only when a GC triggers and
    counts transient garbage plus GC workspace, so `:max_heap` is
    allocation headroom, not a live-data quota.

  Callers granting data larger than the default setup ceiling must raise
  `:setup_max_heap` explicitly; otherwise the forced post-copy GC kills
  the sandbox deterministically with a distinguishable setup-phase error
  (the boundedness precondition, enforced).

  The `max_heap_size` flag is per-process and is *not* inherited by child
  processes, so the PTC-Lisp `pmap`/`pcalls` builtins spawn each worker
  (via `PtcRunner.Lisp.Eval.ParallelRunner`) with its OWN fixed
  `max_heap_size` of `:worker_max_heap` words, armed at spawn with **no
  re-baseline** — a worker's captured closure environment is
  program-created, which is exactly what `worker_max_heap` exists to
  bill. The number of parallel workers alive at once — across the whole
  run, at every nesting depth — is capped by a shared slot semaphore of
  `:max_parallel_workers` (`PtcRunner.Lisp.Eval.ParallelBudget`).
  Aggregate live parallel heap is therefore bounded by:

      max_parallel_workers × worker_max_heap

  A pmap/pcalls worker that cannot obtain a slot fails the run with
  `:parallel_capacity_exceeded` (no sequential fallback). The top-level
  sandbox process is not counted as a parallel slot.

  The `:max_heap` sandbox limit and each `:worker_max_heap` parallel-worker
  limit are enforced via BEAM's `:max_heap_size` process flag with
  `include_shared_binaries: true`, so they account for both process-local heap
  terms and shared (refc) binaries referenced by the process. This prevents
  binary-heavy programs from exceeding the memory budget via off-heap
  allocations.

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

  `baseline_bytes` is the pre-eval sandbox baseline (granted environment +
  parsed program) measured after the post-copy GC; the program's effective
  heap limit was `baseline_bytes + max_heap × word_size`. `nil` when the
  heap limit is disabled (`max_heap: 0`).
  """
  @type metrics :: %{
          duration_ms: integer(),
          memory_bytes: integer(),
          eval_reductions: non_neg_integer(),
          baseline_bytes: non_neg_integer() | nil
        }

  @typedoc """
  Diagnostic payload for a `:memory_exceeded` kill from `execute/3`.

  `phase: :eval` — the program exceeded its budget above the measured
  baseline. `phase: :setup` — the host environment itself blew the
  `:setup_max_heap` ceiling before eval started (`baseline_bytes` is `nil`;
  raise the ceiling or shrink the grant).
  """
  @type memory_exceeded_info :: %{
          phase: :eval | :setup,
          limit_bytes: non_neg_integer(),
          baseline_bytes: non_neg_integer() | nil,
          budget_bytes: non_neg_integer()
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
      - `:max_heap` - Program heap budget in words above the measured
        baseline (default: 1_250_000, configurable via `:default_max_heap`;
        `0` disables the limit entirely)
      - `:setup_max_heap` - Hard ceiling in words while the host
        environment is copied in, before the re-baseline (default:
        `4 × max_heap`)

  ## Returns
    - `{:ok, result, metrics, memory}` on success
    - `{:error, reason}` on failure; a heap kill is
      `{:memory_exceeded, memory_exceeded_info()}`
  """
  @spec execute(any(), Context.t(), keyword()) ::
          {:ok, any(), metrics(), map()}
          | {:error,
             {atom(), memory_exceeded_info()}
             | {atom(), non_neg_integer()}
             | {atom(), String.t()}
             | {atom(), String.t(), any()}}

  def execute(ast, context, opts \\ []) do
    default_timeout = Application.get_env(:ptc_runner, :default_timeout, @default_timeout)
    default_max_heap = Application.get_env(:ptc_runner, :default_max_heap, @default_max_heap)

    timeout = Keyword.get(opts, :timeout, default_timeout)
    max_heap = Keyword.get(opts, :max_heap, default_max_heap)
    setup_max_heap = Keyword.get(opts, :setup_max_heap, 4 * max_heap)
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
         %{size: setup_max_heap, kill: true, error_logger: false, include_shared_binaries: true}},
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

          # Re-baseline: the spawn copy (context, memory, tools, AST) is
          # host-provided; measure it after a forced GC and re-arm the heap
          # flag at baseline + budget so it doesn't bill the program. The
          # forced GC also deterministically enforces the setup ceiling.
          baseline_words = rebaseline(max_heap)
          send(parent, {:baseline, self(), baseline_words})

          start_reductions = process_reductions()
          result = eval_fn.(ast, context)
          eval_reductions = process_reductions() - start_reductions
          memory = get_process_memory()
          send(parent, {:result, self(), result, memory, eval_reductions})
        end,
        spawn_opts
      )

    await = %{
      pid: pid,
      ref: ref,
      deadline: start_time + timeout,
      start_time: start_time,
      timeout: timeout,
      link?: link?,
      max_heap: max_heap,
      setup_max_heap: setup_max_heap,
      baseline_words: nil
    }

    try do
      await_result(await)
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

  # Wait for the sandbox child: consumes the `{:baseline, _, _}` message the
  # child sends after re-arming its heap flag (needed for kill diagnostics —
  # after a `kill: true` the child can report nothing), then the result or
  # DOWN. Absolute deadline keeps the overall timeout stable across the
  # extra receive iteration.
  defp await_result(await) do
    %{pid: pid, ref: ref} = await
    remaining = max(await.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:baseline, ^pid, baseline_words} ->
        await_result(%{await | baseline_words: baseline_words})

      {:result, ^pid, result, memory, eval_reductions} ->
        duration = System.monotonic_time(:millisecond) - await.start_time

        metrics = %{
          duration_ms: duration,
          memory_bytes: memory,
          eval_reductions: eval_reductions,
          baseline_bytes: baseline_bytes(await.baseline_words, await.max_heap)
        }

        Process.demonitor(ref, [:flush])

        case result do
          {:ok, value, eval_memory} ->
            {:ok, value, metrics, eval_memory}

          {:error, reason, eval_ctx} ->
            # Error with eval_ctx (e.g., from tool execution error with recorded tool_calls)
            # Return as a 4-tuple success with error tagged in the value
            {:ok, {:error_with_ctx, reason}, metrics, eval_ctx}

          {:error, reason} ->
            {:error, reason}
        end

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error, {:memory_exceeded, memory_exceeded_info(await)}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:execution_error, "Process terminated: #{inspect(reason)}"}}
    after
      remaining ->
        # Timeout path: kill the child WITHOUT letting its link signal
        # race with the trap_exit restore (codex review of 0fe4c78).
        # `Process.unlink/1` atomically discards any pending exit
        # signal from `pid` on the link, so the EXIT message cannot
        # reach our mailbox after we restore the prior `trap_exit`.
        Process.demonitor(ref, [:flush])
        if await.link?, do: Process.unlink(pid)
        Process.exit(pid, :kill)

        # Flush stragglers the child may have sent right as the timeout
        # fired — a baseline and/or result left unmatched would leak into
        # the caller's mailbox.
        receive do
          {:baseline, ^pid, _words} -> :ok
        after
          0 -> :ok
        end

        receive do
          {:result, ^pid, _result, _memory, _eval_reductions} -> :ok
        after
          0 -> :ok
        end

        {:error, {:timeout, await.timeout}}
    end
  end

  # No baseline received: the kill happened while the host environment was
  # still being copied/measured under the setup ceiling.
  defp memory_exceeded_info(%{baseline_words: nil} = await) do
    %{
      phase: :setup,
      limit_bytes: await.setup_max_heap * 8,
      baseline_bytes: nil,
      budget_bytes: await.max_heap * 8
    }
  end

  defp memory_exceeded_info(%{baseline_words: baseline_words} = await) do
    %{
      phase: :eval,
      limit_bytes: (baseline_words + await.max_heap) * 8,
      baseline_bytes: baseline_words * 8,
      budget_bytes: await.max_heap * 8
    }
  end

  defp baseline_bytes(nil, _max_heap), do: nil
  defp baseline_bytes(_words, 0), do: nil
  defp baseline_bytes(words, _max_heap), do: words * 8

  # Measure the post-copy baseline and re-arm the heap flag at
  # baseline + budget. `max_heap: 0` means "limit disabled" (BEAM treats
  # flag size 0 as no limit) — measure for metrics but leave the flag alone.
  defp rebaseline(max_heap) do
    :erlang.garbage_collect()
    baseline = measure_baseline_words()

    if max_heap > 0 do
      Process.flag(:max_heap_size, %{
        size: baseline + max_heap,
        kill: true,
        error_logger: false,
        include_shared_binaries: true
      })
    end

    baseline
  end

  # total_heap_size (words) + referenced refc binary bytes converted to
  # words — approximating what `max_heap_size` with
  # `include_shared_binaries: true` compares against. `Process.info(:binary)`
  # itself allocates its result list, so the measurement biases the baseline
  # slightly UP: extra slack for the program, never a false kill.
  defp measure_baseline_words do
    {:total_heap_size, heap_words} = Process.info(self(), :total_heap_size)

    binary_bytes =
      case Process.info(self(), :binary) do
        {:binary, bins} -> Enum.reduce(bins, 0, fn {_id, size, _refc}, acc -> acc + size end)
        nil -> 0
      end

    word_size = :erlang.system_info(:wordsize)
    heap_words + div(binary_bytes + word_size - 1, word_size)
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

  defp process_reductions do
    case Process.info(self(), :reductions) do
      {:reductions, reductions} -> reductions
      nil -> 0
    end
  end
end
