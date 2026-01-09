defmodule PtcRunner.Lisp.Eval.Context do
  @moduledoc """
  Evaluation context for the Lisp interpreter.

  Bundles the parameters that flow through recursive evaluation:
  - `ctx`: External data (read-only)
  - `user_ns`: User namespace (mutable bindings from `def`)
  - `env`: Lexical environment (variable bindings)
  - `tool_exec`: Tool executor function
  - `turn_history`: Previous turn results for multi-turn loops
  """

  defstruct [
    :ctx,
    :user_ns,
    :env,
    :tool_exec,
    :turn_history,
    iteration_count: 0,
    loop_limit: 1000,
    prints: [],
    tool_calls: []
  ]

  @max_loop_limit 10_000

  @typedoc """
  Tool call record for tracing.

  Fields:
  - `name`: Tool name
  - `args`: Arguments passed to tool
  - `result`: Tool result
  - `error`: Error message if tool failed
  - `timestamp`: When tool was called
  - `duration_ms`: How long tool took
  """
  @type tool_call :: %{
          name: String.t(),
          args: map(),
          result: term(),
          error: String.t() | nil,
          timestamp: DateTime.t(),
          duration_ms: non_neg_integer()
        }

  @type t :: %__MODULE__{
          ctx: map(),
          user_ns: map(),
          env: map(),
          tool_exec: (String.t(), map() -> term()),
          turn_history: list(),
          iteration_count: integer(),
          loop_limit: integer(),
          prints: [String.t()],
          tool_calls: [tool_call()]
        }

  @doc """
  Creates a new evaluation context.

  ## Examples

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])
      iex> ctx.user_ns
      %{}

  """
  @spec new(map(), map(), map(), (String.t(), map() -> term()), list()) :: t()
  def new(ctx, user_ns, env, tool_exec, turn_history) do
    %__MODULE__{
      ctx: ctx,
      user_ns: user_ns,
      env: env,
      tool_exec: tool_exec,
      turn_history: turn_history,
      prints: [],
      tool_calls: []
    }
  end

  @doc """
  Appends a print message to the context.
  """
  @spec append_print(t(), String.t()) :: t()
  def append_print(%__MODULE__{prints: prints} = context, message) do
    %{context | prints: [message | prints]}
  end

  @doc """
  Appends a tool call record to the context.
  """
  @spec append_tool_call(t(), tool_call()) :: t()
  def append_tool_call(%__MODULE__{tool_calls: tool_calls} = context, tool_call) do
    %{context | tool_calls: [tool_call | tool_calls]}
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
end
