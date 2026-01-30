defmodule PtcRunner.Context do
  @moduledoc """
  Manages context, memory, and tools for program execution.

  - `ctx`: External input data (read-only)
  - `memory`: Mutable state passed through evaluation
  - `tools`: Tool registry

  See `PtcRunner.SubAgent` for usage in agentic loops.
  """

  defstruct [:ctx, :memory, :tools, :journal, turn_history: []]

  @typedoc """
  Context structure containing external data, memory, and tool registry.

  - `journal`: Optional journal map for `(task)` idempotent execution.
    When non-nil, task results are cached by ID. When nil, tasks execute
    without caching (with a trace warning).
  """
  @type t :: %__MODULE__{
          ctx: map(),
          memory: map(),
          tools: map(),
          journal: map() | nil,
          turn_history: list()
        }

  @doc """
  Creates a new context with external data, memory, tools, and optional turn history.

  ## Examples

      iex> ctx = PtcRunner.Context.new(%{"users" => [1, 2, 3]})
      iex> ctx.ctx
      %{"users" => [1, 2, 3]}

      iex> ctx = PtcRunner.Context.new(%{}, %{"counter" => 0})
      iex> ctx.memory
      %{"counter" => 0}

  """
  @spec new(map(), map(), map(), list(), map() | nil) :: t()
  def new(ctx \\ %{}, memory \\ %{}, tools \\ %{}, turn_history \\ [], journal \\ nil) do
    %__MODULE__{
      ctx: ctx,
      memory: memory,
      tools: tools,
      turn_history: turn_history,
      journal: journal
    }
  end

  @doc """
  Retrieves a value from context (external data).

  Returns `{:ok, nil}` if key doesn't exist.

  ## Examples

      iex> ctx = PtcRunner.Context.new(%{"users" => [1, 2, 3]})
      iex> PtcRunner.Context.get_ctx(ctx, "users")
      {:ok, [1, 2, 3]}

      iex> ctx = PtcRunner.Context.new()
      iex> PtcRunner.Context.get_ctx(ctx, "missing")
      {:ok, nil}

  """
  @spec get_ctx(t(), String.t()) :: {:ok, any()} | {:error, {atom(), String.t()}}
  def get_ctx(context, name) when is_binary(name) do
    {:ok, Map.get(context.ctx, name)}
  end

  def get_ctx(_context, name) do
    {:error, {:execution_error, "Context key must be a string, got #{inspect(name)}"}}
  end

  @doc """
  Retrieves a value from memory (mutable state).

  Returns `{:ok, nil}` if key doesn't exist.

  ## Examples

      iex> ctx = PtcRunner.Context.new(%{}, %{"counter" => 42})
      iex> PtcRunner.Context.get_memory(ctx, "counter")
      {:ok, 42}

      iex> ctx = PtcRunner.Context.new()
      iex> PtcRunner.Context.get_memory(ctx, "missing")
      {:ok, nil}

  """
  @spec get_memory(t(), String.t()) :: {:ok, any()} | {:error, {atom(), String.t()}}
  def get_memory(context, name) when is_binary(name) do
    {:ok, Map.get(context.memory, name)}
  end

  def get_memory(_context, name) do
    {:error, {:execution_error, "Memory key must be a string, got #{inspect(name)}"}}
  end

  @doc """
  Sets a value in memory.

  ## Examples

      iex> ctx = PtcRunner.Context.new()
      iex> ctx = PtcRunner.Context.put_memory(ctx, "result", 100)
      iex> ctx.memory
      %{"result" => 100}

  """
  @spec put_memory(t(), String.t(), any()) :: t()
  def put_memory(context, name, value) when is_binary(name) do
    %{context | memory: Map.put(context.memory, name, value)}
  end
end
