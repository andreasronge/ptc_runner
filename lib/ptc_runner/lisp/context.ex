defmodule PtcRunner.Lisp.Context do
  @moduledoc """
  Manages context, memory, and tools for program execution.

  - `ctx`: External input data (read-only)
  - `memory`: Mutable state passed through evaluation
  - `tools`: Tool registry

  Kernel environments construct this context at the evaluator boundary.
  """

  defstruct [:ctx, :memory, :tools, turn_history: []]

  @typedoc """
  Context structure containing external data, memory, and tool registry.

  """
  @type t :: %__MODULE__{
          ctx: map(),
          memory: map(),
          tools: map(),
          turn_history: list()
        }

  @doc """
  Creates a new context with external data, memory, tools, and optional turn history.

  ## Examples

      iex> ctx = PtcRunner.Lisp.Context.new(%{"users" => [1, 2, 3]})
      iex> ctx.ctx
      %{"users" => [1, 2, 3]}

      iex> ctx = PtcRunner.Lisp.Context.new(%{}, %{"counter" => 0})
      iex> ctx.memory
      %{"counter" => 0}

  """
  @spec new(map(), map(), map(), list()) :: t()
  def new(ctx \\ %{}, memory \\ %{}, tools \\ %{}, turn_history \\ []) do
    %__MODULE__{
      ctx: ctx,
      memory: memory,
      tools: tools,
      turn_history: turn_history
    }
  end
end
