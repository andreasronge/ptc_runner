defmodule PtcRunner.Lisp.Eval.Context do
  @moduledoc """
  Evaluation context for the Lisp interpreter.

  Bundles the parameters that flow through recursive evaluation:
  - `ctx`: External data (read-only)
  - `user_ns`: User namespace (mutable bindings from `def`)
  - `env`: Lexical environment (variable bindings)
  - `tool_exec`: Tool executor function
  - `turn_history`: Previous turn results for multi-turn loops

  ## Limits

  | Field | Default | Hard Cap | Purpose |
  |-------|---------|----------|---------|
  | `loop_limit` | 1,000 | 10,000 | Max loop/recur jumps |
  | `max_print_length` | 2,000 | — | Max chars per `println` call |
  | `max_tool_call_result_bytes` | 16,384 | — | Per-entry cap on the `:result` retained in the in-eval tool ledger |
  | `pmap_max_concurrency` | build-time `schedulers * 2` | — | Max concurrent pmap/pcalls tasks |
  | `parallel_deadline_cap` | `nil` | — | Absolute ceiling clamping every pmap/pcalls deadline |

  ## Tool-ledger retention

  `effects.tool_calls` records every call's `:result` and `:args` for post-eval
  telemetry/envelope rendering. To stop a long-running or looping tool use
  (e.g. a paginated read fold) from accumulating full payloads in live eval
  state, `append_tool_call/2` bounds each entry's `:result` to a preview once
  it exceeds `max_tool_call_result_bytes`, marking the entry with
  `:result_truncated`. Only the LEDGER copy is bounded — the value returned to
  the program and any evaluation-local `effects.tool_cache` entry keep the full
  result (they are built separately in `record_tool_call`). `:args` is left
  intact by default because later effect consumers may need the raw map for
  capability identity and canonical argument hashing. A trusted tool may
  instead install an explicit ledger-only argument projection for sensitive
  boundaries. `:child_trace_id`/`:child_step` remain intact.
  """

  alias PtcRunner.Lisp.Eval.Capture
  alias PtcRunner.Lisp.Eval.Effects
  alias PtcRunner.Lisp.Eval.RunResources
  alias PtcRunner.Lisp.RetainedSize

  @default_print_length 2000
  @default_tool_call_result_bytes 16_384

  @default_pmap_timeout 5_000
  @default_pmap_max_concurrency System.schedulers_online() * 2

  defstruct [
    :ctx,
    :user_ns,
    :env,
    :tool_exec,
    :tool_failure_token,
    :failure_origin,
    :return_origin,
    :origin_stack,
    :prelude_caller_user_ns_stack,
    :turn_history,
    iteration_count: 0,
    loop_limit: 1000,
    max_print_length: @default_print_length,
    max_tool_calls: nil,
    # Shared atomic reservation counter for uncached tool invocations. Every
    # closure and parallel worker in one run inherits the same reference, so
    # `max_tool_calls` is a program-wide bound rather than a per-context bound.
    tool_call_budget: nil,
    max_tool_call_result_bytes: @default_tool_call_result_bytes,
    pmap_timeout: @default_pmap_timeout,
    pmap_max_concurrency: @default_pmap_max_concurrency,
    # Absolute monotonic-time deadline (ms) shared by an in-progress
    # pmap/pcalls operation and all of its nested parallel calls. `nil`
    # outside any parallel operation; the outermost pmap/pcalls sets it
    # to `now + pmap_timeout` and nested calls inherit it unchanged, so
    # N parallel branches cannot multiply total wall time.
    pmap_deadline: nil,
    # Absolute monotonic-time ceiling (ms) for ANY parallel deadline,
    # regardless of when the operation starts. A relative `pmap_timeout`
    # alone would let an operation started late in a run construct a
    # deadline past the run's own deadline; the outermost pmap/pcalls
    # clamps to this cap instead. `nil` when the embedding run has no
    # absolute deadline.
    parallel_deadline_cap: nil,
    # Per-process heap cap (in words) applied to the sandbox process.
    # `nil` means no sandbox cap is configured.
    max_heap: nil,
    # FIXED `max_heap_size` (in words) applied to every pmap/pcalls
    # worker — top-level and nested alike — at spawn time. NOT divided
    # by concurrency: division is unsound for nested parallelism (a
    # parent worker is alive while its nested children run). Defaults to
    # the sandbox `max_heap`; overridable. `nil` means no per-worker cap.
    worker_max_heap: nil,
    # Shared `PtcRunner.Lisp.Eval.ParallelBudget` slot semaphore — the
    # HARD global cap on how many pmap/pcalls workers may be alive at
    # once across the whole `Lisp.run`. ONE object per top-level run;
    # nested pmap/pcalls inherit and reuse the SAME object. `nil` when
    # no global cap is configured (uncounted parallel execution).
    parallel_budget: nil,
    # Shared monotonic marker for uncached tool execution. Atomics remain
    # shared across pmap/pcalls workers even though their context ledgers are
    # copied, so contract retry classification cannot lose sibling activity.
    tool_activity: nil,
    effects: %Effects{},
    tools_meta: %{},
    locals: MapSet.new(),
    # When true, accessing `data/<key>` for a key that was not provided
    # in the context raises a runtime error naming the binding instead of
    # returning `nil`. It is off by default for permissive embedded execution.
    strict_data: false,
    # Sorted `data/<name>` forms supplied by the Kernel mission boundary for
    # missing-grant diagnostics. `nil` means the caller did not pass a list;
    # Eval must not derive one from `ctx`.
    data_grants: nil,
    # Kernel-supplied diagnostic used when `data/params` is missing under
    # strict data. `nil` treats `params` as an ordinary missing key.
    missing_data_params_message: nil,
    # When true, session-authored code may only name prelude namespaces that
    # were directly attached. Prelude-internal calls remain allowed because the
    # compiler already validated their declared namespace deps.
    strict_transitive_calls: false,
    # Whether any tool in this run is private. Raw/no-prelude runs use this
    # once-computed flag to avoid authority bookkeeping on every closure.
    private_tool_authority?: false,
    direct_namespaces: MapSet.new(),
    transitive_namespace_requirers: %{},
    prelude_export_mask: nil,
    # The attached compiled prelude's PUBLIC
    # export table, a map from string ref (e.g. "crm/get-user") to a
    # `{callable, ns_env, export}` tuple — the callable captured from `private_env` plus
    # its OWN namespace's private env. Qualified prelude calls
    # (`{:prelude_call, ref, args}`) resolve here — inserted in resolver order
    # AFTER the mutable `user` namespace and BEFORE builtins. The paired
    # `ns_env` is threaded as the export body's `user_ns` layer so its private
    # sibling helpers resolve within its OWN namespace, while user code (whose
    # `user_ns` is the ordinary mutable namespace) cannot reach private helpers
    # by qualified symbol. `%{}` when no prelude is attached.
    prelude_exports: %{},
    # The attached compiled prelude artifact (`%PtcRunner.Lisp.Prelude{}`) or `nil`.
    prelude: nil
  ]

  @typedoc """
  Tool call record for tracing.

  Fields:
  - `name`: Tool name
  - `args`: Arguments passed to tool
  - `result`: Tool result
  - `error`: Error message if tool failed
  - `timestamp`: When tool was called
  - `duration_ms`: How long tool took
  - `child_trace_id`: Trace ID of a nested tool execution, when supplied
  """
  @type tool_call :: %{
          required(:name) => String.t(),
          required(:args) => map(),
          required(:result) => term(),
          required(:error) => String.t() | nil,
          required(:timestamp) => DateTime.t(),
          required(:duration_ms) => non_neg_integer(),
          optional(:child_trace_id) => String.t(),
          optional(:child_step) => term(),
          optional(:cached) => boolean()
        }

  @typedoc """
  Parallel map/calls execution record for tracing.

  Fields:
  - `type`: `:pmap` or `:pcalls`
  - `count`: Number of parallel tasks
  - `child_trace_ids`: Trace IDs supplied by nested tool executions
  - `timestamp`: When execution started
  - `duration_ms`: Total execution time
  - `success_count`: Number of successful executions
  - `error_count`: Number of failed executions
  """
  @type pmap_call :: %{
          type: :pmap | :pcalls,
          count: non_neg_integer(),
          child_trace_ids: [String.t()],
          child_steps: [any()],
          timestamp: DateTime.t(),
          duration_ms: non_neg_integer(),
          success_count: non_neg_integer(),
          error_count: non_neg_integer()
        }

  @type t :: %__MODULE__{
          ctx: map(),
          user_ns: map(),
          env: map(),
          tool_exec: (String.t(), map(), map() | nil -> term()),
          tool_failure_token: reference() | nil,
          failure_origin: :capability | nil,
          return_origin: :direct_tool_call | nil,
          origin_stack: [map()],
          prelude_caller_user_ns_stack: [map()],
          turn_history: list(),
          iteration_count: integer(),
          loop_limit: integer(),
          max_tool_calls: pos_integer() | nil,
          tool_call_budget: :atomics.atomics_ref(),
          max_tool_call_result_bytes: pos_integer(),
          max_print_length: pos_integer(),
          pmap_timeout: pos_integer(),
          pmap_max_concurrency: pos_integer(),
          pmap_deadline: integer() | nil,
          parallel_deadline_cap: integer() | nil,
          max_heap: pos_integer() | nil,
          worker_max_heap: pos_integer() | nil,
          parallel_budget: PtcRunner.Lisp.Eval.ParallelBudget.t() | nil,
          tool_activity: :atomics.atomics_ref(),
          effects: Effects.t(),
          tools_meta: %{String.t() => %{optional(atom()) => term()}},
          strict_data: boolean(),
          data_grants: [String.t()] | nil,
          missing_data_params_message: String.t() | nil,
          strict_transitive_calls: boolean(),
          private_tool_authority?: boolean(),
          direct_namespaces: MapSet.t(String.t()),
          transitive_namespace_requirers: %{String.t() => [String.t()]},
          prelude_export_mask: %{String.t() => MapSet.t(String.t())} | nil,
          prelude_exports: %{String.t() => {term(), map()}},
          prelude: PtcRunner.Lisp.Prelude.t() | nil
        }

  @type recur_effects :: Effects.t()

  @type parallel_effects :: recur_effects()

  @doc """
  Creates a new evaluation context.

  ## Options

  - `:max_print_length` - Max characters per `println` call (default: #{@default_print_length})
  - `:pmap_timeout` - Shared absolute deadline in ms for each pmap/pcalls
    operation, including nested parallel calls (default: 5000). Increase for
    LLM-backed tools.
  - `:parallel_deadline_cap` - Absolute monotonic-time ceiling in ms that
    clamps every parallel deadline regardless of when the operation starts
    (default: nil = no ceiling). Kernel runs pass their run deadline here.
  - `:pmap_max_concurrency` - Max concurrent tasks in pmap/pcalls (default: the build-time `System.schedulers_online() * 2`, frozen into the semantic revision)
  - `:max_heap` - Sandbox per-process heap cap in words (default: nil).
  - `:worker_max_heap` - FIXED `max_heap_size` (in words) for every
    pmap/pcalls worker, top-level and nested (default: the `:max_heap`
    value). Not divided by concurrency. See `PtcRunner.Lisp.Eval.ParallelRunner`.
  - `:parallel_budget` - shared `PtcRunner.Lisp.Eval.ParallelBudget`
    semaphore bounding the number of parallel workers alive at once
    across the whole run (default: nil = uncounted).

  ## Examples

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [])
      iex> ctx.user_ns
      %{}

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [], max_print_length: 500)
      iex> ctx.max_print_length
      500

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [], pmap_timeout: 60_000)
      iex> ctx.pmap_timeout
      60000

  """
  @spec new(map(), map(), map(), (String.t(), map(), map() | nil -> term()), list(), keyword()) ::
          t()
  def new(ctx, user_ns, env, tool_exec, turn_history, opts \\ []) do
    %__MODULE__{
      ctx: ctx,
      user_ns: user_ns,
      env: env,
      tool_exec: tool_exec,
      tool_failure_token: Keyword.get(opts, :tool_failure_token),
      failure_origin: Keyword.get(opts, :failure_origin),
      return_origin: Keyword.get(opts, :return_origin),
      origin_stack: Keyword.get(opts, :origin_stack, []),
      prelude_caller_user_ns_stack: Keyword.get(opts, :prelude_caller_user_ns_stack, []),
      turn_history: turn_history,
      max_tool_calls: Keyword.get(opts, :max_tool_calls),
      tool_call_budget: Keyword.get_lazy(opts, :tool_call_budget, &RunResources.new_counter/0),
      max_tool_call_result_bytes:
        Keyword.get(opts, :max_tool_call_result_bytes, @default_tool_call_result_bytes),
      max_print_length: Keyword.get(opts, :max_print_length, @default_print_length),
      pmap_timeout: Keyword.get(opts, :pmap_timeout, @default_pmap_timeout),
      parallel_deadline_cap: Keyword.get(opts, :parallel_deadline_cap),
      pmap_max_concurrency:
        Keyword.get(opts, :pmap_max_concurrency, @default_pmap_max_concurrency),
      max_heap: Keyword.get(opts, :max_heap),
      worker_max_heap: Keyword.get(opts, :worker_max_heap, Keyword.get(opts, :max_heap)),
      parallel_budget: Keyword.get(opts, :parallel_budget),
      tool_activity: Keyword.get_lazy(opts, :tool_activity, &RunResources.new_counter/0),
      effects: Effects.empty(),
      tools_meta: Keyword.get(opts, :tools_meta, %{}),
      strict_data: Keyword.get(opts, :strict_data, false),
      data_grants: normalize_data_grants(Keyword.get(opts, :data_grants)),
      missing_data_params_message:
        normalize_missing_params_message(Keyword.get(opts, :missing_data_params_message)),
      strict_transitive_calls: Keyword.get(opts, :strict_transitive_calls, false),
      private_tool_authority?: Keyword.get(opts, :private_tool_authority?, false),
      direct_namespaces: namespace_set(Keyword.get(opts, :direct_namespaces, [])),
      transitive_namespace_requirers:
        normalize_namespace_requirers(Keyword.get(opts, :transitive_namespace_requirers, %{})),
      prelude_export_mask: normalize_export_mask(Keyword.get(opts, :prelude_export_mask)),
      prelude_exports: prelude_exports(Keyword.get(opts, :prelude)),
      prelude: prelude_artifact(Keyword.get(opts, :prelude))
    }
  end

  @doc false
  @spec new_child(t(), map(), map(), keyword()) :: t()
  def new_child(%__MODULE__{} = parent, user_ns, env, opts \\ []) do
    opts =
      [
        tool_call_budget: parent.tool_call_budget,
        tool_activity: parent.tool_activity
      ] ++ opts

    parent.ctx
    |> new(user_ns, env, parent.tool_exec, parent.turn_history, opts)
    |> inherit_prelude(parent)
  end

  @doc false
  @spec default_pmap_max_concurrency() :: pos_integer()
  def default_pmap_max_concurrency, do: @default_pmap_max_concurrency

  # Build the public export table (ref => {callable, ns_env}) from the attached
  # prelude. Each export's callable lives in the captured `private_env` under
  # its namespace then its bare symbol; we pair the callable with its OWN
  # namespace's env so a qualified prelude call resolves the right closure AND
  # runs its body against the right private siblings, while private helpers
  # (absent from `exports`) stay unreachable by qualified symbol.
  defp prelude_exports(nil), do: %{}

  defp prelude_exports(%PtcRunner.Lisp.Prelude{exports: exports, private_env: env}) do
    Map.new(exports, fn export ->
      ns_env = Map.get(env, export.namespace, %{})
      {export.ref, {Map.get(ns_env, export.symbol), ns_env, export}}
    end)
  end

  defp prelude_artifact(nil), do: nil
  defp prelude_artifact(%PtcRunner.Lisp.Prelude{} = prelude), do: prelude

  defp namespace_set(namespaces) when is_list(namespaces) do
    namespaces
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp namespace_set(%MapSet{} = namespaces), do: namespaces
  defp namespace_set(_namespaces), do: MapSet.new()

  defp normalize_data_grants(names) when is_list(names), do: Enum.filter(names, &is_binary/1)
  defp normalize_data_grants(_names), do: nil

  defp normalize_missing_params_message(message) when is_binary(message) and message != "",
    do: message

  defp normalize_missing_params_message(_message), do: nil

  defp normalize_namespace_requirers(requirers) when is_map(requirers) do
    Map.new(requirers, fn
      {namespace, ids} when is_binary(namespace) and is_list(ids) ->
        {namespace, ids |> Enum.filter(&is_binary/1) |> Enum.sort()}

      {namespace, id} when is_binary(namespace) and is_binary(id) ->
        {namespace, [id]}

      {namespace, _ids} when is_binary(namespace) ->
        {namespace, []}

      {_namespace, _ids} ->
        {"", []}
    end)
    |> Map.delete("")
  end

  defp normalize_namespace_requirers(_requirers), do: %{}

  defp normalize_export_mask(nil), do: nil

  defp normalize_export_mask(mask) when is_map(mask) do
    normalized =
      mask
      |> Enum.flat_map(fn
        {namespace, refs} when is_binary(namespace) ->
          [{namespace, normalize_ref_set(refs)}]

        {_namespace, _refs} ->
          []
      end)
      |> Map.new()

    if map_size(normalized) == 0, do: nil, else: normalized
  end

  defp normalize_export_mask(_mask), do: nil

  defp normalize_ref_set(%MapSet{} = refs) do
    refs
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp normalize_ref_set(refs) when is_list(refs) do
    refs
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp normalize_ref_set(_refs), do: MapSet.new()

  @doc """
  Appends a print message to the context.

  Long messages are truncated to `max_print_length` characters (default: #{@default_print_length}).
  """
  @spec append_print(t(), String.t()) :: t()
  def append_print(%__MODULE__{max_print_length: max_len} = context, message) do
    truncated = truncate_print(message, max_len)

    :ok = Capture.record_print(truncated)
    %{context | effects: Effects.record_print(context.effects, truncated)}
  end

  @doc false
  @spec truncate_print(String.t(), non_neg_integer()) :: String.t()
  def truncate_print(message, max_len) when is_binary(message) and is_integer(max_len) do
    total = String.length(message)

    if total > max_len do
      String.slice(message, 0, max_len) <> "... (#{max_len}/#{total} chars)"
    else
      message
    end
  end

  @doc """
  Appends a tool call record to the context.

  The entry's `:result` and `:args` are bounded to a preview when they exceed
  `max_tool_call_result_bytes`, so a looping/large tool use cannot accumulate
  full payloads in live eval state. See the "Tool-ledger retention" moduledoc
  section. Only the ledger copy is bounded; callers keep the full result for
  the program return and cache separately.
  """
  @spec append_tool_call(t(), tool_call()) :: t()
  def append_tool_call(
        %__MODULE__{max_tool_call_result_bytes: cap} = context,
        tool_call
      ) do
    ledger_entry = compact_ledger_entry(tool_call, cap)
    :ok = Capture.record_tool_call(ledger_entry)
    %{context | effects: Effects.record_tool_call(context.effects, ledger_entry)}
  end

  # Bound the LEDGER copy of :result only. Preserves every other field,
  # including a nil :result (failed call), :child_trace_id / :child_step
  # (trace-hierarchy metadata), and the already-selected :args ledger value.
  # Ordinary tools retain raw arguments; trusted tools may have projected them
  # before this retention boundary.
  # Small results pass through identically so existing entries are byte-for-
  # byte unchanged.
  defp compact_ledger_entry(%{result: result} = tool_call, cap)
       when is_integer(cap) and cap > 0 and not is_nil(result) do
    case retained_size(result, cap) do
      size when is_integer(size) and size <= cap ->
        Map.update!(tool_call, :result, &RetainedSize.detach_binaries/1)

      size ->
        tool_call
        |> Map.put(:result, preview(result, cap))
        |> Map.put(:result_truncated, true)
        |> Map.put(:result_bytes, size)
    end
  end

  defp compact_ledger_entry(tool_call, _cap), do: tool_call

  # Logical retained-heap estimate. Two parts:
  #
  #   * the term's flat heap size (`:erts_debug.flat_size/1`, words → bytes):
  #     cons cells, tuples, boxed terms. NOT the serialized encoding —
  #     `:erlang.external_size/1` is ~16× smaller for int-heavy lists (a 16k-int
  #     list encodes to ~16 KB but occupies ~256 KB of heap), which would let it
  #     slip under the cap; and
  #   * the own extent of every binary reachable in the term. flat_size counts
  #     only a binary's small header, not its bytes. Ledger values that fit are
  #     detached before retention so a small slice cannot keep a larger
  #     transient parent alive.
  #
  # The two parts are SUMMED, not maxed: a mixed `{rows, raw_chunk}` result
  # retains both. Short-circuit: only walk binaries when the flat heap is already
  # under the cap — if it alone exceeds the cap we truncate regardless.
  defp retained_size(value, cap) do
    RetainedSize.bytes_with_cap(value, cap)
  end

  defp preview(value, cap) do
    # Bump only the inspect budget so a tiny cap still yields a usable render;
    # the retained preview is truncated to the exact `cap` byte budget. `limit`
    # is kept low: only ~cap bytes survive, so rendering many elements just
    # enlarges the transient inspect string.
    value
    |> inspect(limit: 10, printable_limit: max(cap, 32))
    |> truncate_bytes(cap)
  end

  # Bound by BYTES (the cap is a byte budget), UTF-8 safely: take at most
  # `max_bytes` bytes, then drop any incomplete trailing codepoint. The final
  # slice is COPIED — `binary_part/3` returns a sub-binary that would otherwise
  # pin the whole (possibly large) inspect output, defeating the very bound
  # this function enforces.
  defp truncate_bytes(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp truncate_bytes(binary, max_bytes) do
    binary
    |> binary_part(0, max_bytes)
    |> drop_incomplete_trailing()
    |> :binary.copy()
  end

  defp drop_incomplete_trailing(binary) do
    if String.valid?(binary) or binary == "" do
      binary
    else
      drop_incomplete_trailing(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  @doc """
  Appends a pmap/pcalls execution record to the context.
  """
  @spec append_pmap_call(t(), pmap_call()) :: t()
  def append_pmap_call(%__MODULE__{} = context, pmap_call) do
    :ok = Capture.record_pmap_call(pmap_call)
    %{context | effects: Effects.record_pmap_call(context.effects, pmap_call)}
  end

  @doc false
  @spec increment_prelude_call(t(), String.t()) :: t()
  def increment_prelude_call(%__MODULE__{} = context, ref) when is_binary(ref) do
    :ok = Capture.record_prelude_call(ref)
    %{context | effects: Effects.record_prelude_call(context.effects, ref)}
  end

  @doc false
  @spec put_tool_cache(t(), term(), term()) :: t()
  def put_tool_cache(%__MODULE__{} = context, key, value) do
    :ok = Capture.record_cache(key, value)
    %{context | effects: Effects.record_cache(context.effects, key, value)}
  end

  @doc """
  Extracts accumulated side effects that must survive a `recur` jump.
  """
  @spec recur_effects(t()) :: recur_effects()
  def recur_effects(%__MODULE__{} = context), do: context.effects

  @doc """
  Restores side effects carried by a `recur` signal onto the next iteration context.
  """
  @spec restore_recur_effects(t(), recur_effects()) :: t()
  def restore_recur_effects(%__MODULE__{} = context, %Effects{} = effects),
    do: %{context | effects: effects}

  @doc false
  @spec parallel_effects(t(), t()) :: parallel_effects()
  def parallel_effects(%__MODULE__{} = context, %__MODULE__{} = baseline),
    do: Effects.delta(context.effects, baseline.effects)

  @doc false
  @spec merge_parallel_effects(t(), parallel_effects()) :: t()
  def merge_parallel_effects(%__MODULE__{} = context, %Effects{} = effects) do
    :ok = Capture.record_effects(effects)
    %{context | effects: Effects.merge(effects, context.effects)}
  end

  @doc """
  Updates the user namespace in the context.
  """
  @spec update_user_ns(t(), map()) :: t()
  def update_user_ns(%__MODULE__{} = context, new_user_ns) do
    %{context | user_ns: new_user_ns}
  end

  @doc """
  Copies the attached prelude tables and shared run-scoped resources from
  `source` onto `context`.

  Sub-contexts built with `new/6` for closure/thunk evaluation start with empty
  prelude tables; this re-installs them so a qualified prelude call made from
  inside a user closure still resolves.
  """
  @spec inherit_prelude(t(), t()) :: t()
  def inherit_prelude(%__MODULE__{} = context, %__MODULE__{} = source) do
    %{
      context
      | prelude_exports: source.prelude_exports,
        prelude: source.prelude,
        strict_transitive_calls: source.strict_transitive_calls,
        private_tool_authority?: source.private_tool_authority?,
        direct_namespaces: source.direct_namespaces,
        transitive_namespace_requirers: source.transitive_namespace_requirers,
        prelude_export_mask: source.prelude_export_mask,
        max_tool_calls: source.max_tool_calls,
        tool_call_budget: source.tool_call_budget,
        tool_activity: source.tool_activity,
        tool_failure_token: source.tool_failure_token,
        failure_origin: source.failure_origin,
        return_origin: source.return_origin,
        origin_stack: source.origin_stack,
        prelude_caller_user_ns_stack: source.prelude_caller_user_ns_stack,
        strict_data: source.strict_data,
        data_grants: source.data_grants,
        missing_data_params_message: source.missing_data_params_message
    }
  end

  @doc false
  @spec record_tool_activity(t()) :: :ok
  def record_tool_activity(%__MODULE__{tool_activity: activity}) do
    _ = :atomics.add_get(activity, 1, 1)
    :ok
  end

  @doc false
  @spec tool_activity?(t()) :: boolean()
  def tool_activity?(%__MODULE__{tool_activity: activity}), do: :atomics.get(activity, 1) > 0

  @doc "Returns true when a namespace was directly selected by the session."
  @spec direct_namespace?(t(), String.t()) :: boolean()
  def direct_namespace?(%__MODULE__{direct_namespaces: namespaces}, namespace)
      when is_binary(namespace) do
    MapSet.member?(namespaces, namespace)
  end

  @doc "Returns the direct prelude ids that pulled a transitive namespace in."
  @spec transitive_namespace_requirers(t(), String.t()) :: [String.t()]
  def transitive_namespace_requirers(
        %__MODULE__{transitive_namespace_requirers: requirers},
        namespace
      )
      when is_binary(namespace) do
    Map.get(requirers, namespace, [])
  end

  @doc """
  Whether a prelude ref may be resolved from the current origin.

  Under `strict_transitive_calls` a session-authored program may name a
  namespace it selected directly, or one no direct selection pulled in, but not
  one reached only transitively through another prelude's requirements. Calls
  made from inside a prelude export are never restricted.

  Both the evaluator's resolution guard and `PtcRunner.Lisp.Introspection`'s
  visibility filter read this, so what a program can discover and what it can
  call cannot drift apart.
  """
  @spec prelude_ref_visible?(t(), String.t()) :: boolean()
  def prelude_ref_visible?(%__MODULE__{strict_transitive_calls: false}, ref)
      when is_binary(ref),
      do: true

  def prelude_ref_visible?(%__MODULE__{} = context, ref) when is_binary(ref) do
    namespace = ref_namespace(ref)

    cond do
      namespace == nil -> true
      not session_authored_origin?(current_origin(context)) -> true
      direct_namespace?(context, namespace) -> true
      true -> transitive_namespace_requirers(context, namespace) == []
    end
  end

  @doc "Returns the namespace part of a qualified prelude ref, or `nil`."
  @spec ref_namespace(String.t()) :: String.t() | nil
  def ref_namespace(ref) when is_binary(ref) do
    case String.split(ref, "/", parts: 2) do
      [namespace, _symbol] when namespace != "" -> namespace
      _ -> nil
    end
  end

  @doc "Whether an origin is session-authored rather than a prelude export."
  @spec session_authored_origin?(map() | nil) :: boolean()
  def session_authored_origin?(nil), do: true
  def session_authored_origin?(%{type: :user_closure}), do: true
  def session_authored_origin?(_origin), do: false

  @doc "Pushes a prelude-export origin for private tool authorization."
  @spec push_prelude_origin(t(), map()) :: t()
  def push_prelude_origin(%__MODULE__{origin_stack: stack} = context, %{ref: ref} = export)
      when is_binary(ref) do
    origin = %{
      type: :prelude_export,
      ref: ref,
      namespace: Map.get(export, :namespace),
      tool_refs: Map.get(export, :tool_refs, [])
    }

    %{context | origin_stack: [origin | stack]}
  end

  @doc "Pushes a user-code origin that masks inherited prelude-export authority."
  @spec push_user_origin(t()) :: t()
  def push_user_origin(%__MODULE__{origin_stack: stack} = context) do
    %{context | origin_stack: [%{type: :user_closure} | stack]}
  end

  @doc "Pushes a prelude returned-closure origin without granting private tool authority."
  @spec push_prelude_returned_origin(t(), String.t()) :: t()
  def push_prelude_returned_origin(%__MODULE__{origin_stack: stack} = context, namespace)
      when is_binary(namespace) do
    %{context | origin_stack: [%{type: :prelude_returned_closure, namespace: namespace} | stack]}
  end

  @doc "Saves the user namespace active before entering a prelude export."
  @spec push_prelude_caller_user_ns(t(), map()) :: t()
  def push_prelude_caller_user_ns(
        %__MODULE__{prelude_caller_user_ns_stack: stack} = context,
        user_ns
      )
      when is_map(user_ns) do
    %{context | prelude_caller_user_ns_stack: [user_ns | stack]}
  end

  @doc "Returns the user namespace active before the current prelude export, if any."
  @spec current_prelude_caller_user_ns(t()) :: map() | nil
  def current_prelude_caller_user_ns(%__MODULE__{prelude_caller_user_ns_stack: [ns | _]}),
    do: ns

  def current_prelude_caller_user_ns(%__MODULE__{}), do: nil

  @doc "Returns the current evaluator origin, if any."
  @spec current_origin(t()) :: map() | nil
  def current_origin(%__MODULE__{origin_stack: [origin | _]}), do: origin
  def current_origin(%__MODULE__{}), do: nil

  @doc false
  @spec mark_capability_failure(t()) :: t()
  def mark_capability_failure(%__MODULE__{} = context),
    do: %{context | failure_origin: :capability}

  @doc false
  @spec mark_direct_tool_return(t()) :: t()
  def mark_direct_tool_return(%__MODULE__{} = context),
    do: %{context | return_origin: :direct_tool_call}

  @doc """
  Increments the iteration count and checks against the limit.
  """
  @spec increment_iteration(t()) :: {:ok, t()} | {:error, :loop_limit_exceeded}
  def increment_iteration(%__MODULE__{iteration_count: count, loop_limit: limit} = context) do
    if count >= limit do
      {:error, :loop_limit_exceeded}
    else
      {:ok, %{context | iteration_count: count + 1}}
    end
  end

  @doc """
  Atomically reserves one uncached tool invocation against the program-wide
  tool-call limit.

  Returns `:ok` when unlimited (`nil`) or when the reservation succeeds,
  `{:error, :tool_call_limit_exceeded}` when the shared limit is exhausted.
  """
  @spec reserve_tool_call(t()) :: :ok | {:error, :tool_call_limit_exceeded}
  def reserve_tool_call(%{max_tool_calls: nil}), do: :ok

  def reserve_tool_call(%{max_tool_calls: limit, tool_call_budget: budget}) do
    reserve_tool_call(budget, limit)
  end

  defp reserve_tool_call(budget, limit) do
    current = :atomics.get(budget, 1)

    cond do
      current >= limit ->
        {:error, :tool_call_limit_exceeded}

      :atomics.compare_exchange(budget, 1, current, current + 1) == :ok ->
        :ok

      true ->
        reserve_tool_call(budget, limit)
    end
  end

  @doc """
  Merges new bindings into the environment.
  """
  @spec merge_env(t(), map()) :: t()
  def merge_env(%__MODULE__{} = context, bindings) do
    new_locals = bindings |> Map.keys() |> MapSet.new()

    %{
      context
      | env: Map.merge(context.env, bindings),
        locals: MapSet.union(context.locals, new_locals)
    }
  end
end
