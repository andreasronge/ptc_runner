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
  caveats:

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

  @type timeout_info :: %{
          phase: :eval | :setup,
          timeout_ms: non_neg_integer()
        }

  @typedoc """
  Evaluator function that takes AST and context and returns result with memory.
  """
  @type callback_failure ::
          {atom(), term()}
          | {atom(), term(), term()}
          | {atom(), term(), term(), term()}
  @type failure_reason ::
          {:timeout, timeout_info()}
          | {:memory_exceeded, memory_exceeded_info()}
          | {:execution_error, String.t()}
          | callback_failure()
  @type failure_snapshot :: term()
  @type execute_result ::
          {:ok, term(), metrics(), map()}
          | {:error, failure_reason()}
          | {:error, failure_reason(), failure_snapshot()}
  @type eval_fn :: (term(), term() ->
                      {:ok, term(), map()}
                      | {:error, callback_failure()}
                      | {:error, callback_failure(), map()})
  @type prepare_context_fn :: (term() -> {:ok, term()} | {:error, callback_failure()})
  @type failure_snapshot_fn :: (term() -> term())

  @doc """
  Executes an AST in an isolated sandbox process.

  ## Arguments
    - ast: The AST to execute
    - context: The execution context
    - opts: Options (timeout, max_heap, eval_fn)
      - `:eval_fn` - Evaluator function (required)
      - `:prepare_context` - Optional bounded context normalization performed
        under `:setup_max_heap` before the environment baseline is measured
      - `:failure_snapshot` - Optional bounded callback that extracts rollback
        state from the prepared context. Post-setup failures return it as
        `{:error, reason, snapshot}`.
      - `:timeout` - Timeout in milliseconds (default: 1000, configurable via `:default_timeout`)
      - `:max_heap` - Program heap budget in words above the measured
        baseline (default: 1_250_000, configurable via `:default_max_heap`;
        `0` disables the limit entirely)
      - `:setup_max_heap` - Hard ceiling in words while the host
        environment is copied in, before the re-baseline (default:
        `4 × max_heap`)

  ## Returns
    - `{:ok, result, metrics, memory}` on success
    - `{:error, reason}` on failure; a timeout is
      `{:timeout, timeout_info()}` and a heap kill is
      `{:memory_exceeded, memory_exceeded_info()}`
    - `{:error, reason, snapshot}` on a post-setup failure when
      `:failure_snapshot` is configured
  """
  @spec execute(term(), term(), keyword()) :: execute_result()

  def execute(ast, context, opts \\ []) do
    default_timeout = Application.get_env(:ptc_runner, :default_timeout, @default_timeout)
    default_max_heap = Application.get_env(:ptc_runner, :default_max_heap, @default_max_heap)

    timeout = Keyword.get(opts, :timeout, default_timeout)
    max_heap = Keyword.get(opts, :max_heap, default_max_heap)

    validate_limit!(:timeout, timeout)
    validate_limit!(:max_heap, max_heap)

    setup_max_heap = Keyword.get(opts, :setup_max_heap, 4 * max_heap)
    eval_fn = Keyword.fetch!(opts, :eval_fn)
    prepare_context = Keyword.get(opts, :prepare_context, fn context -> {:ok, context} end)
    failure_snapshot = Keyword.get(opts, :failure_snapshot)
    # When `link: true`, the bounded worker starts a tiny watchdog that monitors
    # both worker and caller. Caller shutdown therefore kills the sandbox
    # without changing the caller's trap-exit behavior.
    link? = Keyword.get(opts, :link, false)

    validate_limit!(:setup_max_heap, setup_max_heap)
    validate_callback!(:eval_fn, eval_fn, 2)
    validate_callback!(:prepare_context, prepare_context, 1)
    validate_optional_callback!(:failure_snapshot, failure_snapshot, 1)
    validate_boolean!(:link, link?)

    start_time = System.monotonic_time(:millisecond)
    reply_alias = Process.alias()

    execution = %{
      link?: link?,
      timeout: timeout,
      max_heap: max_heap,
      setup_max_heap: setup_max_heap,
      start_time: start_time,
      reply_alias: reply_alias,
      failure_snapshot: failure_snapshot,
      telemetry_run: Keyword.get(opts, :telemetry_run)
    }

    try do
      spawn_and_await(ast, context, eval_fn, prepare_context, execution)
    after
      # Covers a spawn failure before a pid/ref exists.
      Process.unalias(reply_alias)
    end
  end

  defp spawn_and_await(ast, context, eval_fn, prepare_context, execution) do
    spawn_opts = [
      {:max_heap_size,
       %{
         size: execution.setup_max_heap,
         kill: true,
         error_logger: false,
         include_shared_binaries: true
       }}
    ]

    {pid, ref} =
      spawn_worker(
        fn ->
          # Set process priority to normal within the process
          Process.flag(:priority, :normal)

          case prepare_context.(context) do
            {:ok, prepared_context} ->
              failure_snapshot = capture_failure_snapshot(execution, prepared_context)

              # Re-baseline: the spawn copy and bounded host normalization are
              # environment setup. Measure them after a forced GC and re-arm
              # the heap flag at baseline + budget so the program is not
              # charged for either.
              baseline_words = rebaseline(execution.max_heap, execution.telemetry_run)
              send_baseline(execution.reply_alias, baseline_words, failure_snapshot)

              start_reductions = process_reductions()
              result = eval_fn.(ast, prepared_context)
              eval_reductions = process_reductions() - start_reductions
              memory = get_process_memory()

              send(
                execution.reply_alias,
                {:result, self(), result, memory, eval_reductions}
              )

            {:error, reason} ->
              send(execution.reply_alias, {:setup_error, self(), reason})
          end
        end,
        spawn_opts,
        execution.link?
      )

    await = %{
      pid: pid,
      ref: ref,
      deadline: execution.start_time + execution.timeout,
      start_time: execution.start_time,
      timeout: execution.timeout,
      max_heap: execution.max_heap,
      setup_max_heap: execution.setup_max_heap,
      baseline_words: nil,
      failure_snapshot: :none,
      reply_alias: execution.reply_alias
    }

    try do
      await_result(await)
    after
      cleanup_worker(pid, ref, execution.reply_alias)
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

      {:baseline, ^pid, baseline_words, failure_snapshot} ->
        await_result(%{
          await
          | baseline_words: baseline_words,
            failure_snapshot: {:some, failure_snapshot}
        })

      {:setup_error, ^pid, reason} ->
        {:error, reason}

      {:result, ^pid, result, memory, eval_reductions} ->
        duration = System.monotonic_time(:millisecond) - await.start_time

        metrics = %{
          duration_ms: duration,
          memory_bytes: memory,
          eval_reductions: eval_reductions,
          baseline_bytes: baseline_bytes(await.baseline_words, await.max_heap)
        }

        case result do
          {:ok, value, eval_memory} ->
            {:ok, value, metrics, eval_memory}

          {:error, reason, eval_ctx} ->
            # Error with eval_ctx (e.g., from tool execution error with recorded tool_calls)
            # Return as a 4-tuple success with error tagged in the value
            error_with_context(reason, metrics, eval_ctx, await.failure_snapshot)

          {:error, reason} ->
            failure(reason, await.failure_snapshot)
        end

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        failure({:memory_exceeded, memory_exceeded_info(await)}, await.failure_snapshot)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        failure(
          {:execution_error, "Process terminated: #{inspect(reason)}"},
          await.failure_snapshot
        )
    after
      remaining ->
        failure({:timeout, timeout_info(await)}, await.failure_snapshot)
    end
  end

  defp cleanup_worker(pid, ref, reply_alias) do
    Process.unalias(reply_alias)

    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    Process.demonitor(ref, [:flush])
    flush_worker_messages(pid)
  end

  # Deactivating the reply alias drops signals that have not reached the
  # mailbox. Flush any replies that arrived just before deactivation.
  defp flush_worker_messages(pid) do
    receive do
      {:baseline, ^pid, _words} ->
        flush_worker_messages(pid)

      {:baseline, ^pid, _words, _failure_snapshot} ->
        flush_worker_messages(pid)

      {:setup_error, ^pid, _reason} ->
        flush_worker_messages(pid)

      {:result, ^pid, _result, _memory, _eval_reductions} ->
        flush_worker_messages(pid)

      {:bounded_result, ^pid, _result} ->
        flush_worker_messages(pid)
    after
      0 -> :ok
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

  defp timeout_info(%{baseline_words: nil, timeout: timeout}),
    do: %{phase: :setup, timeout_ms: timeout}

  defp timeout_info(%{timeout: timeout}),
    do: %{phase: :eval, timeout_ms: timeout}

  defp validate_limit!(_name, value) when is_integer(value) and value >= 0, do: :ok

  defp validate_limit!(name, value) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp validate_callback!(_name, callback, arity) when is_function(callback, arity), do: :ok

  defp validate_callback!(name, callback, arity) do
    raise ArgumentError,
          "#{name} must be a function of arity #{arity}, got: #{inspect(callback)}"
  end

  defp validate_optional_callback!(_name, nil, _arity), do: :ok

  defp validate_optional_callback!(name, callback, arity),
    do: validate_callback!(name, callback, arity)

  defp validate_boolean!(_name, value) when is_boolean(value), do: :ok

  defp validate_boolean!(name, value) do
    raise ArgumentError, "#{name} must be a boolean, got: #{inspect(value)}"
  end

  defp capture_failure_snapshot(%{failure_snapshot: nil}, _prepared_context), do: :none

  defp capture_failure_snapshot(%{failure_snapshot: callback}, prepared_context),
    do: {:some, callback.(prepared_context)}

  defp send_baseline(reply_alias, baseline_words, :none),
    do: send(reply_alias, {:baseline, self(), baseline_words})

  defp send_baseline(reply_alias, baseline_words, {:some, failure_snapshot}),
    do: send(reply_alias, {:baseline, self(), baseline_words, failure_snapshot})

  defp error_with_context(reason, metrics, eval_ctx, :none),
    do: {:ok, {:error_with_ctx, reason}, metrics, eval_ctx}

  defp error_with_context(reason, metrics, eval_ctx, {:some, failure_snapshot}),
    do: {:ok, {:error_with_ctx, reason, failure_snapshot}, metrics, eval_ctx}

  defp failure(reason, :none), do: {:error, reason}
  defp failure(reason, {:some, failure_snapshot}), do: {:error, reason, failure_snapshot}

  defp baseline_bytes(nil, _max_heap), do: nil
  defp baseline_bytes(_words, 0), do: nil
  defp baseline_bytes(words, _max_heap), do: words * 8

  # Measure the post-copy baseline and re-arm the heap flag at
  # baseline + budget. `max_heap: 0` means "limit disabled" (BEAM treats
  # flag size 0 as no limit) — measure for metrics but leave the flag alone.
  defp rebaseline(max_heap, telemetry_run) do
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

    :telemetry.execute(
      [:ptc_runner, :sandbox, :armed],
      %{baseline_words: baseline, ceiling_words: baseline + max_heap},
      maybe_put_live_run(%{pid: self(), max_heap: max_heap}, telemetry_run)
    )

    baseline
  end

  defp maybe_put_live_run(metadata, live_run) when is_pid(live_run),
    do: Map.put(metadata, :live_run, live_run)

  defp maybe_put_live_run(metadata, _live_run), do: metadata

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
    * `:link` - Couple the bounded worker to its caller through a linked
      watchdog (default: false). Caller shutdown cancels the worker without
      changing the caller's trap-exit flag.

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
    link? = Keyword.get(opts, :link, false)

    validate_limit!(:timeout, timeout)
    validate_limit!(:max_heap, max_heap)
    validate_boolean!(:link, link?)

    reply_alias = Process.alias()

    try do
      spawn_and_await_bounded(fun, timeout, max_heap, link?, reply_alias)
    after
      # Covers a spawn failure before a pid/ref exists.
      Process.unalias(reply_alias)
    end
  end

  defp spawn_and_await_bounded(fun, timeout, max_heap, link?, reply_alias) do
    spawn_opts = [
      {:max_heap_size,
       %{size: max_heap, kill: true, error_logger: false, include_shared_binaries: true}}
    ]

    {pid, ref} =
      spawn_worker(
        fn ->
          Process.flag(:priority, :normal)
          result = fun.()
          send(reply_alias, {:bounded_result, self(), result})
        end,
        spawn_opts,
        link?
      )

    try do
      await_bounded_result(pid, ref, timeout, max_heap)
    after
      cleanup_worker(pid, ref, reply_alias)
    end
  end

  defp await_bounded_result(pid, ref, timeout, max_heap) do
    receive do
      {:bounded_result, ^pid, result} ->
        {:ok, result}

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error, {:memory_exceeded, max_heap * 8}}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, {:execution_error, "Process terminated: #{inspect(reason)}"}}
    after
      timeout ->
        {:error, {:timeout, timeout}}
    end
  end

  defp spawn_worker(fun, spawn_opts, false),
    do: Process.spawn(fun, [:monitor | spawn_opts])

  defp spawn_worker(fun, spawn_opts, true) do
    owner = self()

    worker_fun = fn ->
      worker = self()
      ready = make_ref()

      {watchdog, watchdog_ref} =
        spawn_monitor(fn ->
          owner_ref = Process.monitor(owner)
          worker_ref = Process.monitor(worker)
          send(worker, {ready, self()})

          receive do
            {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
              Process.exit(worker, :kill)

            {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
              Process.demonitor(owner_ref, [:flush])
          end
        end)

      receive do
        {^ready, ^watchdog} ->
          Process.demonitor(watchdog_ref, [:flush])
          fun.()

        {:DOWN, ^watchdog_ref, :process, ^watchdog, reason} ->
          exit({:watchdog_start_failed, reason})
      end
    end

    Process.spawn(worker_fun, [:monitor | spawn_opts])
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
