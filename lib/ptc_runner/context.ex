defmodule PtcRunner.Context do
  @moduledoc """
  Manages context, memory, and tools for program execution.

  - `ctx`: External input data (read-only)
  - `memory`: Mutable state passed through evaluation
  - `tools`: Tool registry

  See the [Guide](guide.md) for details on how context, memory, and tools interact.
  """

  defstruct [:ctx, :memory, :tools]

  @typedoc """
  Context structure containing external data, memory, and tool registry.
  """
  @type t :: %__MODULE__{
          ctx: map(),
          memory: map(),
          tools: map()
        }

  @doc """
  Creates a new context with external data, memory, and tools.

  ## Examples

      iex> ctx = PtcRunner.Context.new(%{"users" => [1, 2, 3]})
      iex> ctx.ctx
      %{"users" => [1, 2, 3]}

      iex> ctx = PtcRunner.Context.new(%{}, %{"counter" => 0})
      iex> ctx.memory
      %{"counter" => 0}

  """
  @spec new(map(), map(), map()) :: t()
  def new(ctx \\ %{}, memory \\ %{}, tools \\ %{}) do
    %__MODULE__{
      ctx: ctx,
      memory: memory,
      tools: tools
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
