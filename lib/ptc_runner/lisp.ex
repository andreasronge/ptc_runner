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

  Public tools declared with `cache: true` reuse successful results only within
  the current evaluation; private tools never cache. Every `run/2` starts with
  an empty evaluator-owned cache, and cache entries are neither accepted from
  callers nor returned in `PtcRunner.Lisp.Result`.
  """

  require Logger

  alias PtcRunner.Lisp.{
    Analyze,
    CoreAST,
    DataKeys,
    Env,
    Eval,
    ExternalizedCollision,
    Format,
    Parser,
    RuntimeCallable,
    SourceAtoms,
    SymbolCounter
  }

  alias PtcRunner.Kernel.LLMReplayDiagnostic
  alias PtcRunner.Kernel.Program
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Effects
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.HostContext
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
  alias PtcRunner.Lisp.Env.Builtin, as: EnvBuiltin
  alias PtcRunner.Lisp.EvaluatorError
  alias PtcRunner.Lisp.Format.Var
  alias PtcRunner.Lisp.Java.Project, as: JavaProject
  alias PtcRunner.Lisp.Java.Surface, as: JavaSurface
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Result, as: Step
  alias PtcRunner.Lisp.Signature
  alias PtcRunner.Lisp.Tool
  alias PtcRunner.Lisp.TrustedError
  alias PtcRunner.Lisp.UntrustedRenderer

  @valid_callers [:direct, :kernel, :repl]
  @projection_error_public_field_fallbacks [
    signature: nil,
    usage: nil,
    turns: nil,
    trace_id: nil,
    parent_trace_id: nil,
    name: nil,
    field_descriptions: nil,
    failure_origin: nil,
    return_origin: nil,
    prints: [],
    tool_calls: [],
    pmap_calls: [],
    child_traces: [],
    child_steps: [],
    messages: nil,
    prompt: nil,
    original_prompt: nil,
    tools: nil,
    prelude_trace: nil,
    prelude_calls: nil,
    prelude_call_counts: %{}
  ]

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
  Converts native PTC-Lisp runtime values into an inert public Elixir
  representation.

  Stateful hosts may keep native values internally between turns, but should use
  this at public observation boundaries such as final steps and trace events.
  Executable closures, builtins, composed callables, runtime callables, and
  plain BEAM functions are replaced recursively with deterministic display
  labels that cannot retain callable state, captured environments, or metadata.
  If distinct map keys or set members collapse to the same inert representation,
  every entry is retained with an opaque inert collision wrapper. Strict Kernel
  boundaries use the same projection and reject those collisions instead.
  """
  @spec externalize_value(term()) ::
          term()
          | {:error,
             {:java_projection_error
              | :lisp_value_projection_error
              | :symbol_ref_projection_error, term()}}
  def externalize_value(value) do
    case project_boundary_value(value, :public) do
      {:ok, projected} ->
        projected

      {:error, {kind, _, _} = reason} when kind == :symbol_ref_collision ->
        {:error, {:symbol_ref_projection_error, reason}}

      {:error, {kind, _} = reason} when kind == :invalid_symbol_ref ->
        {:error, {:symbol_ref_projection_error, reason}}

      {:error, {kind, _} = reason} when kind == :invalid_keyword ->
        {:error, {:lisp_value_projection_error, reason}}

      {:error, reason} ->
        {:error, {:java_projection_error, reason}}
    end
  end

  @doc false
  @spec project_boundary_value(term(), :public | :kernel_json) ::
          {:ok, term()} | {:error, term()}
  def project_boundary_value(value, boundary) when boundary in [:public, :kernel_json] do
    with {:ok, projected_java} <- JavaProject.project(value, boundary),
         projected = externalize_lisp_values(projected_java, boundary),
         :ok <- validate_externalized_symbol_refs(projected),
         :ok <- validate_projection_collisions(projected, boundary) do
      {:ok, projected}
    end
  end

  @doc false
  @spec project_native_result({:ok | :error, Step.t()}) ::
          {:ok | :error, Step.t()}
  def project_native_result({tag, %Step{} = step}) when tag in [:ok, :error] do
    case externalize_memory(step.memory) do
      memory when is_map(memory) ->
        public_result({tag, %{step | memory: memory}})

      {:error, {:java_projection_error, reason}} ->
        {:error, java_projection_error_step(%{step | memory: %{}}, reason)}

      {:error, {:symbol_ref_projection_error, reason}} ->
        {:error, symbol_projection_error_step(%{step | memory: %{}}, reason)}

      {:error, {:lisp_value_projection_error, reason}} ->
        {:error, symbol_projection_error_step(%{step | memory: %{}}, reason)}
    end
  end

  @doc """
  Converts a PTC-Lisp memory map into the public memory representation.

  Unlike `externalize_value/1`, this also normalizes top-level `def` binding
  keys through the bounded source vocabulary.
  """
  @spec externalize_memory(map()) ::
          map()
          | {:error,
             {:java_projection_error
              | :lisp_value_projection_error
              | :symbol_ref_projection_error, term()}}
  def externalize_memory(memory) when is_map(memory) do
    case JavaProject.project(memory, :public) do
      {:ok, projected} ->
        with externalized <-
               projected
               |> Enum.reject(fn {_k, v} -> match?(%PtcRunner.Lisp.RuntimeCallable{}, v) end)
               |> externalize_memory_entries(),
             :ok <- validate_externalized_symbol_refs(externalized) do
          externalized
        else
          {:error, {:invalid_keyword, _path} = reason} ->
            {:error, {:lisp_value_projection_error, reason}}

          {:error, reason} ->
            {:error, {:symbol_ref_projection_error, reason}}
        end

      {:error, reason} ->
        {:error, {:java_projection_error, reason}}
    end
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
    - `:timeout` - Timeout in milliseconds for entire sandbox execution (default:
      1000, configurable via `config :ptc_runner, :default_timeout`)
    - `:compile_timeout` - Timeout in milliseconds for the compile phase (parse + analyze) (default: 5000)
    - `:compile_max_heap` - Compile-worker heap ceiling in words (default: the
      `:max_heap` value). No ambient application default is consulted, so a
      sealed run's compile ceiling comes only from its own options.
    - `:pmap_timeout` - Shared absolute deadline in milliseconds for each
      pmap/pcalls operation, including nested parallel calls (default: 5000).
      Increase for LLM-backed tools.
    - `:parallel_deadline_cap` - Absolute monotonic-time ceiling in
      milliseconds clamping every parallel deadline regardless of when the
      operation starts (default: the `:run_deadline_ms` value). A parallel
      operation started late in a run therefore cannot outlive the run.
    - `:pmap_max_concurrency` - Local pmap/pcalls scheduling window — max tasks one call keeps in flight (default: the build-time `System.schedulers_online() * 2`, frozen into the semantic revision). Reduce to avoid overflowing connection pools. The HARD aggregate cap is `:max_parallel_workers`.
    - `:max_heap` - Program heap budget in words ABOVE the measured
      environment baseline (default: 1_250_000, configurable via
      `config :ptc_runner, :default_max_heap`). Host-provided data
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
    - `:loop_limit` - Optional positive integer bound on one `loop` or
      tail-`recur` function activation. Omitted or `nil` disables the counter
      (default: `nil`). Sequential loops, nested loops, and separate higher-order
      callback invocations are separate activations. Ordinary non-tail recursion
      and host collection traversal (`map`, `reduce`, and similar) are not
      counted. Invalid values return `:invalid_config`. Heap and elapsed-time
      limits remain the containment boundaries.
    - `:filter_context` - Filter context to only include accessed data keys (default: true)
    - `:strict_data` - When true, a missing `data/<name>` is a runtime error
      instead of `nil` (default: false). The Kernel enables this at every one of
      its boundaries -- the workflow entry, a mission evaluation, and both REPL
      session kinds; `run/2` stays permissive.
    - `:data_grants` - Optional sorted `data/<name>` forms included in the
      missing-grant diagnostic under `:strict_data`. The Kernel passes the list
      `PtcRunner.Lisp.DataKeys.source_referenceable_forms/1` derives from the
      granted data, the same one the mission inventory publishes, rather than
      deriving it from context keys. When omitted, the diagnostic names the
      missing key without a grant list.
    - `:missing_data_params_message` - Optional diagnostic used when `data/params`
      is missing under `:strict_data`. The Kernel sets this so a no-params
      evaluation is not reported as a missing grant.
    - `:shipped_export_owners` - Optional exact public-export ref to shipped
      component-ID map used only for `doc` miss diagnostics.
    - `:attached_component_ids` - Shipped component selections attached to the
      current environment. With the ownership map, this suppresses redirects
      for selected overrides whose replacement source removed an export.
      Omitting the ownership map keeps the ordinary miss, so embedded callers
      are unchanged.
    - `:prelude` - A compiled `%PtcRunner.Lisp.Prelude{}` artifact, a prelude
      SOURCE string, or a list of source-bearing selection maps accepted by
      `PtcRunner.Lisp.Prelude.Bundle.compile/1` to attach before user code.
      Source selections are concatenated and compiled once in explicit order
      after duplicate namespace rejection. The attached
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
    `monotonic_time`, `result_bytes`, `prints_count`, `memory_bytes`,
    `eval_reductions`; metadata `caller`, `program_bytes`,
    `signature_supplied?`, and semantic `outcome`.

    `duration` is in the emitter's native time unit, `result_bytes` is the
    external size of the returned value, and `prints_count` the number of
    prints. `memory_bytes` and `eval_reductions` are the sandbox child's own
    figures, the same pair `step.usage` carries: `memory_bytes` is
    `Process.info(child, :memory)` read the instant the result was ready — a
    heap reading at return, not a peak and not RSS — and `eval_reductions` is
    that child's reduction count. Both are `0` when a run failed before the
    child reported, which is not the same as a run that used nothing, so read
    `outcome` before charting either.
  - `[:ptc_runner, :lisp, :execute, :exception]` — measurements `duration`,
    `monotonic_time`; metadata `caller`, `program_bytes`,
    `signature_supplied?`, and `exception_class`. Exception reasons,
    stacktraces, source, arguments, and results are never attached.

  ## Tool Cache Lifetime

  A public tool configured with `cache: true` reuses successful results during
  one evaluation. The evaluator derives cache identity from the arguments
  prepared for the callback, including Java projection. Sequential and
  higher-order calls observe earlier entries. Parallel workers start from the
  same pre-parallel cache and do not observe sibling writes; their entries merge
  in input order and become reusable after the parallel operation. Every
  top-level call starts empty, and private tools never cache. Passing a
  `:tool_cache` option raises `ArgumentError`, and cache entries are not included
  in the returned `Result`.

  ## Return Value

  `println` writes only to an evaluation-local buffer. Successful and failed
  results expose any retained entries through `step.prints`; a caller must
  explicitly render or store them. The evaluator itself does not write those
  entries to stdout or a canonical trace.

  On success, returns:
   - `{:ok, PtcRunner.Lisp.Result.t()}` with:
     - `step.return`: An inert public projection of the evaluated value.
       Executable values become typed display wrappers. Distinct map keys and
       set members that share one display form remain distinct through inert
       collision wrappers.
     - `step.memory`: Data memory after execution. Direct Lisp callers can pass
       it back through the `:memory` option on a later eval; use
       `externalize_memory/1` when you need a purely public observation shape.
       The `run/2` result preserves supported closures and composed callable
       forms, including embedded builtin/tool runtime-callable references. It
       deliberately omits top-level runtime callables such as directly bound
       builtin/tool aliases and renders runtime callables nested in ordinary
       collection data as labels. Java callables are also rendered as labels,
       including when captured by a closure, so such a closure is
       observation-only on the public continuation path. Do not serialize
       `step.memory`
       (JSON, ETF-to-disk, database) between evals —
       serialization silently converts native values such as keywords into
       plain strings. For a bounded persistent REPL continuation, use
       `PtcRunner.Kernel.ReplSession` from one stable owner process. It is
       process-affine; a separate supervised abstraction must serialize any
       multi-process frontend.
     - `step.usage`: Execution metrics (`duration_ms`, `memory_bytes`,
       `eval_reductions`)

  On error, returns:
  - `{:error, PtcRunner.Lisp.Result.t()}` with:
    - `step.fail.reason`: Error reason atom
    - `step.fail.message`: Human-readable error description
    - `step.memory`: Native continuation memory at the time of error, with the
      same callable caveats as successful `run/2` results. Setup-phase heap
      kills return empty memory because the oversized grant cannot safely be
      projected outside the bounded worker. Do not serialize continuation
      memory; use `externalize_memory/1` for an observation-only projection.

  ## Memory Contract

  The top-level program value determines `step.return` without an implicit map
  merge or special `:return` key handling. `run/2` then projects that value to
  its inert public representation. Storage is **explicit**: `(def x v)`
  persists native `v` in memory (`step.memory["x"]`), and that memory can
  survive across explicitly managed evaluations.

  There are two deliberate host memory projections. Ordinary embedders may use
  `run/2` to continue data definitions, closures that do not capture Java
  callables, and supported composed callable forms by threading `step.memory`
  directly into the next call's `:memory` option. Top-level direct
  runtime-callable aliases and Java callables are not preserved on this public
  path. Hosts that must preserve every runtime callable, including direct
  builtin/tool aliases and Java callables captured by closures, use the
  internal `run_native/2` continuation path with
  `preserve_runtime_callables: true`, as `PtcRunner.Kernel` does. A host must
  not substitute the JSON/public memory projection for either continuation
  path: that projection is observation-only and cannot retain executable
  values.

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

  Exceeding a limit returns an error result whose `Step.fail.reason` is
  `:timeout` or `:memory_exceeded`. `Step.fail.details.phase` identifies
  `:setup` (bounded grant preparation) or `:eval` (program execution). Heap
  diagnostics also include `:limit_bytes`, `:baseline_bytes`, and
  `:budget_bytes`.

  ## Context Filtering

  By default, PTC-Lisp performs static analysis to identify which `data/xxx` keys are accessed
  by a program, then filters the context to only include those datasets. This significantly
  reduces memory pressure when the context contains large datasets that aren't used.

      # Only products is loaded into the sandbox, orders/employees are filtered out
      ctx = %{"products" => large_list, "orders" => large_list, "employees" => large_list}
      PtcRunner.Lisp.run("(count data/products)", context: ctx)

  Filtering performs direct lookups for the statically referenced keys; it does
  not enumerate or copy unrelated collection or scalar grants into the sandbox.

  Disable filtering if you need all context available (e.g., for dynamic data access):

      PtcRunner.Lisp.run(source, context: ctx, filter_context: false)

  See `PtcRunner.Lisp.DataKeys` for the static analysis implementation.
  """
  @spec run(String.t(), keyword()) :: {:ok, Step.t()} | {:error, Step.t()}
  def run(source, opts \\ []) do
    source
    |> instrumented_run(opts, :public)
    |> public_result()
  end

  @doc false
  @spec run_native(String.t(), keyword()) ::
          {:ok, Step.t()} | {:error, Step.t()}
  def run_native(source, opts \\ []), do: instrumented_run(source, opts, :native)

  defp instrumented_run(source, opts, history_mode) when history_mode in [:native, :public] do
    reject_imported_tool_cache!(opts)
    caller = validate_caller!(Keyword.get(opts, :caller, :direct))
    # Strip instrumentation options so they cannot affect execution semantics
    # or be re-read by downstream code.
    inner_opts =
      opts
      |> Keyword.delete(:caller)
      |> Keyword.put(:turn_history_mode, history_mode)

    signature_supplied? = not is_nil(Keyword.get(inner_opts, :signature))
    program_bytes = if is_binary(source), do: byte_size(source), else: 0

    metadata = %{
      caller: caller,
      program_bytes: program_bytes,
      signature_supplied?: signature_supplied?
    }

    metadata = maybe_put_live_run(metadata, Keyword.get(opts, :telemetry_run))

    started_at = System.monotonic_time()

    :telemetry.execute(
      [:ptc_runner, :lisp, :execute, :start],
      %{monotonic_time: started_at, system_time: System.system_time()},
      metadata
    )

    try do
      result = do_run(source, inner_opts)
      stats = telemetry_result_stats(result)
      stopped_at = System.monotonic_time()

      :telemetry.execute(
        [:ptc_runner, :lisp, :execute, :stop],
        %{
          duration: stopped_at - started_at,
          monotonic_time: stopped_at,
          result_bytes: stats.result_bytes,
          prints_count: stats.prints_count,
          memory_bytes: stats.memory_bytes,
          eval_reductions: stats.eval_reductions
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

  defp public_result({tag, %Step{} = step}) when tag in [:ok, :error] do
    case project_public_step(step) do
      {:ok, projected} ->
        public_step = externalize_public_step(projected)

        case validate_externalized_symbol_refs(public_step) do
          :ok -> {tag, public_step}
          {:error, reason} -> {:error, symbol_projection_error_step(public_step, reason)}
        end

      {:error, reason} ->
        {:error, java_projection_error_step(step, reason)}
    end
  end

  defp project_public_step(%Step{} = step) do
    step
    |> Map.from_struct()
    |> Map.keys()
    |> Enum.reduce_while({:ok, step}, fn field, {:ok, projected_step} ->
      boundary = if field == :memory, do: :continuation, else: :public

      case JavaProject.project(Map.fetch!(projected_step, field), boundary) do
        {:ok, value} -> {:cont, {:ok, Map.put(projected_step, field, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp externalize_public_step(%Step{} = step) do
    step
    |> Map.from_struct()
    |> Enum.reduce(step, fn
      {:memory, _memory}, projected_step ->
        projected_step

      {field, value}, projected_step ->
        Map.put(projected_step, field, externalize_lisp_values(value))
    end)
  end

  defp java_projection_error_step(%Step{} = step, reason) do
    details = %{projection_error: inspect(reason, limit: 10)}

    projection_error_step(
      step,
      :java_projection_error,
      "Java value could not be projected at the public boundary",
      details
    )
  end

  defp symbol_projection_error_step(%Step{} = step, reason) do
    projection_error_step(
      step,
      elem(reason, 0),
      format_error(reason),
      error_details(reason)
    )
  end

  defp projection_error_step(%Step{} = step, reason, message, details) do
    safe_step =
      Enum.reduce(
        @projection_error_public_field_fallbacks,
        %{
          step
          | return: nil,
            fail: %{reason: reason, message: message, details: details},
            memory: safely_project_error_field(step.memory, :continuation, %{})
        },
        fn {field, fallback}, projected_step ->
          Map.put(
            projected_step,
            field,
            safely_project_error_field(Map.fetch!(step, field), :public, fallback)
          )
        end
      )

    case validate_externalized_symbol_refs(safe_step) do
      :ok -> safe_step
      {:error, _projection_reason} -> Step.error(reason, message, %{}, details)
    end
  end

  defp validate_externalized_symbol_refs(value) do
    case Format.internalize_symbol_refs(value) do
      {:ok, _validated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp safely_project_error_field(value, boundary, fallback) do
    with {:ok, projected} <- JavaProject.project(value, boundary),
         externalized = maybe_externalize_error_field(projected, boundary),
         :ok <- validate_externalized_symbol_refs(externalized) do
      externalized
    else
      {:error, _reason} -> fallback
    end
  end

  defp maybe_externalize_error_field(value, :public), do: externalize_lisp_values(value)
  defp maybe_externalize_error_field(value, :continuation), do: value

  # Closed atom set for :caller telemetry tag. Validated at entry to
  # `run/2` so out-of-set values fail fast and don't reach instrumentation.
  defp validate_caller!(caller) when caller in @valid_callers, do: caller

  defp validate_caller!(other) do
    raise ArgumentError,
          "invalid :caller option #{inspect(other)}; expected one of " <>
            inspect(@valid_callers)
  end

  defp reject_imported_tool_cache!(opts) do
    if Keyword.has_key?(opts, :tool_cache) do
      raise ArgumentError,
            ":tool_cache option is not supported; tool caches are evaluator-owned and last for one evaluation"
    end
  end

  # Compute telemetry stop measurements from the run result.
  #
  # `Sandbox` already measures `memory_bytes` and `eval_reductions` and puts
  # them in `step.usage`, so surfacing them costs nothing here and is the only
  # way a host attached to the stop event can chart per-run heap. A run that
  # failed before its child reported has no usage at all; those cases report
  # `0` rather than a guess, and `outcome` is what distinguishes them.
  defp telemetry_result_stats({tag, %Step{} = step}) when tag in [:ok, :error] do
    usage = Map.get(step, :usage)

    %{
      result_bytes: safe_term_bytes(Map.get(step, :return)),
      prints_count: safe_length(Map.get(step, :prints)),
      memory_bytes: safe_usage(usage, :memory_bytes),
      eval_reductions: safe_usage(usage, :eval_reductions)
    }
  end

  defp telemetry_result_stats(_other),
    do: %{result_bytes: 0, prints_count: 0, memory_bytes: 0, eval_reductions: 0}

  defp safe_usage(usage, key) when is_map(usage) do
    case Map.get(usage, key) do
      value when is_integer(value) and value >= 0 -> value
      _absent_or_invalid -> 0
    end
  end

  defp safe_usage(_usage, _key), do: 0

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
    params = run_params(opts)

    # Preflight: reject oversized source before any parsing
    if is_binary(source) and byte_size(source) > max_program_bytes do
      Step.error(
        :program_too_large,
        "program size #{byte_size(source)} bytes exceeds limit of #{max_program_bytes}",
        memory,
        %{}
      )
      |> then(&{:error, &1})
      |> prepare_pre_setup_error(params)
    else
      attach_and_run(source, params, prelude_opt, tools, memory)
    end
  end

  defp attach_and_run(source, params, prelude_opt, tools, memory) do
    case attach_prelude(prelude_opt, tools, memory) do
      {:ok, prelude} ->
        source
        |> do_run_inner(Map.put(params, :prelude, prelude))
        |> stamp_prelude_trace(prelude)

      {:error, %Step{}} = err ->
        # Attach FAILED — there is no compiled artifact to summarize.
        prepare_pre_setup_error(err, params)
    end
  end

  # Stamp the prelude trace summary onto the result Step so trace
  # consumers can reproduce the capability environment. Applied to BOTH the
  # success and error Step; `nil` prelude leaves `prelude_trace` nil.
  defp stamp_prelude_trace(result, nil), do: result

  defp stamp_prelude_trace({tag, %Step{} = step}, %Prelude{} = prelude)
       when tag in [:ok, :error] do
    {tag, %{step | prelude_trace: Prelude.trace_summary(prelude)}}
  end

  # Bundle the per-run options map consumed by the rest of the run pipeline.
  defp run_params(opts) do
    max_heap = Keyword.get(opts, :max_heap, PtcRunner.Sandbox.default_max_heap())

    %{
      ctx: Keyword.get(opts, :context, %{}),
      memory: Keyword.get(opts, :memory, %{}),
      raw_tools: Keyword.get(opts, :tools, %{}),
      signature_str: Keyword.get(opts, :signature),
      float_precision: Keyword.get(opts, :float_precision),
      preserve_runtime_callables: Keyword.get(opts, :preserve_runtime_callables, false),
      timeout: Keyword.get(opts, :timeout, PtcRunner.Sandbox.default_timeout()),
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
      # Defaults to the sandbox `max_heap` rather than any ambient application
      # default, so a sealed Kernel run cannot have its compile ceiling moved
      # by process configuration outside the sealed request.
      compile_max_heap: Keyword.get(opts, :compile_max_heap, max_heap),
      run_deadline_ms: Keyword.get(opts, :run_deadline_ms),
      # The absolute ceiling on every parallel deadline. Defaults to the run
      # deadline; the separate option exists so the closure-propagation
      # paths can be tested with a cap that expires well before the sandbox.
      parallel_deadline_cap:
        Keyword.get(opts, :parallel_deadline_cap, Keyword.get(opts, :run_deadline_ms)),
      turn_history: Keyword.get(opts, :turn_history, []),
      max_print_length: Keyword.get(opts, :max_print_length),
      loop_limit: Keyword.get(opts, :loop_limit),
      filter_context: Keyword.get(opts, :filter_context, true),
      pmap_timeout: Keyword.get(opts, :pmap_timeout),
      pmap_max_concurrency: Keyword.get(opts, :pmap_max_concurrency),
      max_tool_calls: Keyword.get(opts, :max_tool_calls),
      max_tool_call_result_bytes: Keyword.get(opts, :max_tool_call_result_bytes),
      turn_history_mode: Keyword.fetch!(opts, :turn_history_mode),
      strict_data: Keyword.get(opts, :strict_data, false),
      data_grants: Keyword.get(opts, :data_grants),
      missing_data_params_message: Keyword.get(opts, :missing_data_params_message),
      strict_transitive_calls: Keyword.get(opts, :strict_transitive_calls, false),
      direct_namespaces: Keyword.get(opts, :direct_namespaces, []),
      transitive_namespace_requirers: Keyword.get(opts, :transitive_namespace_requirers, %{}),
      prelude_export_mask: Keyword.get(opts, :prelude_export_mask),
      shipped_export_owners: Keyword.get(opts, :shipped_export_owners),
      attached_component_ids: Keyword.get(opts, :attached_component_ids, []),
      prelude_filtered_exports: Keyword.get(opts, :prelude_filtered_exports, []),
      link: Keyword.get(opts, :link, false),
      telemetry_run: Keyword.get(opts, :telemetry_run)
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
         :ok <- validate_loop_limit(params.loop_limit),
         {:ok, normalized_tools} <- normalize_tools(raw_tools),
         {:ok, parsed_signature} <- parse_signature(signature_str) do
      tool_failure_token = make_ref()

      # Contracts are introspection data, not execution authority. Keep the
      # bounded projection in tools_meta and strip it from the tool map captured
      # by the executor so parallel workers do not copy every contract twice.
      execution_tools =
        Map.new(normalized_tools, fn {name, tool} -> {name, %{tool | contract: nil}} end)

      tool_executor = fn name, args, origin ->
        execute_tool(execution_tools, name, args, origin, tool_failure_token)
      end

      tools_meta =
        Map.new(normalized_tools, fn {name, tool} ->
          {name,
           %{
             cache: tool.cache,
             visibility: tool.visibility,
             signature: tool.signature,
             contract: tool.contract,
             argument_projection: tool.argument_projection,
             ledger_arguments: tool.ledger_arguments
           }}
        end)

      private_tool_authority? =
        Enum.any?(execution_tools, fn {_name, tool} -> Tool.private?(tool) end)

      opts =
        Map.merge(params, %{
          normalized_tools: execution_tools,
          tool_executor: tool_executor,
          parsed_signature: parsed_signature,
          signature_str: signature_str,
          tool_failure_token: tool_failure_token,
          tools_meta: tools_meta,
          private_tool_authority?: private_tool_authority?
        })

      execute_program(source, opts)
    else
      {:error, {:invalid_tool, tool_name, reason}} ->
        Step.error(:invalid_tool, "Tool '#{tool_name}': #{inspect(reason)}", memory, %{})
        |> then(&{:error, &1})
        |> prepare_pre_setup_error(params)

      {:error, {:invalid_signature, msg}} ->
        Step.error(:parse_error, "Invalid signature: #{msg}", memory, %{})
        |> then(&{:error, &1})
        |> prepare_pre_setup_error(params)

      {:error, {:invalid_config, msg}} ->
        Step.error(:invalid_config, msg, memory, %{})
        |> then(&{:error, &1})
        |> prepare_pre_setup_error(params)
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

  defp validate_loop_limit(nil), do: :ok

  defp validate_loop_limit(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_loop_limit(limit) do
    {:error,
     {:invalid_config, ":loop_limit must be a positive integer or nil, got " <> inspect(limit)}}
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

    validation_opts = [
      max_program_bytes: max_program_bytes,
      compile_timeout: compile_timeout,
      compile_max_heap: max_heap,
      max_heap: max_heap
    ]

    case check_native_mode(source, validation_opts, false) do
      :ok -> :ok
      {:error, step} -> validate_error(step)
    end
  end

  # The names are carried structurally so neither this nor any other consumer
  # has to parse the diagnostic prose (which now also carries hints).
  defp validate_error(%{
         fail: %{reason: :unbound_var, details: %{unbound_names: [_ | _] = names}}
       }),
       do: {:error, names}

  defp validate_error(%{fail: %{reason: :unbound_var, message: message}}) do
    names = message |> String.split(": ", parts: 2) |> List.last() |> String.split(", ")
    {:error, names}
  end

  defp validate_error(%{fail: %{reason: :parse_error, message: message}}),
    do: {:error, ["Parse error: #{message}"]}

  defp validate_error(%{fail: %{message: message}}), do: {:error, [message]}

  @doc false
  @spec check_native(String.t(), keyword()) :: :ok | {:error, Step.t()}
  def check_native(source, opts \\ []) when is_binary(source),
    do: check_native_mode(source, opts, true)

  defp check_native_mode(source, opts, check_tool_resolution?) do
    reject_imported_tool_cache!(opts)
    memory = Keyword.get(opts, :memory, %{})
    tools = Keyword.get(opts, :tools, %{})
    max_program_bytes = Keyword.get(opts, :max_program_bytes, @default_max_program_bytes)
    params = opts |> Keyword.put(:turn_history_mode, :native) |> run_params()

    if byte_size(source) > max_program_bytes do
      {:error,
       Step.error(
         :program_too_large,
         "program size #{byte_size(source)} bytes exceeds limit of #{max_program_bytes}",
         memory,
         %{}
       )}
    else
      with {:ok, prelude} <- attach_prelude(Keyword.get(opts, :prelude), tools, memory),
           :ok <- validate_parallel_config(params.worker_max_heap, params.max_parallel_workers),
           {:ok, normalized_tools} <- normalize_tools(tools) do
        compile_opts =
          Map.merge(params, %{
            memory: memory,
            normalized_tools: normalized_tools,
            prelude: prelude,
            check_tool_resolution: check_tool_resolution?
          })

        case compile_program(source, compile_opts) do
          {:ok, _core_ast, _prelude_calls} -> :ok
          {:error, %Step{} = step} -> {:error, step}
        end
      else
        {:error, %Step{} = step} ->
          {:error, step}

        {:error, {:invalid_tool, tool_name, reason}} ->
          {:error,
           Step.error(:invalid_tool, "Tool '#{tool_name}': #{inspect(reason)}", memory, %{})}

        {:error, {:invalid_config, message}} ->
          {:error, Step.error(:invalid_config, message, memory, %{})}
      end
    end
  end

  defp execute_program(source, opts) do
    case compile_program(source, Map.put(opts, :check_tool_resolution, true)) do
      {:ok, core_ast, prelude_calls} ->
        core_ast
        |> execute_eval(apply_run_deadline(opts))
        |> put_prelude_calls(prelude_calls)

      {:error, %Step{}} = compile_error ->
        prepare_pre_setup_error(compile_error, opts)
    end
  end

  defp compile_program(source, opts) do
    %{
      memory: memory,
      normalized_tools: normalized_tools,
      max_symbols: max_symbols,
      compile_timeout: compile_timeout,
      compile_max_heap: compile_max_heap,
      check_tool_resolution: check_tool_resolution?
    } = opts

    prelude = Map.get(opts, :prelude)
    prelude_filtered_exports = Map.get(opts, :prelude_filtered_exports, [])

    # The compile sandbox closure must capture ONLY what parse/analyze need:
    # tool names, never tool closures or continuation memory (whose data can be
    # megabytes of granted environment). It returns the AST-bounded unresolved
    # variable candidates; the caller then performs direct map lookups for only
    # those names instead of enumerating the memory grant.
    tool_names = Map.keys(normalized_tools)

    public_tool_names =
      normalized_tools
      |> Enum.reject(fn {_name, tool} -> Tool.private?(tool) end)
      |> Enum.map(fn {name, _tool} -> name end)

    compile_fn = fn ->
      with {:ok, raw_ast} <- Parser.parse(source),
           :ok <- check_symbol_limit(raw_ast, max_symbols),
           {:ok, core_ast} <- Analyze.analyze(raw_ast, prelude, prelude_filtered_exports),
           :ok <- CoreAST.validate(core_ast) do
        undefined_vars = core_ast |> collect_undefined_vars(MapSet.new()) |> Enum.uniq()

        tool_check =
          if check_tool_resolution?,
            do: check_undefined_tools(core_ast, public_tool_names, tool_names, prelude),
            else: :ok

        prelude_calls = static_prelude_calls(core_ast, prelude)
        {:ok, core_ast, undefined_vars, tool_check, prelude_calls}
      end
    end

    compile_opts = [
      timeout: compile_timeout,
      max_heap: compile_max_heap,
      link: Map.get(opts, :link, false)
    ]

    case PtcRunner.Sandbox.run_bounded(compile_fn, compile_opts) do
      {:ok, {:ok, core_ast, undefined_vars, tool_check, prelude_calls}} ->
        with :ok <- check_undefined_var_candidates(undefined_vars, memory),
             :ok <- tool_check do
          {:ok, core_ast, prelude_calls}
        else
          {:error, _} = compile_error ->
            handle_compile_error(compile_error, memory)
        end

      {:ok, {:error, _} = compile_error} ->
        handle_compile_error(compile_error, memory)

      {:error, {:timeout, ms}} ->
        Step.error(
          :compile_timeout,
          "compilation exceeded #{ms}ms limit",
          memory,
          %{}
        )
        |> then(&{:error, &1})

      {:error, {:memory_exceeded, bytes}} ->
        Step.error(
          :compile_memory_exceeded,
          "compilation exceeded #{bytes} byte heap limit",
          memory,
          %{}
        )
        |> then(&{:error, &1})

      {:error, {:execution_error, msg}} ->
        Step.error(:compile_error, "compilation failed: #{msg}", memory, %{})
        |> then(&{:error, &1})
    end
  end

  defp apply_run_deadline(%{run_deadline_ms: nil} = opts), do: opts

  defp apply_run_deadline(%{run_deadline_ms: deadline_ms, timeout: timeout} = opts) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 1)
    %{opts | timeout: min(timeout, remaining_ms)}
  end

  defp put_prelude_calls({status, %Step{} = step}, prelude_calls)
       when status in [:ok, :error] and is_list(prelude_calls),
       do: {status, %{step | prelude_calls: prelude_calls}}

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

  defp prepare_pre_setup_error(result, %{turn_history_mode: :native}), do: result

  defp prepare_pre_setup_error({:error, %Step{} = step}, opts) do
    sandbox_opts =
      [
        timeout: opts.timeout,
        max_heap: opts.max_heap,
        prepare_context: &internalize_public_input(&1, :memory),
        eval_fn: fn _ast, prepared_memory -> {:ok, prepared_memory, %{}} end,
        link: Map.get(opts, :link, false),
        telemetry_run: Map.get(opts, :telemetry_run)
      ]
      |> put_setup_max_heap(opts.setup_max_heap)

    case PtcRunner.Sandbox.execute(:prepare_error_memory, step.memory, sandbox_opts) do
      {:ok, prepared_memory, _metrics, %{}} ->
        {:error, %{step | memory: prepared_memory}}

      {:error, {:public_input_error, :memory, _reason}} = error ->
        handle_execute_result(error, %{memory: step.memory})

      {:error, {:timeout, %{timeout_ms: timeout_ms} = info}} ->
        {:error, Step.error(:timeout, "execution exceeded #{timeout_ms}ms limit", %{}, info)}

      {:error, {:memory_exceeded, info}} ->
        memory_exceeded_step(info, %{})

      {:error, reason} ->
        {:error,
         Step.error(:setup_error, "environment setup failed: #{inspect(reason)}", %{}, %{})}
    end
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
      loop_limit: loop_limit,
      filter_context: filter_context,
      pmap_timeout: pmap_timeout,
      pmap_max_concurrency: pmap_max_concurrency,
      tools_meta: tools_meta,
      max_tool_calls: max_tool_calls,
      max_tool_call_result_bytes: max_tool_call_result_bytes,
      turn_history_mode: turn_history_mode,
      strict_data: strict_data,
      data_grants: data_grants,
      missing_data_params_message: missing_data_params_message,
      strict_transitive_calls: strict_transitive_calls,
      private_tool_authority?: private_tool_authority?,
      direct_namespaces: direct_namespaces,
      transitive_namespace_requirers: transitive_namespace_requirers,
      prelude_export_mask: prelude_export_mask,
      shipped_export_owners: shipped_export_owners,
      attached_component_ids: attached_component_ids
    } = opts

    prelude = Map.get(opts, :prelude)

    filter_context? = filter_context and is_nil(prelude)

    ctx =
      if filter_context?,
        do: DataKeys.prefilter_context(core_ast, ctx),
        else: ctx

    context = PtcRunner.Lisp.Context.new(ctx, memory, normalized_tools, turn_history)

    parallel_budget = ParallelBudget.new(max_parallel_workers)

    :telemetry.execute(
      [:ptc_runner, :parallel, :budget],
      %{capacity: max_parallel_workers},
      maybe_put_live_run(%{budget: parallel_budget}, Map.get(opts, :telemetry_run))
    )

    eval_opts =
      [
        max_print_length: max_print_length,
        loop_limit: loop_limit,
        max_heap: max_heap,
        worker_max_heap: worker_max_heap,
        parallel_budget: parallel_budget,
        pmap_timeout: pmap_timeout,
        parallel_deadline_cap: Map.get(opts, :parallel_deadline_cap),
        pmap_max_concurrency: pmap_max_concurrency,
        tools_meta: tools_meta,
        tool_failure_token: Map.fetch!(opts, :tool_failure_token),
        max_tool_calls: max_tool_calls,
        max_tool_call_result_bytes: max_tool_call_result_bytes,
        strict_data: strict_data,
        data_grants: data_grants,
        missing_data_params_message: missing_data_params_message,
        strict_transitive_calls: strict_transitive_calls,
        private_tool_authority?: private_tool_authority?,
        direct_namespaces: direct_namespaces,
        transitive_namespace_requirers: transitive_namespace_requirers,
        prelude_export_mask: prelude_export_mask,
        shipped_export_owners: shipped_export_owners,
        attached_component_ids: attached_component_ids,
        prelude: prelude
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    eval_fn = fn _ast, sandbox_context ->
      try do
        case Eval.eval_with_context_captured(
               core_ast,
               sandbox_context.ctx,
               sandbox_context.memory,
               Env.initial(),
               tool_executor,
               sandbox_context.turn_history,
               eval_opts
             ) do
          {:control, :return, value, context} ->
            {:ok, {:return_signal, value}, context}

          {:control, :fail, value, context} ->
            {:ok, {:fail_signal, value}, context}

          {:control, :recur, values, context} ->
            {:error, {:invalid_recur, values}, context}

          {:raise, kind, reason, stacktrace, context} ->
            {:error, unexpected_eval_error(kind, reason, stacktrace), context}

          outcome ->
            outcome
        end
      rescue
        e ->
          {:error, {:runtime_error, Exception.message(e)}}
      end
    end

    sandbox_opts =
      [
        timeout: timeout,
        max_heap: max_heap,
        prepare_context:
          prepare_context(
            turn_history_mode,
            core_ast,
            filter_context?
          ),
        eval_fn: eval_fn,
        link: Map.get(opts, :link, false),
        telemetry_run: Map.get(opts, :telemetry_run)
      ]
      |> put_failure_snapshot(turn_history_mode)
      |> put_setup_max_heap(setup_max_heap)

    core_ast
    |> PtcRunner.Sandbox.execute(context, sandbox_opts)
    |> handle_execute_result(opts)
  end

  defp maybe_put_live_run(metadata, live_run) when is_pid(live_run),
    do: Map.put(metadata, :live_run, live_run)

  defp maybe_put_live_run(metadata, _live_run), do: metadata

  defp unexpected_eval_error(:error, exception, _stacktrace) when is_exception(exception),
    do: {:runtime_error, Exception.message(exception)}

  defp unexpected_eval_error(:error, reason, _stacktrace),
    do: {:runtime_error, Exception.format_banner(:error, reason)}

  defp unexpected_eval_error(:throw, reason, stacktrace),
    do: {:execution_error, "Process terminated: #{inspect({{:nocatch, reason}, stacktrace})}"}

  defp unexpected_eval_error(:exit, reason, _stacktrace),
    do: {:execution_error, "Process terminated: #{inspect(reason)}"}

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
         {:ok, {:error_with_ctx, reason, rollback_memory}, metrics, %EvalContext{} = eval_ctx},
         _opts
       ) do
    eval_error_step(reason, metrics, rollback_memory, eval_ctx)
  end

  defp handle_execute_result(
         {:ok, {:error_with_ctx, reason}, metrics, %EvalContext{} = eval_ctx},
         %{memory: memory}
       ) do
    eval_error_step(reason, metrics, memory, eval_ctx)
  end

  defp handle_execute_result({:error, reason, rollback_memory}, opts) do
    handle_execute_result({:error, reason}, %{opts | memory: rollback_memory})
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

    validate_return_value(parsed_signature, sig, step)
  end

  defp handle_execute_result(
         {:error, {:timeout, %{phase: :setup, timeout_ms: timeout_ms} = info}},
         _opts
       ) do
    {:error, Step.error(:timeout, "execution exceeded #{timeout_ms}ms limit", %{}, info)}
  end

  defp handle_execute_result(
         {:error, {:timeout, %{phase: :eval, timeout_ms: timeout_ms} = info}},
         %{memory: memory}
       ) do
    {:error, Step.error(:timeout, "execution exceeded #{timeout_ms}ms limit", memory, info)}
  end

  # The setup worker was killed while importing the grant, so do not traverse
  # and project that same oversized memory again in the unbounded caller.
  defp handle_execute_result(
         {:error, {:memory_exceeded, %{phase: :setup} = info}},
         _opts
       ) do
    memory_exceeded_step(info, %{})
  end

  defp handle_execute_result({:error, {:memory_exceeded, info}}, %{memory: memory}) do
    memory_exceeded_step(info, memory)
  end

  # A malformed wrapper inside continuation memory is not a valid runtime
  # value. Do not copy it into the public error Step: boundary projection could
  # replace the useful validation failure with a secondary projection error.
  # Invalid context/history, however, must preserve otherwise-valid memory.
  defp handle_execute_result(
         {:error, {:public_input_error, source, reason}},
         %{memory: memory}
       )
       when source in [:context, :memory, :turn_history] and
              is_tuple(reason) and
              elem(reason, 0) in [
                :invalid_keyword,
                :invalid_lisp_list,
                :invalid_symbol_ref,
                :symbol_ref_collision
              ] do
    reason_atom = elem(reason, 0)

    safe_memory =
      if source == :memory and
           reason_atom in [
             :invalid_keyword,
             :invalid_lisp_list,
             :invalid_symbol_ref,
             :symbol_ref_collision
           ],
         do: %{},
         else: memory

    {:error, Step.error(reason_atom, format_error(reason), safe_memory, error_details(reason))}
  end

  defp handle_execute_result({:error, {reason_atom, _, _} = reason}, %{memory: memory})
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, format_error(reason), memory, error_details(reason))}
  end

  defp handle_execute_result({:error, {reason_atom, _} = reason}, %{memory: memory})
       when is_atom(reason_atom) do
    {:error, Step.error(reason_atom, format_error(reason), memory, error_details(reason))}
  end

  defp handle_execute_result({:error, reason}, %{memory: memory}) do
    {:error, Step.error(direct_error_reason_atom(reason), format_error(reason), memory, %{})}
  end

  defp direct_error_reason_atom(reason), do: elem(reason, 0)

  defp eval_error_step(reason, metrics, memory, %EvalContext{} = eval_ctx) do
    reason_atom = if is_tuple(reason), do: elem(reason, 0), else: reason
    effects = Effects.chronological(eval_ctx.effects)

    reversed_tool_calls = effects.tool_calls
    reversed_pmap_calls = effects.pmap_calls

    tool_child_traces =
      reversed_tool_calls
      |> Enum.filter(&Map.has_key?(&1, :child_trace_id))
      |> Enum.map(& &1.child_trace_id)

    pmap_child_traces =
      reversed_pmap_calls
      |> Enum.flat_map(& &1.child_trace_ids)

    child_traces = tool_child_traces ++ pmap_child_traces

    tool_child_steps =
      reversed_tool_calls
      |> Enum.filter(&Map.has_key?(&1, :child_step))
      |> Enum.map(& &1.child_step)

    pmap_child_steps =
      reversed_pmap_calls
      |> Enum.flat_map(&Map.get(&1, :child_steps, []))

    child_steps = tool_child_steps ++ pmap_child_steps

    cleaned_tool_calls = Enum.map(reversed_tool_calls, &Map.delete(&1, :child_step))
    cleaned_pmap_calls = Enum.map(reversed_pmap_calls, &Map.delete(&1, :child_steps))

    step = %Step{
      return: nil,
      fail: %{
        reason: reason_atom,
        message: format_error(reason),
        details: error_details(reason)
      },
      memory: memory,
      signature: nil,
      usage: metrics,
      turns: nil,
      trace_id: nil,
      parent_trace_id: nil,
      field_descriptions: nil,
      prints: effects.prints,
      tool_calls: cleaned_tool_calls,
      pmap_calls: cleaned_pmap_calls,
      prelude_call_counts: effects.prelude_call_counts,
      child_traces: child_traces,
      child_steps: child_steps
    }

    {:error, step}
  end

  defp error_details({:arithmetic_error, token})
       when token in [:division_by_zero, :integer_overflow, :bad_argument],
       do: %{token: token}

  defp error_details({:arity_error, details}) when is_map(details), do: details

  defp error_details({:not_callable, {:data_ref, symbol}}) when is_binary(symbol),
    do: %{name: symbol}

  defp error_details({:not_callable, details}) when is_map(details), do: details

  defp error_details({:loop_limit_exceeded, n}) when is_integer(n), do: %{limit: n}

  defp error_details({:prelude_contract_error, _message, details}) when is_map(details),
    do: details

  defp error_details({:pmap_error, _message, taxonomy}) when is_map(taxonomy),
    do: retain_parallel_failure_metadata(taxonomy)

  defp error_details({:pcalls_error, _index, _message, taxonomy}) when is_map(taxonomy),
    do: retain_parallel_failure_metadata(taxonomy)

  defp error_details({:runtime_limit_exceeded, _message, details}) when is_map(details),
    do: details

  defp error_details({:model_output_truncated, _message, details}) when is_map(details),
    do: details

  defp error_details({:invalid_agent_config, _message, details}) when is_map(details),
    do: details

  defp error_details({:result_contract_failed, _message, details}) when is_map(details),
    do: details

  defp error_details({:llm_provider_failed, _message, details}) when is_map(details),
    do: details

  defp error_details({category, _message, details})
       when category in [
              :unsupported_java_class,
              :unsupported_java_member,
              :java_arity_error,
              :java_type_error,
              :java_domain_error,
              :invalid_java_string,
              :java_handler_contract_error
            ] and is_map(details),
       do: details

  defp error_details(_reason), do: %{}

  defp retain_parallel_failure_metadata(metadata) do
    LLMReplayDiagnostic.retain_parallel_failure_metadata(metadata)
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

  def format_error({category, message, details})
      when category in [
             :unsupported_java_class,
             :unsupported_java_member,
             :java_arity_error,
             :java_type_error,
             :java_domain_error,
             :invalid_java_string,
             :java_handler_contract_error
           ] and is_binary(message) and is_map(details) do
    case EvaluatorError.lisp_message(category, details) do
      {:ok, public_message} -> public_message
      :error -> "Java interop error"
    end
  end

  # Handle Analyze errors: {:invalid_arity, atom, message}
  def format_error({:invalid_arity, _atom, msg}) when is_binary(msg), do: "Analysis error: #{msg}"

  def format_error({:unsupported_java_member, namespace, member}),
    do: unsupported_java_member_message(namespace, member)

  def format_error({:unsupported_java_class, class}),
    do:
      "Analysis error: unsupported Java class #{class}. Admitted Java classes: " <>
        Enum.join(admitted_java_class_names(), ", ")

  def format_error({:java_arity_error, reference_id, details}),
    do: java_arity_error_message(reference_id, details)

  # Handle Eval errors with specific types
  def format_error({:unbound_var, name}) do
    msg = Helpers.format_closure_error({:unbound_var, name})
    # Lowercase first letter to match existing style
    <<first::utf8, rest::binary>> = msg
    <<String.downcase(<<first::utf8>>)::binary, rest::binary>>
  end

  def format_error({:not_callable, {:data_ref, symbol}}) when is_binary(symbol),
    do: "not callable: #{symbol}"

  def format_error({:not_callable, details}) when is_map(details) do
    case EvaluatorError.lisp_message(:not_callable, details) do
      {:ok, message} -> message
      :error -> "not callable: value"
    end
  end

  def format_error({:not_callable, _value}) do
    case EvaluatorError.lisp_message(:not_callable, %{}) do
      {:ok, message} -> message
      :error -> "not callable: value"
    end
  end

  def format_error({:arity_error, details}) when is_map(details) do
    case EvaluatorError.lisp_message(:arity_error, details) do
      {:ok, message} -> message
      :error -> "arity error"
    end
  end

  def format_error({:arity_error, msg}) when is_binary(msg), do: "arity error: #{msg}"

  def format_error({:arithmetic_error, token})
      when token in [:division_by_zero, :integer_overflow, :bad_argument] do
    case EvaluatorError.lisp_message(:arithmetic_error, %{token: token}) do
      {:ok, message} -> message
      :error -> "arithmetic error"
    end
  end

  def format_error({:arithmetic_error, msg}) when is_binary(msg) do
    token =
      cond do
        msg == "division by zero" or String.contains?(msg, "division by zero") ->
          :division_by_zero

        msg == "integer overflow" or String.contains?(msg, "integer overflow") ->
          :integer_overflow

        true ->
          :bad_argument
      end

    format_error({:arithmetic_error, token})
  end

  # Issue #878: dedicated formatter for unsupported interop methods.
  # Avoids the `:unbound_var` path which would treat the message as a
  # variable name and append an irrelevant hyphen-suggestion hint.
  def format_error({:unsupported_method, name, available}) do
    "Unsupported method '#{name}'. Supported interop methods: #{available}. Use (.method obj) syntax."
  end

  # Issue #884/#1710: friendly message for an opt-in loop iteration cap (DIV-01).
  # Without this clause, the raw Elixir tuple {:loop_limit_exceeded, n}
  # leaks to the LLM via the generic inspect-based fallback.
  def format_error({:loop_limit_exceeded, n}) do
    case EvaluatorError.lisp_message(:loop_limit_exceeded, %{limit: n}) do
      {:ok, message} -> message
      :error -> "loop limit exceeded"
    end
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
      "the environment grant (#{grant_filter_reason(reason)})."
  end

  def format_error({:runtime_error, msg}), do: "Runtime error: #{msg}"

  def format_error({:pmap_error, msg, _taxonomy}) when is_binary(msg),
    do: format_error({:pmap_error, msg})

  def format_error({:pcalls_error, index, msg, _taxonomy})
      when is_integer(index) and is_binary(msg),
      do: format_error({:pcalls_error, index, msg})

  def format_error({:tool_error, name, reason}),
    do: UntrustedRenderer.tool_failure(name, reason)

  # Handle other 3-tuple error formats from Eval: {type, message, data}
  def format_error({type, msg, _}) when is_atom(type) and is_binary(msg),
    do: "#{type}: #{strip_typed_prefix(msg, type)}"

  def format_error({type, msg}) when is_atom(type) and is_binary(msg),
    do: "#{type}: #{strip_typed_prefix(msg, type)}"

  def format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  defp strip_typed_prefix(message, type) when is_atom(type) and is_binary(message) do
    String.replace_prefix(message, Atom.to_string(type) <> ": ", "")
  end

  defp grant_filter_reason(:ptc_tool_denied), do: "ptc_tool_denied"
  defp grant_filter_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp grant_filter_reason(_reason), do: "grant_filtered"

  # Human-readable kill message from `PtcRunner.Sandbox.memory_exceeded_info/0`
  # diagnostics (setup-phase kills are a grant problem, not a program
  # problem) or the integer byte limit reported by `Sandbox.run_bounded/2`.
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

  defp put_failure_snapshot(opts, :public), do: [{:failure_snapshot, & &1.memory} | opts]
  defp put_failure_snapshot(opts, :native), do: opts

  defp prepare_context(mode, core_ast, filter_context?) do
    fn context ->
      # Public values must be validated and normalized before filtering so
      # symbol-reference keys have their canonical internal spelling. This
      # complete pass stays inside the setup worker's heap ceiling and
      # deadline. An AST-bounded caller-side lookup has already retained only
      # referenced keys before the sandbox copy. A prelude disables filtering
      # because its exports may read data keys absent from the user program's
      # own Core AST.
      with {:ok, prepared} <- prepare_context_values(mode, context) do
        if filter_context?,
          do: {:ok, %{prepared | ctx: DataKeys.filter_context(core_ast, prepared.ctx)}},
          else: {:ok, prepared}
      end
    end
  end

  defp prepare_context_values(:native, context), do: {:ok, context}

  defp prepare_context_values(:public, context) do
    with {:ok, memory} <- internalize_public_input(context.memory, :memory),
         {:ok, ctx} <- internalize_public_input(context.ctx, :context),
         {:ok, history} <- internalize_public_input(context.turn_history, :turn_history) do
      {:ok, %{context | ctx: ctx, memory: memory, turn_history: history}}
    end
  end

  defp internalize_public_input(value, source) do
    case Format.internalize_symbol_refs(value) do
      {:ok, projected} -> {:ok, projected}
      {:error, reason} -> {:error, {:public_input_error, source, reason}}
    end
  end

  # V2 simplified memory contract: pass through all values unchanged.
  # Storage is explicit via `def` (values persist in user_ns).
  # No implicit map merge or :return key handling.
  defp apply_memory_contract(value, precision, %EvalContext{} = ctx, preserve_runtime_callables) do
    effects = Effects.chronological(ctx.effects)
    reversed_tool_calls = effects.tool_calls
    reversed_pmap_calls = effects.pmap_calls

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
      signature: nil,
      usage: nil,
      turns: nil,
      failure_origin: ctx.failure_origin,
      return_origin: ctx.return_origin,
      prints: effects.prints,
      tool_calls: cleaned_tool_calls,
      pmap_calls: cleaned_pmap_calls,
      prelude_call_counts: effects.prelude_call_counts,
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
  # matches the parser's canonicalization and the string-keyed component
  # signature boundary.
  defp externalize_lisp_values(value, boundary \\ :public)

  defp externalize_lisp_values(%Program{} = program, boundary) do
    externalize_lisp_values(
      %{program?: true, byte_size: program.byte_size, digest: program.digest},
      boundary
    )
  end

  defp externalize_lisp_values(%Step{memory: memory} = step, _boundary) when is_map(memory),
    do: project_native_result({:ok, step}) |> elem(1)

  defp externalize_lisp_values(%Step{} = step, _boundary),
    do: public_result({:ok, %{step | memory: externalize_lisp_values(step.memory)}}) |> elem(1)

  defp externalize_lisp_values(%{__struct__: LispKeyword} = keyword, :kernel_json) do
    if LispKeyword.valid?(keyword), do: keyword.name, else: keyword
  end

  defp externalize_lisp_values(%{__struct__: LispKeyword} = keyword, :public) do
    if LispKeyword.valid?(keyword), do: SourceAtoms.intern(keyword.name), else: keyword
  end

  defp externalize_lisp_values(
         {:closure, _params, _body, _env, _turn_history, _metadata},
         _boundary
       ),
       do: %Format.Fn{params: "..."}

  defp externalize_lisp_values(%EnvBuiltin{}, _boundary), do: %Format.Builtin{}

  defp externalize_lisp_values(%RuntimeCallable{} = callable, _boundary) do
    RuntimeCallable.label(callable)
  end

  defp externalize_lisp_values(value, _boundary) when is_function(value),
    do: %Format.Fn{params: "..."}

  defp externalize_lisp_values(%Var{name: name} = var, _boundary) when is_binary(name) do
    %{var | name: SourceAtoms.intern(name)}
  end

  defp externalize_lisp_values({:var, name}, _boundary) when is_binary(name),
    do: %Var{name: SourceAtoms.intern(name)}

  defp externalize_lisp_values({:var, name}, _boundary) when is_atom(name),
    do: %Var{name: name}

  defp externalize_lisp_values({:symbol_ref, name}, _boundary) when is_binary(name),
    do: %Format.SymbolRef{name: name}

  defp externalize_lisp_values({:__ptc_return__, inner}, boundary) do
    {:__ptc_return__, externalize_lisp_values(inner, boundary)}
  end

  defp externalize_lisp_values({:__ptc_fail__, inner}, boundary) do
    {:__ptc_fail__, externalize_lisp_values(inner, boundary)}
  end

  defp externalize_lisp_values({:normal, function}, _boundary) when is_function(function),
    do: %Format.Builtin{}

  # Context-dispatched builtins (`println`, `apply`, the introspection forms).
  # Without this the raw binding tuple escapes as the step's return value.
  defp externalize_lisp_values({:special, name}, _boundary) when is_atom(name),
    do: %Format.Builtin{}

  defp externalize_lisp_values({:variadic, function, _identity}, _boundary)
       when is_function(function),
       do: %Format.Builtin{}

  defp externalize_lisp_values({:variadic_nonempty, name, function}, _boundary)
       when is_atom(name) and is_function(function),
       do: %Format.Builtin{}

  defp externalize_lisp_values({:multi_arity, name, functions}, _boundary)
       when is_atom(name) and is_tuple(functions),
       do: %Format.Builtin{}

  defp externalize_lisp_values({:collect, function}, _boundary) when is_function(function),
    do: %Format.Fn{params: "..."}

  defp externalize_lisp_values({:juxt_fn, _fns}, _boundary), do: %Format.Fn{params: "..."}

  defp externalize_lisp_values({:partial_fn, _f, _fixed}, _boundary),
    do: %Format.Fn{params: "..."}

  defp externalize_lisp_values({:comp_fn, _fns}, _boundary), do: %Format.Fn{params: "..."}

  defp externalize_lisp_values({:complement_fn, _f}, _boundary),
    do: %Format.Fn{params: "..."}

  defp externalize_lisp_values({:constantly_fn, _value}, _boundary),
    do: %Format.Fn{params: "..."}

  defp externalize_lisp_values({:every_pred_fn, _preds}, _boundary),
    do: %Format.Fn{params: "..."}

  defp externalize_lisp_values({:some_fn, _fns}, _boundary), do: %Format.Fn{params: "..."}

  defp externalize_lisp_values({:fnil_fn, _f, _default}, _boundary),
    do: %Format.Fn{params: "..."}

  defp externalize_lisp_values(value, boundary) when is_list(value) do
    Enum.map(value, &externalize_lisp_values(&1, boundary))
  end

  defp externalize_lisp_values(%MapSet{} = set, boundary) do
    items = Enum.map(set, &externalize_lisp_values(&1, boundary))
    frequencies = Enum.frequencies(items)
    next_ordinal = next_collision_ordinal(items, :set)

    items
    |> Enum.map_reduce(next_ordinal, fn item, ordinal ->
      if Map.fetch!(frequencies, item) > 1 do
        {%ExternalizedCollision{collection: :set, value: item, ordinal: ordinal}, ordinal + 1}
      else
        {item, ordinal}
      end
    end)
    |> elem(0)
    |> MapSet.new()
  end

  defp externalize_lisp_values(value, boundary) when is_map(value) and not is_struct(value) do
    pairs =
      Enum.map(value, fn {key, item} ->
        externalized_key = externalize_lisp_values(key, boundary)
        display_key = if match?(%LispKeyword{}, key), do: key, else: externalized_key
        {externalized_key, display_key, externalize_lisp_values(item, boundary)}
      end)

    frequencies = Enum.frequencies_by(pairs, &elem(&1, 0))
    next_ordinal = pairs |> Enum.map(&elem(&1, 0)) |> next_collision_ordinal(:map)

    pairs
    |> Enum.map_reduce(next_ordinal, fn {key, display_key, item}, ordinal ->
      if Map.fetch!(frequencies, key) > 1 do
        {{%ExternalizedCollision{
            collection: :map,
            value: display_key,
            ordinal: ordinal
          }, item}, ordinal + 1}
      else
        {{key, item}, ordinal}
      end
    end)
    |> elem(0)
    |> Map.new()
  end

  defp externalize_lisp_values(value, boundary) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&externalize_lisp_values(&1, boundary))
    |> List.to_tuple()
  end

  defp externalize_lisp_values(value, boundary) when is_struct(value) do
    fields =
      value
      |> Map.from_struct()
      |> Map.new(fn {field, item} -> {field, externalize_lisp_values(item, boundary)} end)

    struct(value.__struct__, fields)
  end

  defp externalize_lisp_values(atom, :kernel_json) when is_atom(atom) do
    if LispKeyword.keyword?(atom), do: Atom.to_string(atom), else: atom
  end

  defp externalize_lisp_values(value, _boundary), do: value

  defp next_collision_ordinal(values, collection) do
    values
    |> Enum.reduce(-1, fn
      %ExternalizedCollision{collection: ^collection, ordinal: ordinal}, highest
      when is_integer(ordinal) and ordinal >= 0 ->
        max(ordinal, highest)

      _value, highest ->
        highest
    end)
    |> Kernel.+(1)
  end

  defp validate_projection_collisions(_value, :public), do: :ok

  defp validate_projection_collisions(value, :kernel_json) do
    case projection_collision(value, []) do
      nil -> :ok
      {path, collection} -> {:error, {:public_projection_collision, path, collection}}
    end
  end

  defp projection_collision(%ExternalizedCollision{collection: collection}, path),
    do: {Enum.reverse(path), collection}

  defp projection_collision(value, path) when is_list(value) do
    find_projection_collision(value, path, :list)
  end

  defp projection_collision(value, path) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> find_projection_collision(path, :tuple)
  end

  defp projection_collision(%MapSet{} = set, path) do
    items = MapSet.to_list(set)

    if encoded_projection_collision?(items, &Jason.encode(&1, maps: :strict)) do
      {Enum.reverse(path), :set}
    else
      find_projection_collision(items, path, :set)
    end
  end

  defp projection_collision(value, path) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while(nil, fn {field, item}, nil ->
      case projection_collision(item, [{:struct_field, field} | path]) do
        nil -> {:cont, nil}
        collision -> {:halt, collision}
      end
    end)
  end

  defp projection_collision(value, path) when is_map(value) and not is_struct(value) do
    entries = Map.to_list(value)

    if encoded_projection_collision?(entries, fn {key, _item} ->
         Jason.encode(%{key => nil}, maps: :strict)
       end) do
      {Enum.reverse(path), :map}
    else
      Enum.with_index(entries)
      |> Enum.reduce_while(nil, fn {{key, item}, index}, nil ->
        case projection_collision(key, [{:map_key, index} | path]) ||
               projection_collision(item, [{:map_value, index} | path]) do
          nil -> {:cont, nil}
          collision -> {:halt, collision}
        end
      end)
    end
  end

  defp projection_collision(_value, _path), do: nil

  defp find_projection_collision(values, path, collection) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while(nil, fn {item, index}, nil ->
      case projection_collision(item, [{collection, index} | path]) do
        nil -> {:cont, nil}
        collision -> {:halt, collision}
      end
    end)
  end

  defp encoded_projection_collision?(values, encoder) do
    identities =
      Enum.flat_map(values, fn value ->
        case encoder.(value) do
          {:ok, encoded} -> [encoded]
          {:error, _reason} -> []
        end
      end)

    length(identities) != MapSet.size(MapSet.new(identities))
  end

  # Memory keys are `def`-bound variable names. The evaluator stores their
  # canonical binary spelling regardless of the parser's bounded internal atom
  # representation.
  defp externalize_memory_entries(entries) do
    pairs =
      Enum.map(entries, fn {key, item} ->
        externalized_key = externalize_memory_key(key)
        display_key = if match?(%LispKeyword{}, key), do: key, else: externalized_key
        {externalized_key, display_key, externalize_lisp_values(item)}
      end)

    frequencies = Enum.frequencies_by(pairs, &elem(&1, 0))
    next_ordinal = pairs |> Enum.map(&elem(&1, 0)) |> next_collision_ordinal(:map)

    pairs
    |> Enum.map_reduce(next_ordinal, fn {key, display_key, item}, ordinal ->
      if Map.fetch!(frequencies, key) > 1 do
        {{%ExternalizedCollision{
            collection: :map,
            value: display_key,
            ordinal: ordinal
          }, item}, ordinal + 1}
      else
        {{key, item}, ordinal}
      end
    end)
    |> elem(0)
    |> Map.new()
  end

  defp externalize_memory_key(%{__struct__: LispKeyword} = keyword),
    do: externalize_lisp_values(keyword)

  defp externalize_memory_key(name) when is_binary(name), do: name
  defp externalize_memory_key(other), do: externalize_lisp_values(other)

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
  # side effects can execute. `undefined` comes from the symbol-bounded compile
  # worker. Checking only those candidate names avoids enumerating continuation
  # memory in the unbounded caller process.
  defp check_undefined_var_candidates(undefined, memory) do
    vars = Enum.reject(undefined, &memory_binding?(memory, &1))

    if vars == [] do
      :ok
    else
      label = if length(vars) == 1, do: "Undefined variable", else: "Undefined variables"
      message = "#{label}: #{Enum.join(vars, ", ")}#{Helpers.unresolved_name_suffix(vars)}"
      {:error, Step.error(:unbound_var, message, %{}, %{unbound_names: vars})}
    end
  end

  defp memory_binding?(memory, name) when is_binary(name) do
    Map.has_key?(memory, name)
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

  defp collect_tool_names({tag, _reference_id, args}, acc)
       when tag in [:java_static, :java_new],
       do: Enum.reduce(args, acc, &collect_tool_names/2)

  defp collect_tool_names({tag, _reference_id, receiver, args}, acc)
       when tag in [:java_instance, :java_dot] do
    Enum.reduce(args, collect_tool_names(receiver, acc), &collect_tool_names/2)
  end

  defp collect_tool_names({tag, _reference_id}, acc) when tag in [:java_field, :java_ref], do: acc

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

  defp static_prelude_calls(_core_ast, nil), do: []

  defp static_prelude_calls(core_ast, %Prelude{} = prelude) do
    callable_refs =
      prelude.exports
      |> Enum.filter(&(&1.kind == :function))
      |> MapSet.new(& &1.ref)

    core_ast
    |> collect_static_prelude_calls(callable_refs, MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp collect_static_prelude_calls({:prelude_call, ref, args}, callable_refs, acc) do
    Enum.reduce(args, MapSet.put(acc, ref), &collect_static_prelude_calls(&1, callable_refs, &2))
  end

  defp collect_static_prelude_calls({:prelude_ref, ref}, callable_refs, acc) do
    if MapSet.member?(callable_refs, ref), do: MapSet.put(acc, ref), else: acc
  end

  defp collect_static_prelude_calls(tuple, callable_refs, acc) when is_tuple(tuple),
    do:
      Enum.reduce(
        Tuple.to_list(tuple),
        acc,
        &collect_static_prelude_calls(&1, callable_refs, &2)
      )

  defp collect_static_prelude_calls(list, callable_refs, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_static_prelude_calls(&1, callable_refs, &2))

  defp collect_static_prelude_calls(map, callable_refs, acc) when is_map(map),
    do: Enum.reduce(Map.values(map), acc, &collect_static_prelude_calls(&1, callable_refs, &2))

  defp collect_static_prelude_calls(_other, _callable_refs, acc), do: acc

  defp execute_tool(normalized_tools, name, args, origin, failure_token) do
    case Map.fetch(normalized_tools, name) do
      {:ok, %Tool{} = tool} ->
        with :ok <- authorize_tool_call(tool, origin, failure_token),
             :ok <- validate_private_tool_args(tool, args, failure_token) do
          execute_tool_function(tool, args, failure_token)
        end

      :error ->
        available =
          normalized_tools
          |> Enum.reject(fn {_name, tool} -> Tool.private?(tool) end)
          |> Enum.map(fn {tool_name, _tool} -> tool_name end)
          |> Enum.sort()

        tool_failure(failure_token, :unknown_tool, name, available)
    end
  end

  defp execute_tool_function(
         %Tool{name: name, argument_collisions: :reject},
         %AmbiguousArguments{},
         failure_token
       ) do
    tool_failure(failure_token, :invalid_tool_args, name, :ambiguous_arguments)
  end

  defp execute_tool_function(%Tool{name: name, function: fun}, args, failure_token) do
    case HostContext.without_context(fn -> fun.(args) end) do
      %TrustedError{reason: reason, message: message, details: details}
      when is_atom(reason) and is_binary(message) and is_map(details) ->
        tool_failure(failure_token, reason, message, details)

      {:ok, value} ->
        value

      {:error, reason} ->
        recorded_tool_failure(failure_token, name, reason)

      value ->
        value
    end
  end

  defp authorize_tool_call(%Tool{visibility: :public}, _origin, _failure_token), do: :ok

  defp authorize_tool_call(
         %Tool{
           name: name,
           visibility: :private,
           prelude_namespaces: prelude_namespaces
         },
         %{
           type: :prelude_export,
           ref: ref,
           namespace: namespace,
           tool_refs: tool_refs
         },
         failure_token
       )
       when is_list(tool_refs) do
    if name in tool_refs and authorized_prelude_namespace?(prelude_namespaces, namespace) do
      :ok
    else
      tool_failure(failure_token, :private_tool_unauthorized, name, %{
        origin: ref,
        allowed_tools: tool_refs
      })
    end
  end

  defp authorize_tool_call(
         %Tool{name: name, visibility: :private},
         _origin,
         failure_token
       ) do
    tool_failure(failure_token, :private_tool_unauthorized, name, %{origin: nil})
  end

  defp authorized_prelude_namespace?(:any, _namespace), do: true

  defp authorized_prelude_namespace?(namespaces, namespace) when is_list(namespaces),
    do: namespace in namespaces

  defp validate_private_tool_args(%Tool{visibility: :public}, _args, _failure_token), do: :ok
  defp validate_private_tool_args(%Tool{signature: nil}, _args, _failure_token), do: :ok

  defp validate_private_tool_args(
         %Tool{name: name, signature: signature},
         args,
         failure_token
       ) do
    with {:ok, parsed} <- Signature.parse(signature),
         :ok <- Signature.validate_input(parsed, args) do
      :ok
    else
      {:error, errors} when is_list(errors) ->
        tool_failure(
          failure_token,
          :private_tool_args_error,
          name,
          format_signature_errors(errors)
        )

      {:error, error} ->
        tool_failure(failure_token, :private_tool_args_error, name, error)
    end
  end

  defp format_signature_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: path, message: message} -> "#{Enum.join(path, ".")}: #{message}"
      other -> inspect(other)
    end)
  end

  defp tool_failure(token, reason, message, data, record? \\ false),
    do: {:__ptc_tool_failure__, token, reason, message, data, record?}

  defp recorded_tool_failure(token, name, reason) do
    {reason, child_trace_id, child_step} = tool_failure_metadata(reason)

    {:__ptc_tool_failure__, token, :tool_error, name, reason, true, child_trace_id, child_step}
  end

  defp tool_failure_metadata(%{
         __child_trace_id__: child_trace_id,
         __child_step__: child_step,
         value: reason
       }),
       do: {reason, child_trace_id, child_step}

  defp tool_failure_metadata(%{__child_trace_id__: child_trace_id, value: reason}),
    do: {reason, child_trace_id, nil}

  defp tool_failure_metadata(%{__child_step__: child_step, value: reason}),
    do: {reason, nil, child_step}

  defp tool_failure_metadata(reason), do: {reason, nil, nil}

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
    case JavaProject.project(step.return, :public) do
      {:ok, projected_return} ->
        externalized_return = externalize_lisp_values(projected_return)

        case validate_externalized_symbol_refs(externalized_return) do
          :ok ->
            case Signature.validate(parsed_signature, externalized_return) do
              :ok ->
                # Store the original signature string in the step
                {:ok, %{step | signature: signature_str}}

              {:error, errors} ->
                msg = format_validation_errors(errors)

                {:error, Step.error(:validation_error, msg, step.memory, %{})}
            end

          {:error, reason} ->
            {:error, symbol_projection_error_step(step, reason)}
        end

      {:error, reason} ->
        {:error, java_projection_error_step(step, reason)}
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
  # (a `MapSet` of in-scope names, atoms or binaries). Exposed so the prelude
  # compiler can run the SAME static undefined-var check on captured definition
  # bodies.
  @spec undefined_vars(term(), MapSet.t()) :: [String.t()]
  def undefined_vars(core_ast, %MapSet{} = scope) do
    core_ast |> collect_undefined_vars(normalize_scope(scope)) |> Enum.uniq()
  end

  # The scope holds names as binaries, never atoms. `SourceAtoms.intern/1`
  # returns an atom for the bounded vocabulary and a binary for everything
  # else, so one form can carry both representations of ordinary user names —
  # `(defn- parse …)` parses as `:parse` while `(defn- parse-report …)` parses
  # as `"parse-report"`. Comparing raw representations reported a definition
  # whose spelling happens to be interned as undefined (#1166).
  defp normalize_scope(%MapSet{} = scope), do: MapSet.new(scope, &to_string/1)

  defp put_scope(scope, name), do: MapSet.put(scope, to_string(name))

  # Variable reference — check builtins and local scope
  defp collect_undefined_vars({:var, name}, scope) do
    name_str = to_string(name)

    # Skip interop method names (e.g., .toString) — validity checked at runtime
    if String.starts_with?(name_str, ".") or Env.builtin?(name) or
         MapSet.member?(scope, name_str) do
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
    extended_scope = Enum.reduce(param_names, scope, &put_scope(&2, &1))
    collect_undefined_vars(body, extended_scope)
  end

  defp collect_undefined_vars({:fn, name, params, body}, scope) do
    param_names = fn_param_vars(params)

    extended_scope =
      [name | param_names]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(scope, &put_scope(&2, &1))

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

  defp collect_undefined_vars({tag, _reference_id, args}, scope)
       when tag in [:java_static, :java_new],
       do: Enum.flat_map(args, &collect_undefined_vars(&1, scope))

  defp collect_undefined_vars({tag, _reference_id, receiver, args}, scope)
       when tag in [:java_instance, :java_dot] do
    collect_undefined_vars(receiver, scope) ++
      Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({tag, _reference_id}, _scope)
       when tag in [:java_field, :java_ref],
       do: []

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
    collect_undefined_vars(value, put_scope(scope, name))
  end

  defp collect_undefined_vars({:defonce, name, value, _opts}, scope) do
    collect_undefined_vars(value, put_scope(scope, name))
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
        new_sc = Enum.reduce(extract_def_names(expr), sc, &put_scope(&2, &1))
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
  defp collect_undefined_vars(_other, _scope) do
    Logger.debug("collect_undefined_vars: unhandled CoreAST node")
    []
  end

  defp reduce_bindings(bindings, scope) do
    Enum.reduce(bindings, {[], scope}, fn {:binding, pattern, value}, {errs, sc} ->
      value_errs = collect_undefined_vars(value, sc)
      new_scope = Enum.reduce(pattern_vars(pattern), sc, &put_scope(&2, &1))
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

  defp admitted_java_class_names do
    JavaSurface.references()
    |> Enum.map(& &1.class_id)
    |> Enum.uniq()
    |> Enum.flat_map(fn class_id ->
      case JavaSurface.fetch_class(class_id) do
        {:ok, %{name: name}} -> [name]
        :error -> []
      end
    end)
    |> Enum.sort()
  end

  defp java_arity_error_message(reference_id, %{expected: []}) do
    spelling = java_reference_spelling(reference_id)

    "Analysis error: #{spelling} is a Java field, not a callable; " <>
      "reference it as #{spelling} without parentheses"
  end

  defp java_arity_error_message(reference_id, details) do
    arities = details.expected |> List.wrap() |> Enum.join(", ")

    "Analysis error: #{java_reference_spelling(reference_id)} accepts arity #{arities}, " <>
      "got #{details.actual}"
  end

  defp java_reference_spelling(reference_id) do
    with :error <- java_reference_spelling_from_reference(reference_id),
         :error <- JavaSurface.member_family_source(reference_id) do
      "Java reference #{reference_id}"
    else
      {:ok, spelling} -> spelling
    end
  end

  defp java_reference_spelling_from_reference(reference_id) do
    case JavaSurface.fetch_reference(reference_id) do
      {:ok, %{spellings: [spelling | _]}} -> {:ok, spelling}
      _unspelled -> :error
    end
  end

  defp unsupported_java_member_message(namespace, member) do
    members = JavaSurface.namespace_members(namespace)
    member_labels = Enum.map(members, &"#{namespace}/#{&1}")

    suffix =
      if member_labels == [],
        do: "",
        else: " Interop functions: #{Enum.join(member_labels, ", ")}"

    "Analysis error: #{namespace}/#{member} is not available.#{suffix}"
  end
end
