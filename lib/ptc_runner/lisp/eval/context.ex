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
  | `pmap_max_concurrency` | `schedulers * 2` | — | Max concurrent pmap/pcalls tasks |

  ## Tool-ledger retention

  `tool_calls` records every call's `:result` and `:args` for post-eval
  telemetry/envelope rendering. To stop a long-running or looping tool use
  (e.g. a paginated read fold) from accumulating full payloads in live eval
  state, `append_tool_call/2` bounds each entry's `:result` to a preview once
  it exceeds `max_tool_call_result_bytes`, marking the entry with
  `:result_truncated`. Only the LEDGER copy is bounded — the value returned to
  the program and any `tool_cache` entry keep the full result (they are built
  separately in `record_tool_call`). `:args` is left intact (it is tiny in the
  fold case and `TurnEvent.tool_call_summary/1` needs the raw map for upstream
  identity + the canonical args hash), as are `:child_trace_id`/`:child_step`.
  """

  @default_print_length 2000
  @default_tool_call_result_bytes 16_384

  @default_pmap_timeout 5_000
  @default_pmap_max_concurrency System.schedulers_online() * 2

  defstruct [
    :ctx,
    :user_ns,
    :env,
    :tool_exec,
    :discovery_exec,
    :turn_history,
    :budget,
    :trace_context,
    :journal,
    summaries: %{},
    iteration_count: 0,
    loop_limit: 1000,
    max_print_length: @default_print_length,
    max_tool_calls: nil,
    max_tool_call_result_bytes: @default_tool_call_result_bytes,
    pmap_timeout: @default_pmap_timeout,
    pmap_max_concurrency: @default_pmap_max_concurrency,
    # Absolute monotonic-time deadline (ms) shared by an in-progress
    # pmap/pcalls operation and all of its nested parallel calls. `nil`
    # outside any parallel operation; the outermost pmap/pcalls sets it
    # to `now + pmap_timeout` and nested calls inherit it unchanged, so
    # N parallel branches cannot multiply total wall time.
    pmap_deadline: nil,
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
    prints: [],
    tool_calls: [],
    pmap_calls: [],
    catalog_ops: [],
    tool_cache: %{},
    tools_meta: %{},
    locals: MapSet.new(),
    # When true, accessing `data/<key>` for a key that was not provided
    # in the context raises a runtime error naming the binding instead
    # of returning `nil`. Off by default (preserves existing in-process
    # behaviour); MCP requests pass `strict_data: true` per § 9.3.
    strict_data: false,
    # Capability Prelude V1 (plan §5): the attached compiled prelude's PUBLIC
    # export table, a map from string ref (e.g. "crm/get-user") to a
    # `{callable, ns_env}` tuple — the callable captured from `private_env` plus
    # its OWN namespace's private env. Qualified prelude calls
    # (`{:prelude_call, ref, args}`) resolve here — inserted in resolver order
    # AFTER the mutable `user` namespace and BEFORE builtins. The paired
    # `ns_env` is threaded as the export body's `user_ns` layer so its private
    # sibling helpers resolve within its OWN namespace, while user code (whose
    # `user_ns` is the ordinary mutable namespace) cannot reach private helpers
    # by qualified symbol. `%{}` when no prelude is attached.
    prelude_exports: %{},
    # The attached compiled prelude artifact (`%PtcRunner.Lisp.Prelude{}`) or
    # `nil`. Discovery forms (`ns-publics`, `doc`, `meta`, `dir`, `apropos`,
    # `all-ns`, `ns-name`) consult its PUBLIC export records — the SAME records
    # the analyzer/evaluator use, no separate registry (plan §8). Private
    # helpers have no export record and so never surface in discovery.
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
  - `child_trace_id`: Trace ID of nested SubAgentTool execution (if any)
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
  Trace context for nested agent execution tracing.

  Fields:
  - `trace_id`: Unique identifier for this trace session
  - `parent_span_id`: Span ID of the parent operation (nil for root)
  - `depth`: Nesting depth for visualization
  """
  @type trace_context ::
          %{
            trace_id: String.t(),
            parent_span_id: String.t() | nil,
            depth: non_neg_integer()
          }
          | nil

  @typedoc """
  Parallel map/calls execution record for tracing.

  Fields:
  - `type`: `:pmap` or `:pcalls`
  - `count`: Number of parallel tasks
  - `child_trace_ids`: List of trace IDs from SubAgentTool executions
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

  @typedoc """
  Discovery operation record for tracing.

  Fields:
  - `operation`: Which discovery operation was called
  - `args`: Arguments passed to the operation
  - `outcome`: `:ok`, `:nil_world_fault`, or `:error`
  - `reason`: Reason for nil/error outcome (e.g., `:catalog_cap_exhausted`)
  - `duration_ms`: How long the operation took
  """
  @type catalog_op :: %{
          operation: atom(),
          args: map(),
          outcome: :ok | :nil_world_fault | :error,
          reason: atom() | nil,
          duration_ms: non_neg_integer()
        }

  @type t :: %__MODULE__{
          ctx: map(),
          user_ns: map(),
          env: map(),
          tool_exec: (String.t(), map() -> term()),
          discovery_exec: (atom(), list() -> term()) | nil,
          turn_history: list(),
          budget: map() | nil,
          trace_context: trace_context(),
          journal: map() | nil,
          summaries: %{String.t() => String.t()},
          iteration_count: integer(),
          loop_limit: integer(),
          max_tool_calls: pos_integer() | nil,
          max_tool_call_result_bytes: pos_integer(),
          max_print_length: pos_integer(),
          pmap_timeout: pos_integer(),
          pmap_max_concurrency: pos_integer(),
          pmap_deadline: integer() | nil,
          max_heap: pos_integer() | nil,
          worker_max_heap: pos_integer() | nil,
          parallel_budget: PtcRunner.Lisp.Eval.ParallelBudget.t() | nil,
          prints: [String.t()],
          tool_calls: [tool_call()],
          pmap_calls: [pmap_call()],
          catalog_ops: [catalog_op()],
          tool_cache: map(),
          tools_meta: %{String.t() => %{cache: boolean()}},
          strict_data: boolean(),
          prelude_exports: %{String.t() => {term(), map()}},
          prelude: PtcRunner.Lisp.Prelude.t() | nil
        }

  @type recur_effects :: %{
          prints: [String.t()],
          tool_calls: [tool_call()],
          pmap_calls: [pmap_call()],
          catalog_ops: [catalog_op()],
          tool_cache: map()
        }

  @doc """
  Creates a new evaluation context.

  ## Options

  - `:max_print_length` - Max characters per `println` call (default: #{@default_print_length})
  - `:budget` - Budget info map for `(budget/remaining)` introspection (default: nil)
  - `:pmap_timeout` - Timeout in ms for each pmap task (default: 5000). Increase for LLM-backed tools.
  - `:pmap_max_concurrency` - Max concurrent tasks in pmap/pcalls (default: `System.schedulers_online() * 2`)
  - `:max_heap` - Sandbox per-process heap cap in words (default: nil).
  - `:worker_max_heap` - FIXED `max_heap_size` (in words) for every
    pmap/pcalls worker, top-level and nested (default: the `:max_heap`
    value). Not divided by concurrency. See `PtcRunner.Lisp.Eval.ParallelRunner`.
  - `:parallel_budget` - shared `PtcRunner.Lisp.Eval.ParallelBudget`
    semaphore bounding the number of parallel workers alive at once
    across the whole run (default: nil = uncounted).
  - `:trace_context` - Trace context for nested agent tracing (default: nil)

  ## Examples

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])
      iex> ctx.user_ns
      %{}

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [], max_print_length: 500)
      iex> ctx.max_print_length
      500

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [], budget: %{turns: 10})
      iex> ctx.budget
      %{turns: 10}

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [], pmap_timeout: 60_000)
      iex> ctx.pmap_timeout
      60000

  """
  @spec new(map(), map(), map(), (String.t(), map() -> term()), list(), keyword()) :: t()
  def new(ctx, user_ns, env, tool_exec, turn_history, opts \\ []) do
    %__MODULE__{
      ctx: ctx,
      user_ns: user_ns,
      env: env,
      tool_exec: tool_exec,
      discovery_exec: Keyword.get(opts, :discovery_exec),
      turn_history: turn_history,
      max_tool_calls: Keyword.get(opts, :max_tool_calls),
      max_tool_call_result_bytes:
        Keyword.get(opts, :max_tool_call_result_bytes, @default_tool_call_result_bytes),
      max_print_length: Keyword.get(opts, :max_print_length, @default_print_length),
      pmap_timeout: Keyword.get(opts, :pmap_timeout, @default_pmap_timeout),
      pmap_max_concurrency:
        Keyword.get(opts, :pmap_max_concurrency, @default_pmap_max_concurrency),
      max_heap: Keyword.get(opts, :max_heap),
      worker_max_heap: Keyword.get(opts, :worker_max_heap, Keyword.get(opts, :max_heap)),
      parallel_budget: Keyword.get(opts, :parallel_budget),
      budget: Keyword.get(opts, :budget),
      trace_context: Keyword.get(opts, :trace_context),
      journal: Keyword.get(opts, :journal),
      tool_cache: Keyword.get(opts, :tool_cache, %{}),
      tools_meta: Keyword.get(opts, :tools_meta, %{}),
      strict_data: Keyword.get(opts, :strict_data, false),
      prelude_exports: prelude_exports(Keyword.get(opts, :prelude)),
      prelude: prelude_artifact(Keyword.get(opts, :prelude)),
      prints: [],
      tool_calls: [],
      pmap_calls: [],
      catalog_ops: []
    }
  end

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
      {export.ref, {Map.get(ns_env, export.symbol), ns_env}}
    end)
  end

  defp prelude_artifact(nil), do: nil
  defp prelude_artifact(%PtcRunner.Lisp.Prelude{} = prelude), do: prelude

  @doc """
  Appends a print message to the context.

  Long messages are truncated to `max_print_length` characters (default: #{@default_print_length}).
  """
  @spec append_print(t(), String.t()) :: t()
  def append_print(%__MODULE__{prints: prints, max_print_length: max_len} = context, message) do
    total = String.length(message)

    truncated =
      if total > max_len do
        String.slice(message, 0, max_len) <> "... (#{max_len}/#{total} chars)"
      else
        message
      end

    %{context | prints: [truncated | prints]}
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
        %__MODULE__{tool_calls: tool_calls, max_tool_call_result_bytes: cap} = context,
        tool_call
      ) do
    %{context | tool_calls: [compact_ledger_entry(tool_call, cap) | tool_calls]}
  end

  # Bound the LEDGER copy of :result only. Preserves every other field,
  # including a nil :result (failed call), :child_trace_id / :child_step
  # (trace-hierarchy metadata), and — critically — the raw :args map.
  # `:args` is NOT truncated: `TurnEvent.tool_call_summary/1` reads it to
  # extract the upstream server/tool and compute the canonical args hash for
  # duplicate-fetch detection, and args are tiny in the fold use case anyway.
  # Small results pass through identically so existing entries are byte-for-
  # byte unchanged.
  defp compact_ledger_entry(%{result: result} = tool_call, cap)
       when is_integer(cap) and cap > 0 and not is_nil(result) do
    case retained_size(result, cap) do
      size when is_integer(size) and size <= cap ->
        tool_call

      size ->
        tool_call
        |> Map.put(:result, preview(result, cap))
        |> Map.put(:result_truncated, true)
        |> Map.put(:result_bytes, size)
    end
  end

  defp compact_ledger_entry(tool_call, _cap), do: tool_call

  @word_bytes :erlang.system_info(:wordsize)

  # Retained-HEAP estimate, conservative (never under-counts), in the same units
  # the sandbox bills (`max_heap`). Two parts:
  #
  #   * the term's flat heap size (`:erts_debug.flat_size/1`, words → bytes):
  #     cons cells, tuples, boxed terms. NOT the serialized encoding —
  #     `:erlang.external_size/1` is ~16× smaller for int-heavy lists (a 16k-int
  #     list encodes to ~16 KB but occupies ~256 KB of heap), which would let it
  #     slip under the cap; and
  #   * the parent size of any refc binary reachable in the term
  #     (`:binary.referenced_byte_size/1`). flat_size counts only a binary's
  #     ProcBin header, not its shared bytes (which the sandbox DOES bill), and a
  #     sub-binary keeps its whole parent alive.
  #
  # The two parts are SUMMED, not maxed: the sandbox bills the heap structure
  # AND the shared binary bytes, so a mixed `{rows, raw_chunk}` result retains
  # both. (flat_size already includes each binary's small ProcBin header, a
  # negligible and conservative double-count.) Short-circuit: only walk binaries
  # when the flat heap is already under the cap — if it alone exceeds the cap we
  # truncate regardless, and the sum would only be larger.
  defp retained_size(value, cap) do
    case heap_size(value) do
      :oversized -> :oversized
      heap when heap > cap -> heap
      heap -> heap + referenced_binary_size(value)
    end
  end

  defp heap_size(value) do
    :erts_debug.flat_size(value) * @word_bytes
  rescue
    # Defensive: treat an unsizeable term as oversized so it is previewed.
    _ -> :oversized
  end

  # Sum of underlying parent byte sizes of binaries reachable in the term.
  # Over-counts when sub-binaries share a parent — safe (biases toward
  # truncation, never under toward retention).
  defp referenced_binary_size(value) when is_binary(value),
    do: :binary.referenced_byte_size(value)

  defp referenced_binary_size(value) when is_list(value),
    do: Enum.reduce(value, 0, &(referenced_binary_size(&1) + &2))

  defp referenced_binary_size(value) when is_map(value),
    do:
      Enum.reduce(value, 0, fn {k, v}, acc ->
        acc + referenced_binary_size(k) + referenced_binary_size(v)
      end)

  defp referenced_binary_size(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> referenced_binary_size()

  defp referenced_binary_size(_value), do: 0

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
  def append_pmap_call(%__MODULE__{pmap_calls: pmap_calls} = context, pmap_call) do
    %{context | pmap_calls: [pmap_call | pmap_calls]}
  end

  @doc """
  Appends a catalog operation record to the context.
  """
  @spec append_catalog_op(t(), catalog_op()) :: t()
  def append_catalog_op(%__MODULE__{catalog_ops: catalog_ops} = context, catalog_op) do
    %{context | catalog_ops: [catalog_op | catalog_ops]}
  end

  @doc """
  Extracts accumulated side effects that must survive a `recur` jump.
  """
  @spec recur_effects(t()) :: recur_effects()
  def recur_effects(%__MODULE__{} = context) do
    %{
      prints: context.prints,
      tool_calls: context.tool_calls,
      pmap_calls: context.pmap_calls,
      catalog_ops: context.catalog_ops,
      tool_cache: context.tool_cache
    }
  end

  @doc """
  Restores side effects carried by a `recur` signal onto the next iteration context.
  """
  @spec restore_recur_effects(t(), recur_effects()) :: t()
  def restore_recur_effects(%__MODULE__{} = context, effects) do
    %{
      context
      | prints: effects.prints,
        tool_calls: effects.tool_calls,
        pmap_calls: effects.pmap_calls,
        catalog_ops: effects.catalog_ops,
        tool_cache: effects.tool_cache
    }
  end

  @doc """
  Updates the user namespace in the context.
  """
  @spec update_user_ns(t(), map()) :: t()
  def update_user_ns(%__MODULE__{} = context, new_user_ns) do
    %{context | user_ns: new_user_ns}
  end

  @doc """
  Copies the attached prelude tables (`prelude_exports`/`prelude`) from
  `source` onto `context`.

  Sub-contexts built with `new/6` for closure/thunk evaluation start with empty
  prelude tables; this re-installs them so a qualified prelude call made from
  inside a user closure still resolves (Capability Prelude V1, plan §5).
  """
  @spec inherit_prelude(t(), t()) :: t()
  def inherit_prelude(%__MODULE__{} = context, %__MODULE__{} = source) do
    %{
      context
      | prelude_exports: source.prelude_exports,
        prelude: source.prelude
    }
  end

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
  Checks whether the tool call limit has been reached.

  Returns `:ok` when unlimited (`nil`) or under the limit,
  `{:error, :tool_call_limit_exceeded}` when at or over.
  """
  @spec check_tool_call_limit(t()) :: :ok | {:error, :tool_call_limit_exceeded}
  def check_tool_call_limit(%{max_tool_calls: nil}), do: :ok

  def check_tool_call_limit(%{max_tool_calls: limit, tool_calls: calls}) do
    if length(calls) >= limit, do: {:error, :tool_call_limit_exceeded}, else: :ok
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
