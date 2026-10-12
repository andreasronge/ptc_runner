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
    DataKeys,
    Env,
    Eval,
    Format,
    Sandbox
  }

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Effects
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
  alias PtcRunner.Lisp.Result, as: Step
  alias PtcRunner.Lisp.Signature
  alias PtcRunner.Lisp.Tool

  @doc false
  defdelegate undefined_vars(core_ast, scope), to: PtcRunner.Lisp.Compile

  import PtcRunner.Lisp.Compile, only: [compile_program: 2]
  import PtcRunner.Lisp.ToolExecution, only: [execute_tool: 5, normalize_tools: 1]

  import PtcRunner.Lisp.Memory,
    only: [validate_return_value: 3, public_result: 1, apply_memory_contract: 4]

  import PtcRunner.Lisp.ErrorFormat,
    only: [error_details: 1, error_details: 2, memory_exceeded_message: 1]

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
  defdelegate project_boundary_value(value, boundary), to: PtcRunner.Lisp.Memory

  @doc false
  @spec project_native_result({:ok | :error, Step.t()}) ::
          {:ok | :error, Step.t()}
  defdelegate project_native_result(result), to: PtcRunner.Lisp.Memory

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
  defdelegate externalize_memory(memory), to: PtcRunner.Lisp.Memory

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
    - `:signature` - Optional signature string for return value validation.
      Validation collects at most 16 errors and caps diagnostics at 1,024 bytes.
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
      `PtcRunner.Lisp.Sandbox` for the re-baseline semantics.
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
    - `:host_error_policy` - Optional module implementing
      `PtcRunner.Lisp.HostErrorPolicy`. Host diagnostics crossing private prelude
      boundaries fail closed without it. Parallel program `fail` values retain
      only a bounded scalar kind by default; a policy projects host catalog
      metadata. The invocation's policy is inherited by workers and is never
      captured in closure metadata.
    - `:component_catalog` - Optional host catalog implementing
      `PtcRunner.Lisp.ComponentCatalog` for the selected environment. Public `run/2` strips this option so a direct
      caller cannot inject a Kernel graph. Kernel evaluations pass it only
      through `run_native/2` for the selected workflow or mission catalog. The
      catalog is not projected into result stamps, traces, telemetry, or host
      logs.
    - `:inspect_only` - When true, tool, Kernel, provider, and capability
      routes fail closed with `inspect_only_unavailable`. Public `run/2`
      strips this option. Kernel and inspect-only REPL evaluations pass it
      only through `run_native/2`.
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
    |> instrumented_run(public_run_opts(opts), :public)
    |> public_result()
  end

  @doc false
  @spec public_run_opts(keyword()) :: keyword()
  def public_run_opts(opts) when is_list(opts) do
    opts
    |> Keyword.delete(:component_catalog)
    |> Keyword.delete(:inspect_only)
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
    case attach_prelude(prelude_opt, tools, memory, params.inspect_only) do
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
    max_heap = Keyword.get(opts, :max_heap, Sandbox.default_max_heap())

    %{
      ctx: Keyword.get(opts, :context, %{}),
      memory: Keyword.get(opts, :memory, %{}),
      raw_tools: Keyword.get(opts, :tools, %{}),
      signature_str: Keyword.get(opts, :signature),
      float_precision: Keyword.get(opts, :float_precision),
      preserve_runtime_callables: Keyword.get(opts, :preserve_runtime_callables, false),
      timeout: Keyword.get(opts, :timeout, Sandbox.default_timeout()),
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
      component_catalog: Keyword.get(opts, :component_catalog),
      host_error_policy: Keyword.get(opts, :host_error_policy),
      inspect_only: Keyword.get(opts, :inspect_only, false),
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
  defp attach_prelude(nil, _tools, _memory, _inspect_only), do: {:ok, nil}

  defp attach_prelude(prelude_opt, tools, memory, inspect_only) do
    context =
      PreludeAttachContext.new(
        tools: tools,
        validate_requires?: inspect_only != true
      )

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
      with {:ok, prelude} <-
             attach_prelude(
               Keyword.get(opts, :prelude),
               tools,
               memory,
               Keyword.get(opts, :inspect_only, false)
             ),
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
    # Inspect-only sessions install no tools. The compile-time unknown-tool
    # check would otherwise hide the closed `inspect_only_unavailable`
    # diagnostic that eval emits for Kernel, provider, and capability routes.
    check_tool_resolution? = Map.get(opts, :inspect_only, false) != true

    case compile_program(source, Map.put(opts, :check_tool_resolution, check_tool_resolution?)) do
      {:ok, core_ast, prelude_calls} ->
        core_ast
        |> execute_eval(apply_run_deadline(opts))
        |> put_prelude_calls(prelude_calls)

      {:error, %Step{}} = compile_error ->
        prepare_pre_setup_error(compile_error, opts)
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

    case Sandbox.execute(:prepare_error_memory, step.memory, sandbox_opts) do
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
      component_catalog: component_catalog,
      inspect_only: inspect_only,
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
        component_catalog: component_catalog,
        host_error_policy: Map.get(opts, :host_error_policy),
        inspect_only: inspect_only,
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
    |> Sandbox.execute(context, sandbox_opts)
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
        details: error_details(reason, eval_ctx.host_error_policy)
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
  defdelegate format_error(reason), to: PtcRunner.Lisp.ErrorFormat

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

  # Check if symbol count exceeds limit

  # Parse signature if provided
  defp parse_signature(nil), do: {:ok, nil}

  defp parse_signature(signature_str) when is_binary(signature_str) do
    case Signature.parse(signature_str) do
      {:ok, sig} -> {:ok, sig}
      {:error, msg} -> {:error, {:invalid_signature, msg}}
    end
  end

  # ============================================================
  # validate/1 helpers — walk CoreAST collecting undefined vars
  # ============================================================
end
