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
  | `loop_limit` | 1,000 | 10,000 | Max loop/recursion iterations |
  | `max_print_length` | 2,000 | — | Max chars per `println` call |
  | `pmap_max_concurrency` | `schedulers * 2` | — | Max concurrent pmap/pcalls tasks |
  """

  @default_print_length 2000
  @max_loop_limit 10_000

  @default_pmap_timeout 5_000
  @default_pmap_max_concurrency System.schedulers_online() * 2

  defstruct [
    :ctx,
    :user_ns,
    :env,
    :tool_exec,
    :turn_history,
    :budget,
    :trace_context,
    :journal,
    summaries: %{},
    iteration_count: 0,
    loop_limit: 1000,
    max_print_length: @default_print_length,
    max_tool_calls: nil,
    pmap_timeout: @default_pmap_timeout,
    pmap_max_concurrency: @default_pmap_max_concurrency,
    prints: [],
    tool_calls: [],
    pmap_calls: [],
    tool_cache: %{},
    tools_meta: %{}
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

  @type t :: %__MODULE__{
          ctx: map(),
          user_ns: map(),
          env: map(),
          tool_exec: (String.t(), map(), map() -> term()),
          turn_history: list(),
          budget: map() | nil,
          trace_context: trace_context(),
          journal: map() | nil,
          summaries: %{String.t() => String.t()},
          iteration_count: integer(),
          loop_limit: integer(),
          max_tool_calls: pos_integer() | nil,
          max_print_length: pos_integer(),
          pmap_timeout: pos_integer(),
          pmap_max_concurrency: pos_integer(),
          prints: [String.t()],
          tool_calls: [tool_call()],
          pmap_calls: [pmap_call()],
          tool_cache: map(),
          tools_meta: %{String.t() => %{cache: boolean()}}
        }

  @doc """
  Creates a new evaluation context.

  ## Options

  - `:max_print_length` - Max characters per `println` call (default: #{@default_print_length})
  - `:budget` - Budget info map for `(budget/remaining)` introspection (default: nil)
  - `:pmap_timeout` - Timeout in ms for each pmap task (default: 5000). Increase for LLM-backed tools.
  - `:pmap_max_concurrency` - Max concurrent tasks in pmap/pcalls (default: `System.schedulers_online() * 2`)
  - `:trace_context` - Trace context for nested agent tracing (default: nil)

  ## Examples

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [])
      iex> ctx.user_ns
      %{}

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [], max_print_length: 500)
      iex> ctx.max_print_length
      500

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [], budget: %{turns: 10})
      iex> ctx.budget
      %{turns: 10}

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _, _ -> nil end, [], pmap_timeout: 60_000)
      iex> ctx.pmap_timeout
      60000

  """
  @spec new(map(), map(), map(), (String.t(), map(), map() -> term()), list(), keyword()) :: t()
  def new(ctx, user_ns, env, tool_exec, turn_history, opts \\ []) do
    %__MODULE__{
      ctx: ctx,
      user_ns: user_ns,
      env: env,
      tool_exec: tool_exec,
      turn_history: turn_history,
      max_tool_calls: Keyword.get(opts, :max_tool_calls),
      max_print_length: Keyword.get(opts, :max_print_length, @default_print_length),
      pmap_timeout: Keyword.get(opts, :pmap_timeout, @default_pmap_timeout),
      pmap_max_concurrency:
        Keyword.get(opts, :pmap_max_concurrency, @default_pmap_max_concurrency),
      budget: Keyword.get(opts, :budget),
      trace_context: Keyword.get(opts, :trace_context),
      journal: Keyword.get(opts, :journal),
      tool_cache: Keyword.get(opts, :tool_cache, %{}),
      tools_meta: Keyword.get(opts, :tools_meta, %{}),
      prints: [],
      tool_calls: [],
      pmap_calls: []
    }
  end

  @doc """
  Appends a print message to the context.

  Long messages are truncated to `max_print_length` characters (default: #{@default_print_length}).
  """
  @spec append_print(t(), String.t()) :: t()
  def append_print(%__MODULE__{prints: prints, max_print_length: max_len} = context, message) do
    truncated =
      if String.length(message) > max_len do
        String.slice(message, 0, max_len) <> "..."
      else
        message
      end

    %{context | prints: [truncated | prints]}
  end

  @doc """
  Appends a tool call record to the context.
  """
  @spec append_tool_call(t(), tool_call()) :: t()
  def append_tool_call(%__MODULE__{tool_calls: tool_calls} = context, tool_call) do
    %{context | tool_calls: [tool_call | tool_calls]}
  end

  @doc """
  Appends a pmap/pcalls execution record to the context.
  """
  @spec append_pmap_call(t(), pmap_call()) :: t()
  def append_pmap_call(%__MODULE__{pmap_calls: pmap_calls} = context, pmap_call) do
    %{context | pmap_calls: [pmap_call | pmap_calls]}
  end

  @doc """
  Updates the user namespace in the context.
  """
  @spec update_user_ns(t(), map()) :: t()
  def update_user_ns(%__MODULE__{} = context, new_user_ns) do
    %{context | user_ns: new_user_ns}
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
  Sets a new loop limit, respecting the hard maximum.
  """
  @spec set_loop_limit(t(), integer()) :: t()
  def set_loop_limit(%__MODULE__{} = context, new_limit) do
    limit = min(max(0, new_limit), @max_loop_limit)
    %{context | loop_limit: limit}
  end

  @doc """
  Merges new bindings into the environment.
  """
  @spec merge_env(t(), map()) :: t()
  def merge_env(%__MODULE__{} = context, bindings) do
    %{context | env: Map.merge(context.env, bindings)}
  end

  @doc """
  Merges two contexts, specifically combining prints, tool calls, and pmap calls.
  Used to merge results from parallel execution branches (pmap, pcalls).
  """
  @spec merge(t(), t()) :: t()
  def merge(ctx1, ctx2) do
    %{
      ctx1
      | prints: ctx2.prints ++ ctx1.prints,
        tool_calls: ctx2.tool_calls ++ ctx1.tool_calls,
        pmap_calls: ctx2.pmap_calls ++ ctx1.pmap_calls,
        user_ns: Map.merge(ctx1.user_ns, ctx2.user_ns),
        iteration_count: ctx1.iteration_count + ctx2.iteration_count,
        summaries: Map.merge(ctx1.summaries, ctx2.summaries),
        tool_cache: Map.merge(ctx1.tool_cache, ctx2.tool_cache)
    }
  end
end
