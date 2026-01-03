defmodule PtcRunner.Lisp.Eval.Context do
  @moduledoc """
  Evaluation context for the Lisp interpreter.

  Bundles the parameters that flow through recursive evaluation:
  - `ctx`: External data (read-only)
  - `memory`: Mutable state
  - `env`: Lexical environment (variable bindings)
  - `tool_exec`: Tool executor function
  - `turn_history`: Previous turn results for multi-turn loops
  """

  defstruct [:ctx, :memory, :env, :tool_exec, :turn_history]

  @type t :: %__MODULE__{
          ctx: map(),
          memory: map(),
          env: map(),
          tool_exec: (String.t(), map() -> term()),
          turn_history: list()
        }

  @doc """
  Creates a new evaluation context.

  ## Examples

      iex> ctx = PtcRunner.Lisp.Eval.Context.new(%{}, %{}, %{}, fn _, _ -> nil end, [])
      iex> ctx.memory
      %{}

  """
  @spec new(map(), map(), map(), (String.t(), map() -> term()), list()) :: t()
  def new(ctx, memory, env, tool_exec, turn_history) do
    %__MODULE__{
      ctx: ctx,
      memory: memory,
      env: env,
      tool_exec: tool_exec,
      turn_history: turn_history
    }
  end

  @doc """
  Updates memory in the context, returning a new context.
  """
  @spec put_memory(t(), atom(), term()) :: t()
  def put_memory(%__MODULE__{} = context, key, value) do
    %{context | memory: Map.put(context.memory, key, value)}
  end

  @doc """
  Updates the memory map in the context.
  """
  @spec update_memory(t(), map()) :: t()
  def update_memory(%__MODULE__{} = context, new_memory) do
    %{context | memory: new_memory}
  end

  @doc """
  Merges new bindings into the environment.
  """
  @spec merge_env(t(), map()) :: t()
  def merge_env(%__MODULE__{} = context, bindings) do
    %{context | env: Map.merge(context.env, bindings)}
  end
end
