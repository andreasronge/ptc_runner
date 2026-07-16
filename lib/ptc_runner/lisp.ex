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
    Format,
    Parser,
    RuntimeCallable,
    SourceAtoms,
    SymbolCounter
  }

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.ParallelBudget
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Attach, as: PreludeAttach
  alias PtcRunner.Lisp.Prelude.AttachContext, as: PreludeAttachContext
  alias PtcRunner.Lisp.Prelude.ValidationError, as: PreludeValidationError

  # Default capacity of the global parallel-worker slot semaphore (see
  # `PtcRunner.Lisp.Eval.ParallelBudget`). Conservative: with the
  # default ~10 MB (`1_250_000`-word) `worker_max_heap`, the aggregate
  # worst-case parallel heap is bounded at roughly `8 × 10 MB = 80 MB`.
  # The top-level sandbox process is NOT counted as a slot. Overridable
  # per call via the `:max_parallel_workers` option to `run/2`.
  @default_max_parallel_workers 8
  alias PtcRunner.Lisp.AmbiguousArguments
  alias PtcRunner.Lisp.Format.Var
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Result, as: Step
  alias PtcRunner.Lisp.Signature
  alias PtcRunner.Lisp.Tool

  @valid_callers [:direct, :kernel, :repl]

  @doc """
  Format a PTC-Lisp value as Clojure-style syntax for display.

  This is the public wrapper around `PtcRunner.Lisp.Format.to_clojure/2` used by
  LLM-facing renderers and embedding applications.

  Returns `{formatted_string, truncated?}`.

  ## Examples

      iex> PtcRunner.Lisp.format_value(%{count: 2, ids: [1, 2]})
      {"{:count 2 :ids [1 2]}", false}

      iex> PtcRunner.Lisp.format_value([1, 2, 3], limit: 2)
      {"[1 2 ...] (2/3)", true}
  """
  @spec format_value(term(), keyword()) :: {String.t(), boolean()}
  def format_value(value, opts \\ []) do
    Format.to_clojure(value, opts)
  end

  @doc """
  Converts native PTC-Lisp runtime values into the public Elixir/JSON-facing
  representation used by `PtcRunner.Lisp.Result.return`.

  Stateful hosts may keep native values internally between turns, but should use
  this at public observation boundaries such as final steps and trace events.
  """
  @spec externalize_value(term()) :: term()
  def externalize_value(value), do: externalize_lisp_values(value)

  @doc """
  Converts a PTC-Lisp memory map into the public memory representation.

  Unlike `externalize_value/1`, this also normalizes top-level `def` binding
  keys through the bounded source vocabulary.
  """
  @spec externalize_memory(map()) :: map()
  def externalize_memory(memory) when is_map(memory) do
    memory
    |> Enum.reject(fn {_k, v} -> match?(%PtcRunner.Lisp.RuntimeCallable{}, v) end)
    |> Map.new(fn {k, v} ->
      {externalize_memory_key(k), externalize_lisp_values(v)}
    end)
  end

  @doc """
  Run a PTC-Lisp program.

  ## Parameters

  - `source`: PTC-Lisp source code as a string
  - `opts`: Keyword list of options
    - `:context` - Initial context map (default: %{})
    - `:memory` - Initial memory map (default: %{})
    - `:turn_history` - Prior turn return values, oldest first, used by
      `*1`, `*2`, and `*3` (default: `[]`)
    - `:tools` - Map of tool names to functions (default: %{})
    - `:signature` - Optional signature string for return value validation
    - `:float_precision` - Number of decimal places for floats in result (default: nil = full precision)
    - `:timeout` - Timeout in milliseconds for entire sandbox execution (default: 1000)
    - `:compile_timeout` - Timeout in milliseconds for the compile phase (parse + analyze) (default: 5000)
    - `:pmap_timeout` - Timeout in milliseconds per pmap/pcalls task (default: 5000). Increase for LLM-backed tools.
    - `:pmap_max_concurrency` - Local pmap/pcalls scheduling window — max tasks one call keeps in flight (default: `System.schedulers_online() * 2`). Reduce to avoid overflowing connection pools. The HARD aggregate cap is `:max_parallel_workers`.
    - `:max_heap` - Program heap budget in words ABOVE the measured
      environment baseline (default: 1_250_000). Host-provided data
      (context, `:memory`, tool closures, the parsed program) is measured
      after spawn and excluded from this budget — see
      `PtcRunner.Sandbox` for the re-baseline semantics.
    - `:setup_max_heap` - Hard heap ceiling in words while the host
      environment is copied into the sandbox, before the re-baseline
      (default: `4 × max_heap`). Callers granting large tools/memory must
      raise this explicitly; exceeding it fails with a setup-phase
      `:memory_exceeded` error.
    - `:worker_max_heap` - Fixed `max_heap_size` (words) for every pmap/pcalls worker, top-level and nested (default: the `:max_heap` value)
    - `:max_parallel_workers` - Global cap on pmap/pcalls worker processes alive at once across the whole run, at any nesting depth (default: 8). Aggregate live parallel heap ≈ `max_parallel_workers * worker_max_heap`. A pmap/pcalls that cannot get a slot fails with `:parallel_capacity_exceeded`.
    - `:max_symbols` - Max unique symbols/keywords allowed (default: 10_000)
    - `:max_program_bytes` - Max source code size in bytes (default: 1_000_000)
    - `:max_print_length` - Max characters per `println` call (default: 2000)
    - `:filter_context` - Filter context to only include accessed data keys (default: true)
    - `:prelude` - A compiled `%PtcRunner.Lisp.Prelude{}` artifact, a prelude
      SOURCE string, or a list of source-bearing selection maps accepted by
      `PtcRunner.Lisp.Prelude.Bundle.compile/1` to attach before user code
      (Capability Prelude V1). Source selections are concatenated and compiled
      once in explicit order after duplicate namespace rejection. The attached
      prelude's protected namespaces and public export table are consulted by
      the analyzer/evaluator so qualified prelude calls (e.g. `crm/get-user`)
      resolve, while private helpers stay user-invisible. Compile/attach
      failures return `{:error, Step}`. Attach-time `tool:<name>`
      requirements are checked against the granted `:tools` map. (default: nil)
    - `:caller` - Closed-set tag for telemetry. One of `:direct`, `:kernel`,
      or `:repl` (default: `:direct`). Pure
      instrumentation: attached to `[:ptc_runner, :lisp, :execute, *]`
      events and otherwise discarded. Out-of-set values raise
      `ArgumentError`.

  ## Telemetry

  `run/2` emits the following events:

  - `[:ptc_runner, :lisp, :execute, :start]` — measurements
    `monotonic_time`, `system_time`; metadata `caller`,
    `program_bytes`, `signature_supplied?`.
  - `[:ptc_runner, :lisp, :execute, :stop]` — measurements `duration`,
    `monotonic_time`, `result_bytes`, `prints_count`; metadata `caller`,
    `program_bytes`, `signature_supplied?`, and semantic `outcome`.
  - `[:ptc_runner, :lisp, :execute, :exception]` — measurements `duration`,
    `monotonic_time`; metadata `caller`, `program_bytes`,
    `signature_supplied?`, and `exception_class`. Exception reasons,
    stacktraces, source, arguments, and results are never attached.

  ## Return Value

  On success, returns:
   - `{:ok, PtcRunner.Lisp.Result.t()}` with:
     - `step.return`: The value returned to the caller
     - `step.memory`: Data memory after execution. Direct Lisp callers can pass
       it back through the `:memory` option on a later eval; use
       `externalize_memory/1` when you need a purely public observation shape.
       The `run/2` result preserves closures and
       composed callable forms, but deliberately omits top-level runtime
       callables such as directly bound builtin/tool aliases and renders nested
       runtime callables as labels. Do not serialize `step.memory` (JSON,
       ETF-to-disk, database) between evals —
       serialization silently converts native values such as keywords into
       plain strings. For persistent or cross-process REPL state, use
       `PtcRunner.Kernel.ReplSession`, which owns continuation memory.
     - `step.usage`: Execution metrics (`duration_ms`, `memory_bytes`,
       `eval_reductions`)

  On error, returns:
  - `{:error, PtcRunner.Lisp.Result.t()}` with:
    - `step.fail.reason`: Error reason atom
    - `step.fail.message`: Human-readable error description
    - `step.memory`: Native continuation memory at the time of error, with the
      same callable caveats as successful `run/2` results. Do not serialize it;
      use `externalize_memory/1` for an observation-only projection.

  ## Memory Contract

  The top-level program value passes through to `step.return` **unchanged** —
  there is no implicit map merge and no special `:return` key handling. Storage
  is **explicit**: `(def x v)` persists `v` in memory (`step.memory["x"]`), and
  that memory can survive across explicitly managed evaluations.

  There are two deliberate host memory projections. Ordinary embedders may use
  `run/2` to continue data definitions, `defn` closures, and composed
  callable forms by threading `step.memory` directly into the next call's
  `:memory` option. Top-level direct runtime-callable aliases are not
  preserved on this public path. Hosts that must preserve every runtime
  callable, including direct builtin/tool aliases, use the internal
  `run_native/2` continuation path with `preserve_runtime_callables: true`, as
  `PtcRunner.Kernel` does. A host must not substitute the JSON/public memory
  projection for either continuation path: that projection is observation-only
  and cannot retain executable values.

  `:turn_history` is separate from memory. Hosts pass a list of prior
  successful `step.return` values in chronological order; `*1` reads the most
  recent value, `*2` the previous value, and `*3` the third-most-recent value.
  Missing history reads return `nil`. `run/2` does not mutate the supplied
  history; callers that want REPL semantics should append `step.return` only
  after a successful run and keep their chosen bounded depth. For direct
  embedding use, `PtcRunner.Kernel.ReplSession` implements this contract with a
  default depth of 3.

  **Related modules:**
  - `PtcRunner.Kernel` - Executes bounded Kernel workflows
  - `PtcRunner.Kernel.ReplSession` - Stateful direct evaluation wrapper
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
  - `{:error, {:memory_exceeded, info}}` - heap limit exceeded; `info` is a
    diagnostics map (`:phase`, `:limit_bytes`, `:baseline_bytes`,
    `:budget_bytes`) where `phase: :eval` marks a program over its budget and
    `phase: :setup` a granted environment over the setup ceiling, surfaced in
    `Step.fail.details`

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
  @spec run(String.t(), keyword()) :: {:ok, Step.t()} | {:error, Step.t()}
  def run(source, opts \\ []) do
    source
    |> run_native(opts)
    |> public_result()
  end

  @doc false
  @spec run_native(String.t(), keyword()) ::
          {:ok, Step.t()} | {:error, Step.t()}
  def run_native(source, opts \\ []) do
    caller = validate_caller!(Keyword.get(opts, :caller, :direct))
    # Strip instrumentation options so they cannot affect execution semantics
    # or be re-read by downstream code.
    inner_opts = Keyword.delete(opts, :caller)
    signature_supplied? = not is_nil(Keyword.get(inner_opts, :signature))
    program_bytes = if is_binary(source), do: byte_size(source), else: 0

    metadata = %{
      caller: caller,
      program_bytes: program_bytes,
      signature_supplied?: signature_supplied?
    }

    started_at = System.monotonic_time()

    :telemetry.execute(
      [:ptc_runner, :lisp, :execute, :start],
      %{monotonic_time: started_at, system_time: System.system_time()},
      metadata
    )

    try do
      result = do_run(source, inner_opts)
      {result_bytes, prints_count} = telemetry_result_stats(result)
      stopped_at = System.monotonic_time()

      :telemetry.execute(
        [:ptc_runner, :lisp, :execute, :stop],
        %{
          duration: stopped_at - started_at,
          monotonic_time: stopped_at,
          result_bytes: result_bytes,
          prints_count: prints_count
        },
        Map.put(metadata, :outcome, telemetry_outcome(result))
      )

      result
    rescue
      exception ->
        emit_telemetry_exception(started_at, metadata, exception.__struct__)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_telemetry_exception(started_at, metadata, kind)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_telemetry_exception(started_at, metadata, exception_class) do
    stopped_at = System.monotonic_time()

    :telemetry.execute(
      [:ptc_runner, :lisp, :execute, :exception],
      %{duration: stopped_at - started_at, monotonic_time: stopped_at},
      Map.put(metadata, :exception_class, exception_class)
    )
  end

  defp telemetry_outcome({:ok, %Step{}}), do: :ok
  defp telemetry_outcome({:error, %Step{}}), do: :error
  defp telemetry_outcome(_other), do: :error

  defp public_result({tag, %Step{} = step}) when tag in [:ok, :error] do
    {tag,
     %{
       step
       | return: public_result_value(step.return),
         fail: public_result_value(step.fail),
         tool_calls: public_result_value(step.tool_calls),
         pmap_calls: public_result_value(step.pmap_calls),
         child_steps: public_result_value(step.child_steps),
         tool_cache: public_result_value(step.tool_cache)
     }}
  end

  defp public_result_value({:closure, _params, _body, _env, _history, _metadata}),
    do: "#fn[...]"

  defp public_result_value({:juxt_fn, _fns}), do: "#fn[...]"
  defp public_result_value({:partial_fn, _function, _fixed}), do: "#fn[...]"
  defp public_result_value({:comp_fn, _fns}), do: "#fn[...]"
  defp public_result_value({:complement_fn, _function}), do: "#fn[...]"
  defp public_result_value({:constantly_fn, _value}), do: "#fn[...]"
  defp public_result_value({:every_pred_fn, _predicates}), do: "#fn[...]"
  defp public_result_value({:some_fn, _functions}), do: "#fn[...]"
  defp public_result_value({:fnil_fn, _function, _default}), do: "#fn[...]"

  defp public_result_value(%Step{} = step), do: public_result({:ok, step}) |> elem(1)

  defp public_result_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&public_result_value/1) |> List.to_tuple()

  defp public_result_value(value) when is_list(value), do: Enum.map(value, &public_result_value/1)

  defp public_result_value(%MapSet{} = value),
    do: value |> Enum.map(&public_result_value/1) |> MapSet.new()

  defp public_result_value(value) when is_map(value) and not is_struct(value),
    do:
      Map.new(value, fn {key, item} -> {public_result_value(key), public_result_value(item)} end)

  defp public_result_value(value), do: externalize_lisp_values(value)

  # Closed atom set for :caller telemetry tag. Validated at entry to
  # `run/2` so out-of-set values fail fast and don't reach instrumentation.
  defp validate_caller!(caller) when caller in @valid_callers, do: caller

  defp validate_caller!(other) do
    raise ArgumentError,
          "invalid :caller option #{inspect(other)}; expected one of " <>
            inspect(@valid_callers)
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
    memory = Keyword.get(opts, :memory, %{})
    max_program_bytes = Keyword.get(opts, :max_program_bytes, @default_max_program_bytes)
    prelude_opt = Keyword.get(opts, :prelude)
    tools = Keyword.get(opts, :tools, %{})

    # Preflight: reject oversized source before any parsing
    if is_binary(source) and byte_size(source) > max_program_bytes do
      {:error,
       Step.error(
         :program_too_large,
         "program size #{byte_size(source)} bytes exceeds limit of #{max_program_bytes}",
         memory,
         %{}
       )}
    else
      attach_and_run(source, opts, prelude_opt, tools, memory)
    end
  end

  defp attach_and_run(source, opts, prelude_opt, tools, memory) do
    case attach_prelude(prelude_opt, tools, memory) do
      {:ok, prelude} ->
        source
        |> do_run_inner(Map.put(run_params(opts), :prelude, prelude))
        |> stamp_prelude_trace(prelude)

      {:error, %Step{}} = err ->
        # Attach FAILED — there is no compiled artifact to summarize.
        err
    end
  end

  # Stamp the prelude trace summary (plan §12) onto the result Step so trace
  # consumers can reproduce the V1 capability environment. Applied to BOTH the
  # success and error Step; `nil` prelude leaves `prelude_trace` nil.
  defp stamp_prelude_trace(result, nil), do: result

  defp stamp_prelude_trace({tag, %Step{} = step}, %Prelude{} = prelude)
       when tag in [:ok, :error] do
    {tag, %{step | prelude_trace: Prelude.trace_summary(prelude)}}
  end

  # Bundle the per-run options map consumed by the rest of the run pipeline.
  defp run_params(opts) do
    max_heap = Keyword.get(opts, :max_heap, 1_250_000)

    %{
      ctx: Keyword.get(opts, :context, %{}),
      memory: Keyword.get(opts, :memory, %{}),
      raw_tools: Keyword.get(opts, :tools, %{}),
      signature_str: Keyword.get(opts, :signature),
      float_precision: Keyword.get(opts, :float_precision),
      preserve_runtime_callables: Keyword.get(opts, :preserve_runtime_callables, false),
      timeout: Keyword.get(opts, :timeout, 1000),
      max_heap: max_heap,
      setup_max_heap: Keyword.get(opts, :setup_max_heap),
      # Security H1: every pmap/pcalls worker runs under this FIXED heap cap
      # (default: the sandbox `max_heap`), and the global `max_parallel_workers`
      # semaphore caps how many such workers are alive at once across the run.
      worker_max_heap: Keyword.get(opts, :worker_max_heap, max_heap),
      max_parallel_workers:
        Keyword.get(opts, :max_parallel_workers, @default_max_parallel_workers),
      max_symbols: Keyword.get(opts, :max_symbols, 10_000),
      compile_timeout: Keyword.get(opts, :compile_timeout, @default_compile_timeout),
      run_deadline_ms: Keyword.get(opts, :run_deadline_ms),
      turn_history: Keyword.get(opts, :turn_history, []),
      max_print_length: Keyword.get(opts, :max_print_length),
      filter_context: Keyword.get(opts, :filter_context, true),
      pmap_timeout: Keyword.get(opts, :pmap_timeout),
      pmap_max_concurrency: Keyword.get(opts, :pmap_max_concurrency),
      tool_cache: Keyword.get(opts, :tool_cache, %{}),
      max_tool_calls: Keyword.get(opts, :max_tool_calls),
      max_tool_call_result_bytes: Keyword.get(opts, :max_tool_call_result_bytes),
      strict_data: Keyword.get(opts, :strict_data, false),
      strict_transitive_calls: Keyword.get(opts, :strict_transitive_calls, false),
      direct_namespaces: Keyword.get(opts, :direct_namespaces, []),
      transitive_namespace_requirers: Keyword.get(opts, :transitive_namespace_requirers, %{}),
      prelude_export_mask: Keyword.get(opts, :prelude_export_mask),
      prelude_filtered_exports: Keyword.get(opts, :prelude_filtered_exports, []),
      link: Keyword.get(opts, :link, false)
    }
  end

  # Resolve the `:prelude` option (compiled artifact or source) and run
  # attach-time requires validation against the granted tools map.
  defp attach_prelude(nil, _tools, _memory), do: {:ok, nil}

  defp attach_prelude(prelude_opt, tools, memory) do
    context = PreludeAttachContext.new(tools: tools)

    case PreludeAttach.attach(prelude_opt, context) do
      {:ok, prelude} ->
        {:ok, prelude}

      {:error, %PreludeValidationError{} = err} ->
        {:error, Step.error(err.reason, "prelude attach failed: #{err.message}", memory, %{})}
    end
  end

  defp do_run_inner(source, %{raw_tools: raw_tools, memory: memory} = params) do
    signature_str = params.signature_str

    # Normalize tools to Tool structs
    with :ok <- validate_parallel_config(params.worker_max_heap, params.max_parallel_workers),
         {:ok, normalized_tools} <- normalize_tools(raw_tools),
         {:ok, parsed_signature} <- parse_signature(signature_str) do
      tool_executor = fn name, args, origin ->
        execute_tool(normalized_tools, name, args, origin)
      end

      tools_meta =
        Map.new(normalized_tools, fn {name, tool} ->
          {name, %{cache: tool.cache, visibility: tool.visibility}}
        end)

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
         Step.error(:invalid_tool, "Tool '#{tool_name}': #{inspect(reason)}", memory, %{})}

      {:error, {:invalid_signature, msg}} ->
        {:error, Step.error(:parse_error, "Invalid signature: #{msg}", memory, %{})}

      {:error, {:invalid_config, msg}} ->
        {:error, Step.error(:invalid_config, msg, memory, %{})}
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
      compile_timeout: compile_timeout
    } = opts

    prelude = Map.get(opts, :prelude)
    prelude_filtered_exports = Map.get(opts, :prelude_filtered_exports, [])

    # The compile sandbox closure must capture ONLY what parse/analyze need:
    # tool NAMES and memory KEYS, never the tool closures or memory values
    # (whose data can be megabytes of granted environment). Error Steps built
    # inside carry placeholder memory, re-hydrated in
    # `handle_compile_error/2`. `run_bounded/2` bills everything the closure
    # references against `max_heap` at spawn — by design (the closure is the
    # workload), so the grant must not ride along.
    tool_names = Map.keys(normalized_tools)

    public_tool_names =
      normalized_tools
      |> Enum.reject(fn {_name, tool} -> Tool.private?(tool) end)
      |> Enum.map(fn {name, _tool} -> name end)

    memory_keys = Map.keys(memory)

    compile_fn = fn ->
      with {:ok, raw_ast} <- Parser.parse(source),
           :ok <- check_symbol_limit(raw_ast, max_symbols),
           {:ok, core_ast} <- Analyze.analyze(raw_ast, prelude, prelude_filtered_exports),
           :ok <- check_undefined_vars(core_ast, memory_keys),
           :ok <- check_undefined_tools(core_ast, public_tool_names, tool_names, prelude) do
        {:ok, core_ast}
      end
    end

    compile_max_heap =
      Application.get_env(:ptc_runner, :default_max_heap, 1_250_000)

    compile_opts = [timeout: compile_timeout, max_heap: compile_max_heap]

    case PtcRunner.Sandbox.run_bounded(compile_fn, compile_opts) do
      {:ok, {:ok, core_ast}} ->
        execute_eval(core_ast, apply_run_deadline(opts))

      {:ok, {:error, _} = compile_error} ->
        handle_compile_error(compile_error, memory)

      {:error, {:timeout, ms}} ->
        {:error,
         Step.error(
           :compile_timeout,
           "compilation exceeded #{ms}ms limit",
           memory,
           %{}
         )}

      {:error, {:memory_exceeded, bytes}} ->
        {:error,
         Step.error(
           :compile_memory_exceeded,
           "compilation exceeded #{bytes} byte heap limit",
           memory,
           %{}
         )}

      {:error, {:execution_error, msg}} ->
        {:error, Step.error(:compile_error, "compilation failed: #{msg}", memory, %{})}
    end
  end

  defp apply_run_deadline(%{run_deadline_ms: nil} = opts), do: opts

  defp apply_run_deadline(%{run_deadline_ms: deadline_ms, timeout: timeout} = opts) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 1)
    %{opts | timeout: min(timeout, remaining_ms)}
  end

  defp handle_compile_error({:error, {:parse_error, msg}}, memory) do
    {:error, Step.error(:parse_error, msg, memory, %{})}
  end

  # Compile-sandbox Steps are built with placeholder memory so the compile
  # closure doesn't capture the granted environment — restore it here.
  defp handle_compile_error({:error, %Step{} = step}, memory) do
    {:error, %{step | memory: memory}}
  end

  defp handle_compile_error({:error, {reason_atom, _, _} = reason}, memory)
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, format_error(reason), memory, %{})}
  end

  defp handle_compile_error({:error, {reason_atom, _} = reason}, memory)
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, format_error(reason), memory, %{})}
  end

  defp execute_eval(core_ast, opts) do
    %{
      ctx: ctx,
      memory: memory,
      normalized_tools: normalized_tools,
      tool_executor: tool_executor,
      timeout: timeout,
      max_heap: max_heap,
      setup_max_heap: setup_max_heap,
      worker_max_heap: worker_max_heap,
      max_parallel_workers: max_parallel_workers,
      turn_history: turn_history,
      max_print_length: max_print_length,
      filter_context: filter_context,
      pmap_timeout: pmap_timeout,
      pmap_max_concurrency: pmap_max_concurrency,
      tool_cache: tool_cache,
      tools_meta: tools_meta,
      max_tool_calls: max_tool_calls,
      max_tool_call_result_bytes: max_tool_call_result_bytes,
      strict_data: strict_data,
      strict_transitive_calls: strict_transitive_calls,
      direct_namespaces: direct_namespaces,
      transitive_namespace_requirers: transitive_namespace_requirers,
      prelude_export_mask: prelude_export_mask
    } = opts

    prelude = Map.get(opts, :prelude)

    # Skip dataset filtering when a prelude is attached: a prelude export may
    # read `data/*` keys that never appear in the user program's own AST, so
    # filtering (a memory optimization, not a security boundary) would starve
    # the export of its data. Correctness wins over the optimization here.
    filtered_ctx =
      if filter_context and is_nil(prelude),
        do: DataKeys.filter_context(core_ast, ctx),
        else: ctx

    context = PtcRunner.Lisp.Context.new(filtered_ctx, memory, normalized_tools, turn_history)

    parallel_budget = ParallelBudget.new(max_parallel_workers)

    eval_opts =
      [
        max_print_length: max_print_length,
        max_heap: max_heap,
        worker_max_heap: worker_max_heap,
        parallel_budget: parallel_budget,
        pmap_timeout: pmap_timeout,
        pmap_max_concurrency: pmap_max_concurrency,
        tool_cache: tool_cache,
        tools_meta: tools_meta,
        max_tool_calls: max_tool_calls,
        max_tool_call_result_bytes: max_tool_call_result_bytes,
        strict_data: strict_data,
        strict_transitive_calls: strict_transitive_calls,
        direct_namespaces: direct_namespaces,
        transitive_namespace_requirers: transitive_namespace_requirers,
        prelude_export_mask: prelude_export_mask,
        prelude: prelude
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

        e in PtcRunner.Lisp.ToolError ->
          {:error, {:tool_error, e.tool_name, e.message}, e.eval_ctx}

        e ->
          {:error, {:runtime_error, Exception.message(e)}}
      end
    end

    sandbox_opts =
      [
        timeout: timeout,
        max_heap: max_heap,
        eval_fn: eval_fn,
        link: Map.get(opts, :link, false)
      ]
      |> put_setup_max_heap(setup_max_heap)

    core_ast
    |> PtcRunner.Sandbox.execute(context, sandbox_opts)
    |> handle_execute_result(opts)
  end

  defp handle_execute_result(
         {:ok, {:return_signal, value}, metrics, %EvalContext{} = eval_ctx},
         %{
           float_precision: float_precision,
           preserve_runtime_callables: preserve_runtime_callables
         }
       ) do
    step =
      apply_memory_contract(
        {:__ptc_return__, value},
        float_precision,
        eval_ctx,
        preserve_runtime_callables
      )

    {:ok, %{step | usage: metrics}}
  end

  defp handle_execute_result(
         {:ok, {:fail_signal, value}, metrics, %EvalContext{} = eval_ctx},
         %{
           float_precision: float_precision,
           preserve_runtime_callables: preserve_runtime_callables
         }
       ) do
    step =
      apply_memory_contract(
        {:__ptc_fail__, value},
        float_precision,
        eval_ctx,
        preserve_runtime_callables
      )

    {:ok, %{step | usage: metrics}}
  end

  defp handle_execute_result(
         {:ok, {:error_with_ctx, reason}, metrics, %EvalContext{} = eval_ctx},
         %{memory: memory}
       ) do
    eval_error_step(reason, metrics, memory, eval_ctx)
  end

  defp handle_execute_result({:ok, value, metrics, %EvalContext{} = eval_ctx}, opts) do
    %{
      float_precision: float_precision,
      parsed_signature: parsed_signature,
      signature_str: sig,
      preserve_runtime_callables: preserve_runtime_callables
    } =
      opts

    step =
      value
      |> apply_memory_contract(float_precision, eval_ctx, preserve_runtime_callables)
      |> Map.put(:usage, metrics)

    case validate_return_value(parsed_signature, sig, step) do
      {:ok, validated_step} -> {:ok, validated_step}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_execute_result({:error, {:timeout, ms}}, %{memory: memory}) do
    {:error, Step.error(:timeout, "execution exceeded #{ms}ms limit", memory, %{})}
  end

  defp handle_execute_result({:error, {:memory_exceeded, info}}, %{memory: memory}) do
    memory_exceeded_step(info, memory)
  end

  defp handle_execute_result({:error, {reason_atom, _, _} = reason}, %{memory: memory})
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, format_error(reason), memory, %{})}
  end

  defp handle_execute_result({:error, {reason_atom, _} = reason}, %{memory: memory})
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, format_error(reason), memory, %{})}
  end

  defp handle_execute_result({:error, reason}, %{memory: memory}) do
    {:error, Step.error(direct_error_reason_atom(reason), format_error(reason), memory, %{})}
  end

  defp direct_error_reason_atom(reason), do: elem(reason, 0)

  defp eval_error_step(reason, metrics, memory, %EvalContext{} = eval_ctx) do
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
      prelude_call_counts: eval_ctx.prelude_call_counts,
      child_traces: child_traces,
      child_steps: child_steps,
      tool_cache: eval_ctx.tool_cache
    }

    {:error, step}
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

  def format_error({:memory_exceeded, info}),
    do: "Memory exceeded: #{memory_exceeded_message(info)}"

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

  def format_error({:private_tool_unauthorized, name, %{origin: nil}}),
    do: "Private tool '#{name}' cannot be called directly"

  def format_error({:private_tool_unauthorized, name, %{origin: origin, allowed_tools: allowed}}),
    do:
      "Private tool '#{name}' is not authorized for prelude export #{origin}; " <>
        "declared private tools: #{Enum.join(allowed, ", ")}"

  def format_error({:private_tool_args_error, name, details}),
    do: "Private tool '#{name}' arguments failed validation: #{details}"

  def format_error({:transitive_call_unauthorized, ref, namespace, []}) do
    "Prelude namespace '#{namespace}' is attached only as a transitive dependency; " <>
      "attach it directly to use #{ref}."
  end

  def format_error({:transitive_call_unauthorized, ref, namespace, requirers}) do
    pulled_by = Enum.map_join(requirers, ", ", &"`#{&1}`")

    "Prelude namespace '#{namespace}' is a transitive dependency of #{pulled_by}; " <>
      "attach it directly to use #{ref}."
  end

  def format_error({:grant_filtered_prelude_export, ref, reason}) do
    "#{ref} is public in an attached prelude but was removed from this session by " <>
      "the role grant (#{grant_filter_reason(reason)}); see prelude_projection " <>
      "in the session start result."
  end

  def format_error({:runtime_error, msg}), do: "Runtime error: #{msg}"
  def format_error({:tool_error, name, reason}), do: "Tool '#{name}' failed: #{inspect(reason)}"
  # Handle other 3-tuple error formats from Eval: {type, message, data}
  def format_error({type, msg, _}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error({type, msg}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  defp grant_filter_reason(:ptc_tool_denied), do: "ptc_tool_denied"
  defp grant_filter_reason(:upstream_tool_denied), do: "upstream_tool_denied"

  defp grant_filter_reason(:dynamic_upstream_requires_broad_grant),
    do: "dynamic_upstream_requires_broad_grant"

  defp grant_filter_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp grant_filter_reason(_reason), do: "grant_filtered"

  # Human-readable kill message from `PtcRunner.Sandbox.memory_exceeded_info/0`
  # diagnostics (setup-phase kills are a grant problem, not a program
  # problem) or the legacy integer byte limit (`run_bounded/2`).
  defp memory_exceeded_message(%{phase: :setup} = info) do
    "killed during environment setup: granted context/memory/tools exceeded " <>
      "the #{info.limit_bytes}-byte setup ceiling (raise :setup_max_heap or shrink the grant)"
  end

  defp memory_exceeded_message(%{phase: :eval} = info) do
    "heap limit exceeded: program used more than its #{info.budget_bytes}-byte " <>
      "budget above the #{info.baseline_bytes}-byte environment baseline " <>
      "(limit #{info.limit_bytes} bytes)"
  end

  defp memory_exceeded_message(bytes) when is_integer(bytes),
    do: "heap limit #{bytes} bytes exceeded"

  # Nested pmap/pcalls worker kills surface as {:memory_exceeded, message}
  # from the eval layer — already human-readable.
  defp memory_exceeded_message(message) when is_binary(message), do: message

  defp memory_exceeded_step(info, memory) do
    message = memory_exceeded_message(info)
    details = if is_map(info), do: info, else: %{}
    Logger.warning("PTC-Lisp execution killed: #{message}")

    {:error, Step.error(:memory_exceeded, message, memory, details)}
  end

  defp put_setup_max_heap(opts, nil), do: opts
  defp put_setup_max_heap(opts, words), do: [{:setup_max_heap, words} | opts]

  # V2 simplified memory contract: pass through all values unchanged.
  # Storage is explicit via `def` (values persist in user_ns).
  # No implicit map merge or :return key handling.
  defp apply_memory_contract(value, precision, %EvalContext{} = ctx, preserve_runtime_callables) do
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
      return: round_floats(value, precision),
      fail: nil,
      memory: native_memory(ctx.user_ns, preserve_runtime_callables),
      tool_cache: ctx.tool_cache,
      signature: nil,
      usage: nil,
      turns: nil,
      prints: Enum.reverse(ctx.prints),
      tool_calls: cleaned_tool_calls,
      pmap_calls: cleaned_pmap_calls,
      prelude_call_counts: ctx.prelude_call_counts,
      child_traces: child_traces,
      child_steps: child_steps
    }
  end

  defp native_memory(memory, preserve_runtime_callables) when is_map(memory) do
    memory
    |> Enum.reject(fn {_k, v} ->
      not preserve_runtime_callables and match?(%RuntimeCallable{}, v)
    end)
    |> Map.new(fn {k, v} -> {k, native_memory_value(v, preserve_runtime_callables)} end)
  end

  defp native_memory_value(%RuntimeCallable{} = callable, true), do: callable

  defp native_memory_value(%RuntimeCallable{} = callable, false),
    do: RuntimeCallable.label(callable)

  defp native_memory_value(value, preserve_runtime_callables) when is_list(value) do
    Enum.map(value, &native_memory_value(&1, preserve_runtime_callables))
  end

  defp native_memory_value(value, preserve_runtime_callables)
       when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} ->
      {native_memory_value(k, preserve_runtime_callables),
       native_memory_value(v, preserve_runtime_callables)}
    end)
  end

  defp native_memory_value({:__ptc_return__, inner}, preserve_runtime_callables),
    do: {:__ptc_return__, native_memory_value(inner, preserve_runtime_callables)}

  defp native_memory_value({:__ptc_fail__, inner}, preserve_runtime_callables),
    do: {:__ptc_fail__, native_memory_value(inner, preserve_runtime_callables)}

  defp native_memory_value({:juxt_fn, fns}, _preserve_runtime_callables) when is_list(fns) do
    {:juxt_fn, Enum.map(fns, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:partial_fn, f, fixed}, _preserve_runtime_callables)
       when is_list(fixed) do
    {:partial_fn, native_memory_value(f, true), Enum.map(fixed, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:comp_fn, fns}, _preserve_runtime_callables) when is_list(fns) do
    {:comp_fn, Enum.map(fns, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:complement_fn, f}, _preserve_runtime_callables) do
    {:complement_fn, native_memory_value(f, true)}
  end

  defp native_memory_value({:constantly_fn, value}, _preserve_runtime_callables) do
    {:constantly_fn, native_memory_value(value, true)}
  end

  defp native_memory_value({:every_pred_fn, preds}, _preserve_runtime_callables)
       when is_list(preds) do
    {:every_pred_fn, Enum.map(preds, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:some_fn, fns}, _preserve_runtime_callables) when is_list(fns) do
    {:some_fn, Enum.map(fns, &native_memory_value(&1, true))}
  end

  defp native_memory_value({:fnil_fn, f, default}, _preserve_runtime_callables) do
    {:fnil_fn, native_memory_value(f, true), native_memory_value(default, true)}
  end

  defp native_memory_value(
         {:closure, _params, _body, _env, _turn_history, _metadata} = closure,
         _preserve_runtime_callables
       ),
       do: closure

  defp native_memory_value(%MapSet{} = set, preserve_runtime_callables) do
    set
    |> Enum.map(&native_memory_value(&1, preserve_runtime_callables))
    |> MapSet.new()
  end

  defp native_memory_value(value, _preserve_runtime_callables), do: value

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

  defp externalize_lisp_values(value) when is_function(value), do: "#fn[...]"

  defp externalize_lisp_values(%Var{name: name} = var) when is_binary(name) do
    %{var | name: existing_atom_or(name, name)}
  end

  defp externalize_lisp_values({:__ptc_return__, inner}) do
    {:__ptc_return__, externalize_lisp_values(inner)}
  end

  defp externalize_lisp_values({:__ptc_fail__, inner}) do
    {:__ptc_fail__, externalize_lisp_values(inner)}
  end

  defp externalize_lisp_values({:juxt_fn, _fns}), do: "#fn[...]"
  defp externalize_lisp_values({:partial_fn, _f, _fixed}), do: "#fn[...]"
  defp externalize_lisp_values({:comp_fn, _fns}), do: "#fn[...]"
  defp externalize_lisp_values({:complement_fn, _f}), do: "#fn[...]"
  defp externalize_lisp_values({:constantly_fn, _value}), do: "#fn[...]"
  defp externalize_lisp_values({:every_pred_fn, _preds}), do: "#fn[...]"
  defp externalize_lisp_values({:some_fn, _fns}), do: "#fn[...]"
  defp externalize_lisp_values({:fnil_fn, _f, _default}), do: "#fn[...]"

  defp externalize_lisp_values(value) when is_list(value) do
    Enum.map(value, &externalize_lisp_values/1)
  end

  defp externalize_lisp_values(%MapSet{} = set) do
    set
    |> Enum.map(&externalize_lisp_values/1)
    |> MapSet.new()
  end

  defp externalize_lisp_values(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} ->
      {externalize_lisp_values(k), externalize_lisp_values(v)}
    end)
  end

  defp externalize_lisp_values(value), do: value

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
  defp check_symbol_limit(ast, max_symbols) do
    count = SymbolCounter.count(ast)

    if count <= max_symbols do
      :ok
    else
      {:error,
       Step.error(
         :symbol_limit_exceeded,
         "program contains #{count} unique symbols/keywords, exceeds limit of #{max_symbols}",
         %{}
       )}
    end
  end

  # Pre-execution check: reject programs with undefined variables before any
  # side effects (tool calls) can execute. Memory keys are included in scope
  # to support executions where the supplied memory pre-binds variables.
  # Runs inside the compile sandbox: takes memory KEYS (pre-bound vars from
  # prior turns), not the memory map, so the closure doesn't capture grant
  # data. Error Steps carry placeholder memory, re-hydrated in
  # `handle_compile_error/2`.
  defp check_undefined_vars(core_ast, memory_keys) do
    initial_scope = MapSet.new(memory_keys)

    case collect_undefined_vars(core_ast, initial_scope) do
      [] ->
        :ok

      undefined ->
        vars = Enum.uniq(undefined)

        label = if length(vars) == 1, do: "Undefined variable", else: "Undefined variables"

        {:error, Step.error(:unbound_var, "#{label}: #{Enum.join(vars, ", ")}", %{})}
    end
  end

  # Pre-execution check: reject programs that reference tools not in the provided
  # toolset, preventing partial execution where early tool calls succeed before
  # a later unknown tool call crashes.
  # Takes tool NAMES (not the tools map) so the compile sandbox closure never
  # captures the tool closures and their granted environments. Direct user
  # references are checked against public names only; private names are admitted
  # only when they are reached through a prelude export's declared tool refs, and
  # runtime origin checks still enforce that same boundary at call time.
  defp check_undefined_tools(core_ast, public_tool_names, tool_names, prelude) do
    # CoreAST tool names are atoms, tool_names entries are strings — convert to strings
    direct =
      core_ast |> collect_tool_names() |> MapSet.new(fn name -> to_string(name) end)

    # A prelude export wraps tools in its captured body, invisible to the AST
    # walk above; union in the tools any referenced export will invoke so a
    # missing wrapped tool fails BEFORE an earlier tool can run (side-effect guard).
    prelude_refs = collect_prelude_tool_refs(core_ast, prelude)
    available = MapSet.new(tool_names)
    public_available = MapSet.new(public_tool_names)
    private_available = MapSet.difference(available, public_available)
    private_direct = MapSet.intersection(direct, private_available)
    referenced = MapSet.union(direct, prelude_refs)
    undefined = MapSet.difference(referenced, available)

    cond do
      MapSet.size(private_direct) > 0 ->
        names = private_direct |> MapSet.to_list() |> Enum.sort()
        label = if length(names) == 1, do: "Private tool", else: "Private tools"

        {:error,
         Step.error(
           :private_tool_unauthorized,
           "#{label} may only be called by authorized prelude exports: #{Enum.join(names, ", ")}",
           %{}
         )}

      MapSet.size(undefined) > 0 ->
        names = undefined |> MapSet.to_list() |> Enum.sort()
        label = if length(names) == 1, do: "Unknown tool", else: "Unknown tools"

        hint =
          case MapSet.to_list(public_available) |> Enum.sort() do
            [] -> "No tools available."
            tools -> "Available tools: #{Enum.join(tools, ", ")}"
          end

        {:error, Step.error(:unknown_tool, "#{label}: #{Enum.join(names, ", ")}. #{hint}", %{})}

      true ->
        :ok
    end
  end

  # Collect all tool names referenced in the CoreAST
  defp collect_tool_names(ast), do: collect_tool_names(ast, MapSet.new())

  defp collect_tool_names({:tool_call, name, args}, acc) do
    Enum.reduce(args, MapSet.put(acc, name), &collect_tool_names/2)
  end

  defp collect_tool_names({:runtime_callable, :tool, name}, acc), do: MapSet.put(acc, name)
  defp collect_tool_names({:runtime_callable, _namespace, _name}, acc), do: acc
  defp collect_tool_names({:symbol_ref, _name}, acc), do: acc

  # Prelude export call: the wrapped tool/call lives inside the captured prelude
  # closure body, not in the user AST; recurse into the call args only. The
  # body's own tools are surfaced separately via collect_prelude_tool_refs/2.
  defp collect_tool_names({:prelude_ref, _ref}, acc), do: acc

  defp collect_tool_names({:prelude_call, _ref, args}, acc),
    do: Enum.reduce(args, acc, &collect_tool_names/2)

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

  defp collect_tool_names({:pmap, fn_expr, colls}, acc) do
    acc = collect_tool_names(fn_expr, acc)
    Enum.reduce(colls, acc, &collect_tool_names/2)
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

  # Typed tools a referenced prelude export will invoke (from its export record),
  # so the pre-execution guard rejects a wrapped `(tool/call ...)` whose tool is
  # missing BEFORE any earlier tool can run.
  defp collect_prelude_tool_refs(_core_ast, nil), do: MapSet.new()

  defp collect_prelude_tool_refs(core_ast, %Prelude{} = prelude) do
    core_ast
    |> collect_prelude_refs(MapSet.new())
    |> Enum.reduce(MapSet.new(), fn ref, acc ->
      prelude |> Prelude.export_tool_refs(ref) |> MapSet.new() |> MapSet.union(acc)
    end)
  end

  # Generic CoreAST walk collecting prelude export refs ({:prelude_call,...} /
  # {:prelude_ref,...}) referenced anywhere in the user program.
  defp collect_prelude_refs({:prelude_call, ref, args}, acc),
    do: Enum.reduce(args, MapSet.put(acc, ref), &collect_prelude_refs/2)

  defp collect_prelude_refs({:prelude_ref, ref}, acc), do: MapSet.put(acc, ref)

  defp collect_prelude_refs(tuple, acc) when is_tuple(tuple),
    do: Enum.reduce(Tuple.to_list(tuple), acc, &collect_prelude_refs/2)

  defp collect_prelude_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_prelude_refs/2)

  defp collect_prelude_refs(map, acc) when is_map(map),
    do: Enum.reduce(Map.values(map), acc, &collect_prelude_refs/2)

  defp collect_prelude_refs(_other, acc), do: acc

  defp execute_tool(normalized_tools, name, args, origin) do
    case Map.fetch(normalized_tools, name) do
      {:ok, %Tool{} = tool} ->
        with :ok <- authorize_tool_call(tool, origin),
             :ok <- validate_private_tool_args(tool, args) do
          execute_tool_function(tool, args)
        end

      :error ->
        available =
          normalized_tools
          |> Enum.reject(fn {_name, tool} -> Tool.private?(tool) end)
          |> Enum.map(fn {tool_name, _tool} -> tool_name end)
          |> Enum.sort()

        raise ExecutionError, reason: :unknown_tool, message: name, data: available
    end
  end

  defp execute_tool_function(
         %Tool{name: name, argument_collisions: :reject},
         %AmbiguousArguments{}
       ) do
    raise ExecutionError,
      reason: :invalid_tool_args,
      message: name,
      data: :ambiguous_arguments
  end

  defp execute_tool_function(%Tool{name: name, function: fun}, args) do
    case fun.(args) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise ExecutionError, reason: :tool_error, message: name, data: reason

      value ->
        value
    end
  end

  defp authorize_tool_call(%Tool{visibility: :public}, _origin), do: :ok

  defp authorize_tool_call(%Tool{name: name, visibility: :private}, %{
         type: :prelude_export,
         ref: ref,
         tool_refs: tool_refs
       })
       when is_list(tool_refs) do
    if name in tool_refs do
      :ok
    else
      raise ExecutionError,
        reason: :private_tool_unauthorized,
        message: name,
        data: %{origin: ref, allowed_tools: tool_refs}
    end
  end

  defp authorize_tool_call(%Tool{name: name, visibility: :private}, _origin) do
    raise ExecutionError,
      reason: :private_tool_unauthorized,
      message: name,
      data: %{origin: nil}
  end

  defp validate_private_tool_args(%Tool{visibility: :public}, _args), do: :ok
  defp validate_private_tool_args(%Tool{signature: nil}, _args), do: :ok

  defp validate_private_tool_args(%Tool{name: name, signature: signature}, args) do
    with {:ok, parsed} <- Signature.parse(signature),
         :ok <- Signature.validate_input(parsed, args) do
      :ok
    else
      {:error, errors} when is_list(errors) ->
        raise ExecutionError,
          reason: :private_tool_args_error,
          message: name,
          data: format_signature_errors(errors)

      {:error, error} ->
        raise ExecutionError,
          reason: :private_tool_args_error,
          message: name,
          data: error
    end
  end

  defp format_signature_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: path, message: message} -> "#{Enum.join(path, ".")}: #{message}"
      other -> inspect(other)
    end)
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
    case Signature.validate(parsed_signature, externalize_lisp_values(step.return)) do
      :ok ->
        # Store the original signature string in the step
        {:ok, %{step | signature: signature_str}}

      {:error, errors} ->
        msg = format_validation_errors(errors)

        {:error,
         Step.error(:validation_error, msg, step.memory, %{}, tool_cache: step.tool_cache)}
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

  @doc false
  # Returns the unresolved variable names in `core_ast` given an initial scope
  # (a `MapSet` of in-scope names). Exposed so the prelude compiler can run the
  # SAME static undefined-var check on captured definition bodies.
  @spec undefined_vars(term(), MapSet.t()) :: [String.t()]
  def undefined_vars(core_ast, %MapSet{} = scope) do
    core_ast |> collect_undefined_vars(scope) |> Enum.uniq()
  end

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

  defp collect_undefined_vars({:fn, name, params, body}, scope) do
    param_names = fn_param_vars(params)

    extended_scope =
      [name | param_names]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(scope, &MapSet.put(&2, &1))

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
  defp collect_undefined_vars({:symbol_ref, _name}, _scope), do: []

  # Prelude export ref/call: the ref resolves through the prelude export table,
  # not user scope; recurse into call args only.
  defp collect_undefined_vars({:prelude_ref, _ref}, _scope), do: []

  defp collect_undefined_vars({:prelude_call, _ref, args}, scope),
    do: Enum.flat_map(args, &collect_undefined_vars(&1, scope))

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
  defp collect_undefined_vars({:pmap, fn_expr, coll_exprs}, scope) do
    collect_undefined_vars(fn_expr, scope) ++
      Enum.flat_map(coll_exprs, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:pcalls, fn_exprs}, scope) do
    Enum.flat_map(fn_exprs, &collect_undefined_vars(&1, scope))
  end

  # Task/step operations
  # Turn history
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
