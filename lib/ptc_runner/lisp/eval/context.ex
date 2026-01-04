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

  defstruct [:ctx, :user_ns, :env, :tool_exec, :turn_history]

  @type t :: %__MODULE__{
          ctx: map(),
          user_ns: map(),
          env: map(),
          tool_exec: (String.t(), map() -> term()),
          turn_history: list()
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
      turn_history: turn_history
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
  Merges new bindings into the environment.
  """
  @spec merge_env(t(), map()) :: t()
  def merge_env(%__MODULE__{} = context, bindings) do
    %{context | env: Map.merge(context.env, bindings)}
  end
end
