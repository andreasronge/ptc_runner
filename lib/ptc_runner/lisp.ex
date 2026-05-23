defmodule PtcRunner.Lisp do
  @moduledoc """
  Execute PTC programs written in Lisp DSL (Clojure subset).

  PTC-Lisp enables LLMs to write safe programs that orchestrate tools and transform
  data. Unlike raw code execution (Python, JavaScript), PTC-Lisp provides safety by
  design: no filesystem/network access, no unbounded recursion, and deterministic
  execution in isolated BEAM processes with resource limits.

  See the [PTC-Lisp Specification](ptc-lisp-specification.md) for the complete
  language reference.

  ## Tool Registration

  Tools are functions that receive a map of arguments and return results.
  Note: tool names use kebab-case in Lisp (e.g., `"get-user"` not `"get_user"`):

      tools = %{
        "get-user" => fn %{"id" => id} -> MyApp.Users.get(id) end,
        "search" => fn %{"query" => q} -> MyApp.Search.run(q) end
      }

      PtcRunner.Lisp.run(~S|(tool/get-user {:id 123})|, tools: tools)

  **Contract:**
  - Receives: `map()` of arguments (may be empty `%{}`)
  - Returns: Any Elixir term (maps, lists, primitives)
  - Should not raise (return `{:error, reason}` for errors)
  """

  require Logger

  alias PtcRunner.Lisp.{
    Analyze,
    DataKeys,
    Env,
    Eval,
    ExecutionError,
    Parser,
    RuntimeCallable,
    SourceAtoms,
    SymbolCounter
  }

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.ParallelBudget

  # Default capacity of the global parallel-worker slot semaphore (see
  # `PtcRunner.Lisp.Eval.ParallelBudget`). Conservative: with the
  # default ~10 MB (`1_250_000`-word) `worker_max_heap`, the aggregate
  # worst-case parallel heap is bounded at roughly `8 × 10 MB = 80 MB`.
  # The top-level sandbox process is NOT counted as a slot. Overridable
  # per call via the `:max_parallel_workers` option to `run/2`.
  @default_max_parallel_workers 8
  alias PtcRunner.Lisp.Format.Var
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Step
  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.Tool

  @doc """
  Run a PTC-Lisp program.

  ## Parameters

  - `source`: PTC-Lisp source code as a string
  - `opts`: Keyword list of options
    - `:context` - Initial context map (default: %{})
    - `:memory` - Initial memory map (default: %{})
    - `:tools` - Map of tool names to functions (default: %{})
    - `:signature` - Optional signature string for return value validation
    - `:float_precision` - Number of decimal places for floats in result (default: nil = full precision)
    - `:timeout` - Timeout in milliseconds for entire sandbox execution (default: 1000)
    - `:compile_timeout` - Timeout in milliseconds for the compile phase (parse + analyze) (default: 5000)
    - `:pmap_timeout` - Timeout in milliseconds per pmap/pcalls task (default: 5000). Increase for LLM-backed tools.
    - `:pmap_max_concurrency` - Local pmap/pcalls scheduling window — max tasks one call keeps in flight (default: `System.schedulers_online() * 2`). Reduce to avoid overflowing connection pools. The HARD aggregate cap is `:max_parallel_workers`.
    - `:max_heap` - Sandbox-process max heap size in words (default: 1_250_000)
    - `:worker_max_heap` - Fixed `max_heap_size` (words) for every pmap/pcalls worker, top-level and nested (default: the `:max_heap` value)
    - `:max_parallel_workers` - Global cap on pmap/pcalls worker processes alive at once across the whole run, at any nesting depth (default: 8). Aggregate live parallel heap ≈ `max_parallel_workers * worker_max_heap`. A pmap/pcalls that cannot get a slot fails with `:parallel_capacity_exceeded`.
    - `:max_symbols` - Max unique symbols/keywords allowed (default: 10_000)
    - `:max_program_bytes` - Max source code size in bytes (default: 1_000_000)
    - `:max_print_length` - Max characters per `println` call (default: 2000)
    - `:filter_context` - Filter context to only include accessed data keys (default: true)
    - `:budget` - Budget info map for `(budget/remaining)` introspection (default: nil)
    - `:trace_context` - Trace context for nested agent tracing (default: nil)
    - `:caller` - Closed-set tag for telemetry. One of `:in_process_v1`,
      `:text_mode`, or `:mcp` (default: `:in_process_v1`). Pure
      instrumentation: attached to `[:ptc_runner, :lisp, :execute, *]`
      events and otherwise discarded. Out-of-set values raise
      `ArgumentError`.
    - `:profile` - Closed-set telemetry tag for the calling profile.
      One of `:mcp_no_tools`, `:mcp_aggregator`, `:in_process_v1`, or
      `:text_mode`, or `nil` (default). Pure instrumentation: attached
      to `[:ptc_runner, :lisp, :execute, *]` events and otherwise
      discarded. Out-of-set values raise `ArgumentError`. The MCP v1
      handler passes `:mcp_no_tools`; the aggregator (Phase 1a)
      flips it to `:mcp_aggregator`. See
      `Plans/ptc-runner-mcp-aggregator.md` §11.5.

  ## Telemetry

  `run/2` is wrapped in `:telemetry.span/3` and emits the following events:

  - `[:ptc_runner, :lisp, :execute, :start]` — measurements
    `monotonic_time`, `system_time`; metadata `caller`, `profile`,
    `program_bytes`, `signature_supplied?`.
  - `[:ptc_runner, :lisp, :execute, :stop]` — measurements `duration`,
    `monotonic_time`, `result_bytes`, `prints_count`; metadata `caller`,
    `profile`, `program_bytes`, `signature_supplied?`.
  - `[:ptc_runner, :lisp, :execute, :exception]` — measurements `duration`,
    `monotonic_time`; metadata `caller`, `profile`, `program_bytes`,
    `signature_supplied?`, `kind`, `reason`, `stacktrace`.

  ## Return Value

  On success, returns:
  - `{:ok, Step.t()}` with:
    - `step.return`: The value returned to the caller
    - `step.memory`: Complete memory state after execution
    - `step.usage`: Execution metrics (duration_ms, memory_bytes)

  On error, returns:
  - `{:error, Step.t()}` with:
    - `step.fail.reason`: Error reason atom
    - `step.fail.message`: Human-readable error description
    - `step.memory`: Memory state at time of error

  ## Memory Contract

  The top-level program value passes through to `step.return` **unchanged** —
  there is no implicit map merge and no special `:return` key handling. Storage
  is **explicit**: `(def x v)` persists `v` in memory (`step.memory["x"]`), and
  that memory survives across turns within a single `SubAgent` run.

  **Related modules:**
  - `PtcRunner.SubAgent.Loop` - Uses this contract to persist memory across turns
  - `PtcRunner.Lisp.Eval` - Evaluates programs with user_ns (memory) symbol resolution

  ## Float Precision

  When `:float_precision` is set, all floats in the result are rounded to that many decimal places.
  This is useful for LLM-facing applications where excessive precision wastes tokens.

      # Full precision (default)
      {:ok, step} = PtcRunner.Lisp.run("(/ 10 3)")
      step.return
      #=> 3.3333333333333335

      # Rounded to 2 decimals
      {:ok, step} = PtcRunner.Lisp.run("(/ 10 3)", float_precision: 2)
      step.return
      #=> 3.33

  ## Resource Limits

  Lisp programs execute with configurable timeout and memory limits:

      PtcRunner.Lisp.run(source, timeout: 5000, max_heap: 5_000_000)

  Exceeding limits returns an error:
  - `{:error, {:timeout, ms}}` - execution exceeded timeout
  - `{:error, {:memory_exceeded, bytes}}` - heap limit exceeded

  ## Context Filtering

  By default, PTC-Lisp performs static analysis to identify which `data/xxx` keys are accessed
  by a program, then filters the context to only include those datasets. This significantly
  reduces memory pressure when the context contains large datasets that aren't used.

      # Only products is loaded into the sandbox, orders/employees are filtered out
      ctx = %{"products" => large_list, "orders" => large_list, "employees" => large_list}
      PtcRunner.Lisp.run("(count data/products)", context: ctx)

  Scalar context values (strings, numbers, nil) are always preserved as they typically
  represent metadata like prompts or configuration.

  Disable filtering if you need all context available (e.g., for dynamic data access):

      PtcRunner.Lisp.run(source, context: ctx, filter_context: false)

  See `PtcRunner.Lisp.DataKeys` for the static analysis implementation.
  """
  @valid_callers [:in_process_v1, :text_mode, :mcp]
  @valid_profiles [:mcp_no_tools, :mcp_aggregator, :in_process_v1, :text_mode]

  @spec run(String.t(), keyword()) ::
          {:ok, Step.t()} | {:error, Step.t()}
  def run(source, opts \\ []) do
    caller = validate_caller!(Keyword.get(opts, :caller, :in_process_v1))
    profile = validate_profile!(Keyword.get(opts, :profile))
    # Strip :caller / :profile from opts: pure instrumentation; must
    # not affect execution semantics or be re-read by downstream code.
    inner_opts = opts |> Keyword.delete(:caller) |> Keyword.delete(:profile)
    signature_supplied? = not is_nil(Keyword.get(inner_opts, :signature))
    program_bytes = if is_binary(source), do: byte_size(source), else: 0

    start_meta = %{
      caller: caller,
      profile: profile,
      program_bytes: program_bytes,
      signature_supplied?: signature_supplied?
    }

    :telemetry.span([:ptc_runner, :lisp, :execute], start_meta, fn ->
      result = do_run(source, inner_opts)
      {result_bytes, prints_count} = telemetry_result_stats(result)

      stop_meta = %{
        caller: caller,
        profile: profile,
        program_bytes: program_bytes,
        signature_supplied?: signature_supplied?
      }

      {result, %{result_bytes: result_bytes, prints_count: prints_count}, stop_meta}
    end)
  end

  # Closed atom set for :caller telemetry tag. Validated at entry to
  # `run/2` so out-of-set values fail fast and don't reach instrumentation.
  defp validate_caller!(caller) when caller in @valid_callers, do: caller

  defp validate_caller!(other) do
    raise ArgumentError,
          "invalid :caller option #{inspect(other)}; expected one of " <>
            inspect(@valid_callers)
  end

  # Closed atom set for :profile telemetry tag. `nil` (default) is
  # accepted so existing in-process callers don't have to pass it; MCP
  # callsites pass the appropriate profile (`:mcp_no_tools` for v1,
  # `:mcp_aggregator` for the aggregator) per
  # `Plans/ptc-runner-mcp-aggregator.md` §11.5.
  defp validate_profile!(nil), do: nil
  defp validate_profile!(profile) when profile in @valid_profiles, do: profile

  defp validate_profile!(other) do
    raise ArgumentError,
          "invalid :profile option #{inspect(other)}; expected nil or one of " <>
            inspect(@valid_profiles)
  end

  # Compute telemetry stop measurements from the run result.
  defp telemetry_result_stats({tag, %Step{} = step}) when tag in [:ok, :error] do
    bytes = safe_term_bytes(Map.get(step, :return))
    prints = safe_length(Map.get(step, :prints))
    {bytes, prints}
  end

  defp telemetry_result_stats(_other), do: {0, 0}

  defp safe_term_bytes(nil), do: 0

  defp safe_term_bytes(term) do
    :erlang.external_size(term)
  rescue
    _ -> 0
  end

  defp safe_length(nil), do: 0
  defp safe_length(list) when is_list(list), do: length(list)
  defp safe_length(_), do: 0

  @default_max_program_bytes 1_000_000
  @default_compile_timeout 5_000

  @spec do_run(String.t(), keyword()) :: {:ok, Step.t()} | {:error, Step.t()}
  defp do_run(source, opts) do
    ctx = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})
    raw_tools = Keyword.get(opts, :tools, %{})
    signature_str = Keyword.get(opts, :signature)
    float_precision = Keyword.get(opts, :float_precision)
    timeout = Keyword.get(opts, :timeout, 1000)
    max_heap = Keyword.get(opts, :max_heap, 1_250_000)
    # Security H1: every pmap/pcalls worker runs under this FIXED heap
    # cap (default: the sandbox `max_heap`), and the global
    # `max_parallel_workers` semaphore caps how many such workers are
    # alive at once across the whole run. Aggregate live parallel heap
    # is therefore bounded by `max_parallel_workers * worker_max_heap`.
    worker_max_heap = Keyword.get(opts, :worker_max_heap, max_heap)
    max_parallel_workers = Keyword.get(opts, :max_parallel_workers, @default_max_parallel_workers)
    max_symbols = Keyword.get(opts, :max_symbols, 10_000)
    max_program_bytes = Keyword.get(opts, :max_program_bytes, @default_max_program_bytes)
    compile_timeout = Keyword.get(opts, :compile_timeout, @default_compile_timeout)
    turn_history = Keyword.get(opts, :turn_history, [])
    max_print_length = Keyword.get(opts, :max_print_length)
    filter_context = Keyword.get(opts, :filter_context, true)
    budget = Keyword.get(opts, :budget)
    pmap_timeout = Keyword.get(opts, :pmap_timeout)
    pmap_max_concurrency = Keyword.get(opts, :pmap_max_concurrency)
    trace_context = Keyword.get(opts, :trace_context)
    journal = Keyword.get(opts, :journal)
    tool_cache = Keyword.get(opts, :tool_cache, %{})
    max_tool_calls = Keyword.get(opts, :max_tool_calls)
    strict_data = Keyword.get(opts, :strict_data, false)
    catalog_exec = Keyword.get(opts, :catalog_exec)
    link_sandbox = Keyword.get(opts, :link, false)

    # Preflight: reject oversized source before any parsing
    if is_binary(source) and byte_size(source) > max_program_bytes do
      {:error,
       Step.error(
         :program_too_large,
         "program size #{byte_size(source)} bytes exceeds limit of #{max_program_bytes}",
         memory,
         %{},
         journal: journal
       )}
    else
      do_run_inner(source, %{
        ctx: ctx,
        memory: memory,
        raw_tools: raw_tools,
        signature_str: signature_str,
        float_precision: float_precision,
        timeout: timeout,
        max_heap: max_heap,
        worker_max_heap: worker_max_heap,
        max_parallel_workers: max_parallel_workers,
        max_symbols: max_symbols,
        compile_timeout: compile_timeout,
        turn_history: turn_history,
        max_print_length: max_print_length,
        filter_context: filter_context,
        budget: budget,
        pmap_timeout: pmap_timeout,
        pmap_max_concurrency: pmap_max_concurrency,
        trace_context: trace_context,
        journal: journal,
        tool_cache: tool_cache,
        max_tool_calls: max_tool_calls,
        strict_data: strict_data,
        catalog_exec: catalog_exec,
        link: link_sandbox
      })
    end
  end

  defp do_run_inner(source, %{raw_tools: raw_tools, memory: memory, journal: journal} = params) do
    signature_str = params.signature_str

    # Normalize tools to Tool structs
    with :ok <- validate_parallel_config(params.worker_max_heap, params.max_parallel_workers),
         {:ok, normalized_tools} <- normalize_tools(raw_tools),
         {:ok, parsed_signature} <- parse_signature(signature_str) do
      tool_executor = fn name, args ->
        execute_tool(normalized_tools, name, args)
      end

      tools_meta =
        Map.new(normalized_tools, fn {name, tool} -> {name, %{cache: tool.cache}} end)

      opts =
        Map.merge(params, %{
          normalized_tools: normalized_tools,
          tool_executor: tool_executor,
          parsed_signature: parsed_signature,
          signature_str: signature_str,
          tools_meta: tools_meta
        })

      execute_program(source, opts)
    else
      {:error, {:invalid_tool, tool_name, reason}} ->
        {:error,
         Step.error(:invalid_tool, "Tool '#{tool_name}': #{inspect(reason)}", memory, %{},
           journal: journal
         )}

      {:error, {:invalid_signature, msg}} ->
        {:error,
         Step.error(:parse_error, "Invalid signature: #{msg}", memory, %{}, journal: journal)}

      {:error, {:invalid_config, msg}} ->
        {:error, Step.error(:invalid_config, msg, memory, %{}, journal: journal)}
    end
  end

  # P2: validate operator-supplied parallel-worker config before it can
  # reach `Process.spawn`, where a bad `max_heap_size` value would raise
  # a raw `ArgumentError`. `worker_max_heap` must be a positive integer
  # (a valid `max_heap_size` spawn value) or `nil`; `max_parallel_workers`
  # must be a positive integer.
  defp validate_parallel_config(worker_max_heap, max_parallel_workers) do
    cond do
      not (is_nil(worker_max_heap) or (is_integer(worker_max_heap) and worker_max_heap > 0)) ->
        {:error,
         {:invalid_config,
          ":worker_max_heap must be a positive integer (heap words) or nil, got " <>
            inspect(worker_max_heap)}}

      not (is_integer(max_parallel_workers) and max_parallel_workers > 0) ->
        {:error,
         {:invalid_config,
          ":max_parallel_workers must be a positive integer, got " <>
            inspect(max_parallel_workers)}}

      true ->
        :ok
    end
  end

  @doc """
  Validate PTC-Lisp source code without executing it.

  Parses and analyzes the source, then checks for undefined variables.
  Returns `:ok` if valid, or `{:error, messages}` with a list of error strings.

  Accepts optional keyword options to configure compile-phase limits:

    * `:compile_timeout` - Timeout in ms for bounded compile (default: 5000)
    * `:max_heap` - Max heap words for bounded compile (default: 1_250_000)
    * `:max_program_bytes` - Max source size in bytes (default: 1_000_000)

  ## Examples

      iex> PtcRunner.Lisp.validate("(and (map? data/result) (> (count data/result) 0))")
      :ok

      iex> PtcRunner.Lisp.validate("(and (map? foo) true)")
      {:error, ["foo"]}

      iex> PtcRunner.Lisp.validate("(let [x 1] (> x 0))")
      :ok
  """
  @spec validate(String.t(), keyword()) :: :ok | {:error, [String.t()]}
  def validate(source, opts \\ [])

  def validate(source, opts) when is_binary(source) do
    max_program_bytes = Keyword.get(opts, :max_program_bytes, @default_max_program_bytes)
    compile_timeout = Keyword.get(opts, :compile_timeout, @default_compile_timeout)
    max_heap = Keyword.get(opts, :max_heap, 1_250_000)

    if byte_size(source) > max_program_bytes do
      {:error, ["program size #{byte_size(source)} bytes exceeds limit of #{max_program_bytes}"]}
    else
      validate_bounded(source, compile_timeout, max_heap)
    end
  end

  defp validate_bounded(source, compile_timeout, max_heap) do
    compile_fn = fn ->
      with {:ok, raw_ast} <- Parser.parse(source),
           {:ok, core_ast} <- Analyze.analyze(raw_ast) do
        case collect_undefined_vars(core_ast, MapSet.new()) do
          [] -> :ok
          undefined -> {:error, Enum.uniq(undefined)}
        end
      else
        {:error, reason} -> {:error, [format_validate_error(reason)]}
      end
    end

    case PtcRunner.Sandbox.run_bounded(compile_fn,
           timeout: compile_timeout,
           max_heap: max_heap
         ) do
      {:ok, result} ->
        result

      {:error, {:timeout, ms}} ->
        {:error, ["compilation exceeded #{ms}ms limit"]}

      {:error, {:memory_exceeded, bytes}} ->
        {:error, ["compilation exceeded #{bytes} byte heap limit"]}

      {:error, {:execution_error, msg}} ->
        {:error, ["compilation failed: #{msg}"]}
    end
  end

  defp execute_program(source, opts) do
    %{
      memory: memory,
      normalized_tools: normalized_tools,
      max_symbols: max_symbols,
      compile_timeout: compile_timeout,
      journal: journal
    } = opts

    compile_fn = fn ->
      with {:ok, raw_ast} <- Parser.parse(source),
           :ok <- check_symbol_limit(raw_ast, max_symbols, memory, journal),
           {:ok, core_ast} <- Analyze.analyze(raw_ast),
           :ok <- check_undefined_vars(core_ast, memory, journal),
           :ok <- check_undefined_tools(core_ast, normalized_tools, memory, journal) do
        {:ok, core_ast}
      end
    end

    compile_max_heap =
      Application.get_env(:ptc_runner, :default_max_heap, 1_250_000)

    compile_opts = [timeout: compile_timeout, max_heap: compile_max_heap]

    case PtcRunner.Sandbox.run_bounded(compile_fn, compile_opts) do
      {:ok, {:ok, core_ast}} ->
        execute_eval(core_ast, opts)

      {:ok, {:error, _} = compile_error} ->
        handle_compile_error(compile_error, memory, journal)

      {:error, {:timeout, ms}} ->
        {:error,
         Step.error(
           :compile_timeout,
           "compilation exceeded #{ms}ms limit",
           memory,
           %{},
           journal: journal
         )}

      {:error, {:memory_exceeded, bytes}} ->
        {:error,
         Step.error(
           :compile_memory_exceeded,
           "compilation exceeded #{bytes} byte heap limit",
           memory,
           %{},
           journal: journal
         )}

      {:error, {:execution_error, msg}} ->
        {:error,
         Step.error(:compile_error, "compilation failed: #{msg}", memory, %{}, journal: journal)}
    end
  end

  defp handle_compile_error({:error, {:parse_error, msg}}, memory, journal) do
    {:error, Step.error(:parse_error, msg, memory, %{}, journal: journal)}
  end

  defp handle_compile_error({:error, %Step{} = step}, _memory, _journal) do
    {:error, step}
  end

  defp handle_compile_error({:error, {reason_atom, _, _} = reason}, memory, journal)
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, format_error(reason), memory, %{}, journal: journal)}
  end

  defp handle_compile_error({:error, {reason_atom, _} = reason}, memory, journal)
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, format_error(reason), memory, %{}, journal: journal)}
  end

  defp execute_eval(core_ast, opts) do
    %{
      ctx: ctx,
      memory: memory,
      normalized_tools: normalized_tools,
      tool_executor: tool_executor,
      parsed_signature: parsed_signature,
      signature_str: signature_str,
      float_precision: float_precision,
      timeout: timeout,
      max_heap: max_heap,
      worker_max_heap: worker_max_heap,
      max_parallel_workers: max_parallel_workers,
      turn_history: turn_history,
      max_print_length: max_print_length,
      filter_context: filter_context,
      budget: budget,
      pmap_timeout: pmap_timeout,
      pmap_max_concurrency: pmap_max_concurrency,
      trace_context: trace_context,
      journal: journal,
      tool_cache: tool_cache,
      tools_meta: tools_meta,
      max_tool_calls: max_tool_calls,
      strict_data: strict_data,
      catalog_exec: catalog_exec
    } = opts

    filtered_ctx = if filter_context, do: DataKeys.filter_context(core_ast, ctx), else: ctx
    context = PtcRunner.Context.new(filtered_ctx, memory, normalized_tools, turn_history)

    parallel_budget = ParallelBudget.new(max_parallel_workers)

    eval_opts =
      [
        max_print_length: max_print_length,
        budget: budget,
        max_heap: max_heap,
        worker_max_heap: worker_max_heap,
        parallel_budget: parallel_budget,
        pmap_timeout: pmap_timeout,
        pmap_max_concurrency: pmap_max_concurrency,
        trace_context: trace_context,
        journal: journal,
        tool_cache: tool_cache,
        tools_meta: tools_meta,
        max_tool_calls: max_tool_calls,
        strict_data: strict_data,
        catalog_exec: catalog_exec
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    eval_fn = fn _ast, sandbox_context ->
      try do
        Eval.eval_with_context(
          core_ast,
          sandbox_context.ctx,
          sandbox_context.memory,
          Env.initial(),
          tool_executor,
          sandbox_context.turn_history,
          eval_opts
        )
      rescue
        e in ExecutionError ->
          {:error, {e.reason, e.message, e.data}}

        e in PtcRunner.ToolExecutionError ->
          {:error, {:tool_error, e.tool_name, e.message}, e.eval_ctx}

        e ->
          {:error, {:runtime_error, Exception.message(e)}}
      end
    end

    sandbox_opts = [
      timeout: timeout,
      max_heap: max_heap,
      eval_fn: eval_fn,
      link: Map.get(opts, :link, false)
    ]

    case PtcRunner.Sandbox.execute(core_ast, context, sandbox_opts) do
      {:ok, {:return_signal, value}, metrics, %EvalContext{} = eval_ctx} ->
        step =
          apply_memory_contract({:__ptc_return__, value}, float_precision, eval_ctx)

        {:ok, %{step | usage: metrics}}

      {:ok, {:fail_signal, value}, metrics, %EvalContext{} = eval_ctx} ->
        step =
          apply_memory_contract({:__ptc_fail__, value}, float_precision, eval_ctx)

        {:ok, %{step | usage: metrics}}

      {:ok, {:error_with_ctx, reason}, metrics, %EvalContext{} = eval_ctx} ->
        reason_atom = if is_tuple(reason), do: elem(reason, 0), else: reason

        tool_child_traces =
          eval_ctx.tool_calls
          |> Enum.filter(&Map.has_key?(&1, :child_trace_id))
          |> Enum.map(& &1.child_trace_id)

        pmap_child_traces =
          eval_ctx.pmap_calls
          |> Enum.flat_map(& &1.child_trace_ids)

        child_traces = tool_child_traces ++ pmap_child_traces

        tool_child_steps =
          eval_ctx.tool_calls
          |> Enum.filter(&Map.has_key?(&1, :child_step))
          |> Enum.map(& &1.child_step)

        pmap_child_steps =
          eval_ctx.pmap_calls
          |> Enum.flat_map(&Map.get(&1, :child_steps, []))

        child_steps = tool_child_steps ++ pmap_child_steps

        cleaned_tool_calls = Enum.map(eval_ctx.tool_calls, &Map.delete(&1, :child_step))
        cleaned_pmap_calls = Enum.map(eval_ctx.pmap_calls, &Map.delete(&1, :child_steps))

        step = %Step{
          return: nil,
          fail: %{reason: reason_atom, message: format_error(reason)},
          memory: memory,
          signature: nil,
          usage: metrics,
          turns: nil,
          trace_id: nil,
          parent_trace_id: nil,
          field_descriptions: nil,
          prints: eval_ctx.prints,
          tool_calls: cleaned_tool_calls,
          pmap_calls: cleaned_pmap_calls,
          catalog_ops: Enum.reverse(eval_ctx.catalog_ops),
          child_traces: child_traces,
          child_steps: child_steps,
          journal: eval_ctx.journal,
          summaries: eval_ctx.summaries,
          tool_cache: eval_ctx.tool_cache
        }

        {:error, step}

      {:ok, value, metrics, %EvalContext{} = eval_ctx} ->
        step =
          apply_memory_contract(value, float_precision, eval_ctx)

        step_with_usage = %{step | usage: metrics}

        case validate_return_value(parsed_signature, signature_str, step_with_usage) do
          {:ok, validated_step} -> {:ok, validated_step}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:timeout, ms}} ->
        {:error,
         Step.error(:timeout, "execution exceeded #{ms}ms limit", memory, %{}, journal: journal)}

      {:error, {:memory_exceeded, bytes}} ->
        Logger.warning("PTC-Lisp execution killed: heap limit #{bytes} bytes exceeded")

        {:error,
         Step.error(:memory_exceeded, "heap limit #{bytes} bytes exceeded", memory, %{},
           journal: journal
         )}

      {:error, {reason_atom, _, _} = reason} when is_atom(reason_atom) ->
        {:error, Step.error(reason_atom, format_error(reason), memory, %{}, journal: journal)}

      {:error, {reason_atom, _} = reason} when is_atom(reason_atom) ->
        {:error, Step.error(reason_atom, format_error(reason), memory, %{}, journal: journal)}
    end
  end

  @doc """
  Format an error tuple into a human-readable string.

  Useful for displaying errors to users or feeding back to LLMs for retry.

  ## Examples

      iex> PtcRunner.Lisp.format_error({:parse_error, "unexpected token"})
      "Parse error: unexpected token"

      iex> PtcRunner.Lisp.format_error({:eval_error, "undefined variable: x"})
      "Eval error: undefined variable: x"
  """
  @spec format_error(term()) :: String.t()
  def format_error({:parse_error, msg}), do: "Parse error: #{msg}"
  def format_error({:analysis_error, msg}), do: "Analysis error: #{msg}"
  def format_error({:eval_error, msg}), do: "Eval error: #{msg}"

  def format_error({:invalid_placeholder, name}),
    do:
      "Analysis error: placeholder '#{name}' can only be used inside #() anonymous function syntax"

  def format_error({:timeout, ms}), do: "Timeout: execution exceeded #{ms}ms limit"
  def format_error({:memory_exceeded, bytes}), do: "Memory exceeded: #{bytes} byte limit"
  # Handle Analyze errors: {:invalid_arity, atom, message}
  def format_error({:invalid_arity, _atom, msg}) when is_binary(msg), do: "Analysis error: #{msg}"
  # Handle Eval errors with specific types
  def format_error({:unbound_var, name}) do
    msg = Helpers.format_closure_error({:unbound_var, name})
    # Lowercase first letter to match existing style
    <<first::utf8, rest::binary>> = msg
    <<String.downcase(<<first::utf8>>)::binary, rest::binary>>
  end

  def format_error({:not_callable, value}), do: "not callable: #{inspect(value, limit: 3)}"
  def format_error({:arity_error, msg}), do: "arity error: #{msg}"

  # Issue #878: dedicated formatter for unsupported interop methods.
  # Avoids the `:unbound_var` path which would treat the message as a
  # variable name and append an irrelevant hyphen-suggestion hint.
  def format_error({:unsupported_method, name, available}) do
    "Unsupported method '#{name}'. Supported interop methods: #{available}. Use (.method obj) syntax."
  end

  # Issue #884: friendly message for the loop iteration cap (DIV-01).
  # Without this clause, the raw Elixir tuple {:loop_limit_exceeded, 1000}
  # leaks to the LLM via the generic inspect-based fallback.
  def format_error({:loop_limit_exceeded, n}) do
    "Loop iteration limit exceeded (#{n} iterations). Use reduce/map over a finite sequence instead, or split work across smaller loops."
  end

  # Handle tool errors
  def format_error({:unknown_tool, name, []}), do: "Unknown tool: #{name}. No tools available."

  def format_error({:unknown_tool, name, available}),
    do: "Unknown tool: #{name}. Available tools: #{Enum.join(available, ", ")}"

  def format_error({:runtime_error, msg}), do: "Runtime error: #{msg}"
  def format_error({:tool_error, name, reason}), do: "Tool '#{name}' failed: #{inspect(reason)}"
  # Handle other 3-tuple error formats from Eval: {type, message, data}
  def format_error({type, msg, _}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error({type, msg}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  # V2 simplified memory contract: pass through all values unchanged.
  # Storage is explicit via `def` (values persist in user_ns).
  # No implicit map merge or :return key handling.
  defp apply_memory_contract(value, precision, %EvalContext{} = ctx) do
    reversed_tool_calls = Enum.reverse(ctx.tool_calls)
    reversed_pmap_calls = Enum.reverse(ctx.pmap_calls)

    # Extract child_trace_ids from both direct tool calls and pmap/pcalls
    tool_child_traces =
      reversed_tool_calls
      |> Enum.filter(&Map.has_key?(&1, :child_trace_id))
      |> Enum.map(& &1.child_trace_id)

    pmap_child_traces =
      reversed_pmap_calls
      |> Enum.flat_map(& &1.child_trace_ids)

    child_traces = tool_child_traces ++ pmap_child_traces

    # Extract child_steps from tool calls and pmap/pcalls
    tool_child_steps =
      reversed_tool_calls
      |> Enum.filter(&Map.has_key?(&1, :child_step))
      |> Enum.map(& &1.child_step)

    pmap_child_steps =
      reversed_pmap_calls
      |> Enum.flat_map(&Map.get(&1, :child_steps, []))

    child_steps = tool_child_steps ++ pmap_child_steps

    # Strip child_step/child_steps from tool/pmap_calls to avoid double storage
    cleaned_tool_calls = Enum.map(reversed_tool_calls, &Map.delete(&1, :child_step))
    cleaned_pmap_calls = Enum.map(reversed_pmap_calls, &Map.delete(&1, :child_steps))

    %Step{
      return: value |> externalize_lisp_values() |> round_floats(precision),
      fail: nil,
      memory: externalize_memory(ctx.user_ns),
      journal: ctx.journal,
      summaries: ctx.summaries,
      tool_cache: ctx.tool_cache,
      signature: nil,
      usage: nil,
      turns: nil,
      prints: Enum.reverse(ctx.prints),
      tool_calls: cleaned_tool_calls,
      pmap_calls: cleaned_pmap_calls,
      catalog_ops: Enum.reverse(ctx.catalog_ops),
      child_traces: child_traces,
      child_steps: child_steps
    }
  end

  # Round floats recursively in nested structures
  defp round_floats(value, nil), do: value

  defp round_floats(value, precision) when is_float(value) do
    Float.round(value, precision)
  end

  defp round_floats(value, precision) when is_list(value) do
    Enum.map(value, &round_floats(&1, precision))
  end

  defp round_floats(value, precision) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {k, round_floats(v, precision)} end)
  end

  # Handle sentinel tuples for return/fail signals
  defp round_floats({:__ptc_return__, inner}, precision) do
    {:__ptc_return__, round_floats(inner, precision)}
  end

  defp round_floats({:__ptc_fail__, inner}, precision) do
    {:__ptc_fail__, round_floats(inner, precision)}
  end

  defp round_floats(value, _precision), do: value

  # Collapse runtime keyword structs deterministically: `SourceAtoms.intern/1`
  # yields the bounded atom for vocabulary names and the plain binary for
  # everything else. This never consults the global atom table, so the
  # externalized representation no longer depends on VM state (#964), and it
  # matches the parser's canonicalization plus the string-keyed SubAgent
  # boundary contract (signature validation, mustache, chaining).
  defp externalize_lisp_values(%LispKeyword{name: name}), do: SourceAtoms.intern(name)

  defp externalize_lisp_values(%RuntimeCallable{} = callable) do
    RuntimeCallable.label(callable)
  end

  defp externalize_lisp_values(%Var{name: name} = var) when is_binary(name) do
    %{var | name: existing_atom_or(name, name)}
  end

  defp externalize_lisp_values({:__ptc_return__, inner}) do
    {:__ptc_return__, externalize_lisp_values(inner)}
  end

  defp externalize_lisp_values({:__ptc_fail__, inner}) do
    {:__ptc_fail__, externalize_lisp_values(inner)}
  end

  defp externalize_lisp_values(value) when is_list(value) do
    Enum.map(value, &externalize_lisp_values/1)
  end

  defp externalize_lisp_values(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} ->
      {externalize_lisp_values(k), externalize_lisp_values(v)}
    end)
  end

  defp externalize_lisp_values(value), do: value

  defp externalize_memory(memory) when is_map(memory) do
    memory
    |> Enum.reject(fn {_k, v} -> match?(%PtcRunner.Lisp.RuntimeCallable{}, v) end)
    |> Map.new(fn {k, v} ->
      {externalize_memory_key(k), externalize_lisp_values(v)}
    end)
  end

  # Memory keys are `def`-bound variable names. Externalize them through the
  # same bounded vocabulary as parsed symbols: builtin names remain atoms,
  # user-defined names remain binaries, and unrelated VM atom-table state is
  # ignored.
  defp externalize_memory_key(%LispKeyword{name: name}), do: SourceAtoms.intern(name)
  defp externalize_memory_key(name) when is_binary(name), do: SourceAtoms.intern(name)
  defp externalize_memory_key(other), do: other

  defp existing_atom_or(name, fallback) when is_binary(name) do
    case safe_to_existing_atom(name) do
      {:ok, atom} -> atom
      :error -> fallback
    end
  end

  # Check if symbol count exceeds limit
  defp check_symbol_limit(ast, max_symbols, memory, journal) do
    count = SymbolCounter.count(ast)

    if count <= max_symbols do
      :ok
    else
      {:error,
       Step.error(
         :symbol_limit_exceeded,
         "program contains #{count} unique symbols/keywords, exceeds limit of #{max_symbols}",
         memory,
         %{},
         journal: journal
       )}
    end
  end

  # Pre-execution check: reject programs with undefined variables before any
  # side effects (tool calls) can execute. Memory keys are included in scope
  # to support multi-turn SubAgent execution where previous turns def'd variables.
  defp check_undefined_vars(core_ast, memory, journal) do
    initial_scope = memory |> Map.keys() |> MapSet.new()

    case collect_undefined_vars(core_ast, initial_scope) do
      [] ->
        :ok

      undefined ->
        vars = Enum.uniq(undefined)

        label = if length(vars) == 1, do: "Undefined variable", else: "Undefined variables"

        {:error,
         Step.error(
           :unbound_var,
           "#{label}: #{Enum.join(vars, ", ")}",
           memory,
           %{},
           journal: journal
         )}
    end
  end

  # Pre-execution check: reject programs that reference tools not in the provided
  # toolset, preventing partial execution where early tool calls succeed before
  # a later unknown tool call crashes.
  defp check_undefined_tools(_core_ast, normalized_tools, _memory, _journal)
       when map_size(normalized_tools) == 0,
       do: :ok

  defp check_undefined_tools(core_ast, normalized_tools, memory, journal) do
    # CoreAST tool names are atoms, normalized_tools keys are strings — convert to strings
    referenced =
      core_ast |> collect_tool_names() |> MapSet.new(fn name -> to_string(name) end)

    available = MapSet.new(Map.keys(normalized_tools))
    undefined = MapSet.difference(referenced, available)

    if MapSet.size(undefined) == 0 do
      :ok
    else
      names = undefined |> MapSet.to_list() |> Enum.sort()
      label = if length(names) == 1, do: "Unknown tool", else: "Unknown tools"

      hint =
        case MapSet.to_list(available) |> Enum.sort() do
          [] -> "No tools available."
          tools -> "Available tools: #{Enum.join(tools, ", ")}"
        end

      {:error,
       Step.error(
         :unknown_tool,
         "#{label}: #{Enum.join(names, ", ")}. #{hint}",
         memory,
         %{},
         journal: journal
       )}
    end
  end

  # Collect all tool names referenced in the CoreAST
  defp collect_tool_names(ast), do: collect_tool_names(ast, MapSet.new())

  defp collect_tool_names({:tool_call, name, args}, acc) do
    Enum.reduce(args, MapSet.put(acc, name), &collect_tool_names/2)
  end

  defp collect_tool_names({:runtime_callable, :tool, name}, acc), do: MapSet.put(acc, name)
  defp collect_tool_names({:runtime_callable, _namespace, _name}, acc), do: acc

  defp collect_tool_names({:do, exprs}, acc) do
    Enum.reduce(exprs, acc, &collect_tool_names/2)
  end

  defp collect_tool_names({:let, bindings, body}, acc) do
    acc =
      Enum.reduce(bindings, acc, fn {:binding, _pat, val}, a -> collect_tool_names(val, a) end)

    collect_tool_names(body, acc)
  end

  defp collect_tool_names({:fn, _params, body}, acc), do: collect_tool_names(body, acc)

  defp collect_tool_names({:loop, bindings, body}, acc) do
    acc =
      Enum.reduce(bindings, acc, fn {:binding, _pat, val}, a -> collect_tool_names(val, a) end)

    collect_tool_names(body, acc)
  end

  defp collect_tool_names({:call, target, args}, acc) do
    acc = collect_tool_names(target, acc)
    Enum.reduce(args, acc, &collect_tool_names/2)
  end

  defp collect_tool_names({:if, c, t, e}, acc) do
    acc = collect_tool_names(c, acc)
    acc = collect_tool_names(t, acc)
    collect_tool_names(e, acc)
  end

  defp collect_tool_names({:and, exprs}, acc), do: Enum.reduce(exprs, acc, &collect_tool_names/2)
  defp collect_tool_names({:or, exprs}, acc), do: Enum.reduce(exprs, acc, &collect_tool_names/2)
  defp collect_tool_names({:return, val}, acc), do: collect_tool_names(val, acc)
  defp collect_tool_names({:fail, val}, acc), do: collect_tool_names(val, acc)
  defp collect_tool_names({:recur, args}, acc), do: Enum.reduce(args, acc, &collect_tool_names/2)
  defp collect_tool_names({:def, _name, val, _meta}, acc), do: collect_tool_names(val, acc)

  defp collect_tool_names({:vector, elems}, acc),
    do: Enum.reduce(elems, acc, &collect_tool_names/2)

  defp collect_tool_names({:map, pairs}, acc) do
    Enum.reduce(pairs, acc, fn {k, v}, a ->
      a = collect_tool_names(k, a)
      collect_tool_names(v, a)
    end)
  end

  defp collect_tool_names({:set, elems}, acc), do: Enum.reduce(elems, acc, &collect_tool_names/2)

  defp collect_tool_names({:pmap, fn_expr, coll}, acc) do
    acc = collect_tool_names(fn_expr, acc)
    collect_tool_names(coll, acc)
  end

  defp collect_tool_names({:pcalls, fns}, acc), do: Enum.reduce(fns, acc, &collect_tool_names/2)

  defp collect_tool_names({:task, _id, body}, acc), do: collect_tool_names(body, acc)

  defp collect_tool_names({:task_dynamic, id, body}, acc) do
    acc = collect_tool_names(id, acc)
    collect_tool_names(body, acc)
  end

  defp collect_tool_names({:step_done, id, summary}, acc) do
    acc = collect_tool_names(id, acc)
    collect_tool_names(summary, acc)
  end

  defp collect_tool_names({:task_reset, id}, acc), do: collect_tool_names(id, acc)

  defp collect_tool_names({:juxt, fns}, acc), do: Enum.reduce(fns, acc, &collect_tool_names/2)

  defp collect_tool_names(_other, acc), do: acc

  defp execute_tool(normalized_tools, name, args) do
    case Map.fetch(normalized_tools, name) do
      {:ok, %Tool{function: fun}} ->
        case fun.(args) do
          {:ok, value} ->
            value

          {:error, reason} ->
            raise ExecutionError, reason: :tool_error, message: name, data: reason

          value ->
            value
        end

      :error ->
        available = Map.keys(normalized_tools) |> Enum.sort()
        raise ExecutionError, reason: :unknown_tool, message: name, data: available
    end
  end

  # Normalize tools from various formats to Tool structs
  defp normalize_tools(raw_tools) do
    Enum.reduce_while(raw_tools, {:ok, %{}}, fn {name, format}, {:ok, acc} ->
      case Tool.new(name, format) do
        {:ok, tool} -> {:cont, {:ok, Map.put(acc, name, tool)}}
        {:error, reason} -> {:halt, {:error, {:invalid_tool, name, reason}}}
      end
    end)
  end

  # Parse signature if provided
  defp parse_signature(nil), do: {:ok, nil}

  defp parse_signature(signature_str) when is_binary(signature_str) do
    case Signature.parse(signature_str) do
      {:ok, sig} -> {:ok, sig}
      {:error, msg} -> {:error, {:invalid_signature, msg}}
    end
  end

  # Validate return value against signature
  defp validate_return_value(nil, _signature_str, step), do: {:ok, step}

  defp validate_return_value(parsed_signature, signature_str, step) do
    case Signature.validate(parsed_signature, step.return) do
      :ok ->
        # Store the original signature string in the step
        {:ok, %{step | signature: signature_str}}

      {:error, errors} ->
        msg = format_validation_errors(errors)

        {:error,
         Step.error(:validation_error, msg, step.memory, %{},
           journal: step.journal,
           tool_cache: step.tool_cache
         )}
    end
  end

  # Format validation errors into a readable message
  defp format_validation_errors(errors) do
    Enum.map_join(errors, "; ", fn %{path: path, message: message} ->
      path_str = format_path(path)
      "#{path_str}: #{message}"
    end)
  end

  defp format_path([]), do: "return"
  defp format_path(path), do: "return." <> Enum.join(path, ".")

  # ============================================================
  # validate/1 helpers — walk CoreAST collecting undefined vars
  # ============================================================

  # Variable reference — check builtins and local scope
  defp collect_undefined_vars({:var, name}, scope) do
    name_str = to_string(name)

    # Skip interop method names (e.g., .toString) — validity checked at runtime
    if String.starts_with?(name_str, ".") or Env.builtin?(name) or scope_member?(scope, name) do
      []
    else
      [name_str]
    end
  end

  # Data access — always valid
  defp collect_undefined_vars({:data, _key}, _scope), do: []

  # Literals
  defp collect_undefined_vars(nil, _scope), do: []
  defp collect_undefined_vars(n, _scope) when is_number(n), do: []
  defp collect_undefined_vars(b, _scope) when is_boolean(b), do: []
  defp collect_undefined_vars({:string, _}, _scope), do: []
  defp collect_undefined_vars({:keyword, _}, _scope), do: []
  defp collect_undefined_vars({:literal, _}, _scope), do: []
  defp collect_undefined_vars(a, _scope) when a in [:infinity, :negative_infinity, :nan], do: []

  # Let bindings — extend scope with bound vars
  defp collect_undefined_vars({:let, bindings, body}, scope) do
    {binding_errors, extended_scope} = reduce_bindings(bindings, scope)
    binding_errors ++ collect_undefined_vars(body, extended_scope)
  end

  # fn — extend scope with param vars
  defp collect_undefined_vars({:fn, params, body}, scope) do
    param_names = fn_param_vars(params)
    extended_scope = Enum.reduce(param_names, scope, &MapSet.put(&2, &1))
    collect_undefined_vars(body, extended_scope)
  end

  # loop — extend scope with binding vars
  defp collect_undefined_vars({:loop, bindings, body}, scope) do
    {binding_errors, extended_scope} = reduce_bindings(bindings, scope)
    binding_errors ++ collect_undefined_vars(body, extended_scope)
  end

  # Function call
  defp collect_undefined_vars({:call, target, args}, scope) do
    collect_undefined_vars(target, scope) ++
      Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  # Tool call
  defp collect_undefined_vars({:tool_call, _name, args}, scope) do
    Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:runtime_callable, _namespace, _name}, _scope), do: []

  # def / defonce — add name to scope before recursing (enables recursive defn)
  defp collect_undefined_vars({:def, name, value, _meta}, scope) do
    collect_undefined_vars(value, MapSet.put(scope, name))
  end

  defp collect_undefined_vars({:defonce, name, value, _opts}, scope) do
    collect_undefined_vars(value, MapSet.put(scope, name))
  end

  # Control flow
  defp collect_undefined_vars({:if, c, t, e}, scope) do
    collect_undefined_vars(c, scope) ++
      collect_undefined_vars(t, scope) ++ collect_undefined_vars(e, scope)
  end

  defp collect_undefined_vars({:do, exprs}, scope) do
    {errors, _final_scope} =
      Enum.reduce(exprs, {[], scope}, fn expr, {errs, sc} ->
        new_errs = collect_undefined_vars(expr, sc)
        new_sc = Enum.reduce(extract_def_names(expr), sc, &MapSet.put(&2, &1))
        {errs ++ new_errs, new_sc}
      end)

    errors
  end

  defp collect_undefined_vars({:and, exprs}, scope) do
    Enum.flat_map(exprs, &collect_undefined_vars(&1, scope))
  end

  # `or` treats unbound vars as nil at runtime (see eval.ex), so bare variable
  # references inside `or` are safe — skip them in the static check.  This
  # supports the common `(or my-var default)` pattern for memory initialisation.
  defp collect_undefined_vars({:or, exprs}, scope) do
    Enum.flat_map(exprs, fn
      {:var, _} -> []
      expr -> collect_undefined_vars(expr, scope)
    end)
  end

  defp collect_undefined_vars({:return, value}, scope) do
    collect_undefined_vars(value, scope)
  end

  defp collect_undefined_vars({:fail, value}, scope) do
    collect_undefined_vars(value, scope)
  end

  defp collect_undefined_vars({:recur, args}, scope) do
    Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  # Collections
  defp collect_undefined_vars({:vector, elems}, scope) do
    Enum.flat_map(elems, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:map, pairs}, scope) do
    Enum.flat_map(pairs, fn {k, v} ->
      collect_undefined_vars(k, scope) ++ collect_undefined_vars(v, scope)
    end)
  end

  defp collect_undefined_vars({:set, elems}, scope) do
    Enum.flat_map(elems, &collect_undefined_vars(&1, scope))
  end

  # Juxt
  defp collect_undefined_vars({:juxt, fns}, scope) do
    Enum.flat_map(fns, &collect_undefined_vars(&1, scope))
  end

  # Parallel operations
  defp collect_undefined_vars({:pmap, fn_expr, coll_expr}, scope) do
    collect_undefined_vars(fn_expr, scope) ++ collect_undefined_vars(coll_expr, scope)
  end

  defp collect_undefined_vars({:pcalls, fn_exprs}, scope) do
    Enum.flat_map(fn_exprs, &collect_undefined_vars(&1, scope))
  end

  # Task/step operations
  defp collect_undefined_vars({:task, _id, body}, scope) do
    collect_undefined_vars(body, scope)
  end

  defp collect_undefined_vars({:task_dynamic, id_expr, body}, scope) do
    collect_undefined_vars(id_expr, scope) ++ collect_undefined_vars(body, scope)
  end

  defp collect_undefined_vars({:step_done, id, summary}, scope) do
    collect_undefined_vars(id, scope) ++ collect_undefined_vars(summary, scope)
  end

  defp collect_undefined_vars({:task_reset, id}, scope) do
    collect_undefined_vars(id, scope)
  end

  # Budget/turn history
  defp collect_undefined_vars({:budget_remaining}, _scope), do: []
  defp collect_undefined_vars({:turn_history, _n}, _scope), do: []

  # Catch-all: safe to skip unknown nodes (runtime eval still catches real errors).
  # Log in debug to surface missing clauses when CoreAST is extended.
  defp collect_undefined_vars(other, _scope) do
    Logger.debug("collect_undefined_vars: unhandled node #{inspect(other, limit: 3)}")
    []
  end

  defp reduce_bindings(bindings, scope) do
    Enum.reduce(bindings, {[], scope}, fn {:binding, pattern, value}, {errs, sc} ->
      value_errs = collect_undefined_vars(value, sc)
      new_scope = Enum.reduce(pattern_vars(pattern), sc, &MapSet.put(&2, &1))
      {errs ++ value_errs, new_scope}
    end)
  end

  # Extract def/defonce names from definite-execution contexts only.
  # Used to propagate top-level vars across program expressions in {:do, ...}.
  # Only recurses into forms guaranteed to execute: do, let, loop.
  # Does NOT recurse into conditional (if, and, or) or deferred (fn) forms.
  defp extract_def_names({:def, name, _value, _meta}), do: [name]
  defp extract_def_names({:defonce, name, _value, _meta}), do: [name]
  defp extract_def_names({:do, exprs}), do: Enum.flat_map(exprs, &extract_def_names/1)

  defp extract_def_names({:let, bindings, body}) do
    Enum.flat_map(bindings, fn {:binding, _pat, value} -> extract_def_names(value) end) ++
      extract_def_names(body)
  end

  defp extract_def_names({:loop, bindings, body}) do
    Enum.flat_map(bindings, fn {:binding, _pat, value} -> extract_def_names(value) end) ++
      extract_def_names(body)
  end

  defp extract_def_names(_), do: []

  # Extract variable names from fn params
  defp fn_param_vars(params) when is_list(params) do
    Enum.flat_map(params, &pattern_vars/1)
  end

  defp fn_param_vars({:variadic, leading, rest_pattern}) do
    Enum.flat_map(leading, &pattern_vars/1) ++ pattern_vars(rest_pattern)
  end

  # Extract all variable names from a destructuring pattern
  defp pattern_vars({:var, name}), do: [name]

  defp pattern_vars({:destructure, {:keys, keys, _defaults}}) do
    keys
  end

  defp pattern_vars({:destructure, {:map, keys, renames, _defaults}}) do
    keys ++
      Enum.flat_map(renames, fn {target_pattern, _source_key} -> pattern_vars(target_pattern) end)
  end

  defp pattern_vars({:destructure, {:as, name, inner}}) do
    [name | pattern_vars(inner)]
  end

  defp pattern_vars({:destructure, {:seq, patterns}}) do
    Enum.flat_map(patterns, &pattern_vars/1)
  end

  defp pattern_vars({:destructure, {:seq_rest, leading, rest}}) do
    Enum.flat_map(leading, &pattern_vars/1) ++ pattern_vars(rest)
  end

  defp pattern_vars(_other), do: []

  defp scope_member?(scope, name) do
    MapSet.member?(scope, name) or
      (is_binary(name) and
         case safe_to_existing_atom(name) do
           {:ok, atom} -> MapSet.member?(scope, atom)
           :error -> false
         end)
  end

  defp safe_to_existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  # Format errors from parse/analyze for validate/1
  defp format_validate_error({:parse_error, msg}), do: "Parse error: #{msg}"

  defp format_validate_error({:invalid_arity, _form, msg}), do: "Analysis error: #{msg}"

  defp format_validate_error({:invalid_placeholder, name}),
    do:
      "Analysis error: placeholder '#{name}' can only be used inside #() anonymous function syntax"

  defp format_validate_error({type, msg}) when is_atom(type) and is_binary(msg),
    do: "#{type}: #{msg}"

  defp format_validate_error(other), do: "Error: #{inspect(other)}"
end
