defmodule PtcRunner.Context do
  @moduledoc """
  Manages context, memory, and tools for program execution.

  - `ctx`: External input data (read-only)
  - `memory`: Mutable state passed through evaluation
  - `tools`: Tool registry
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

  ## Arguments
    - ctx: Map of external context data (default: `%{}`)
    - memory: Map of mutable state (default: `%{}`)
    - tools: Map of tool names to functions (default: `%{}`)

  ## Returns
    - New Context struct
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

  Returns nil if key doesn't exist.

  ## Arguments
    - context: The context
    - name: Key to retrieve

  ## Returns
    - `{:ok, value}` if key exists
    - `{:ok, nil}` if key doesn't exist
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

  Returns nil if key doesn't exist.

  ## Arguments
    - context: The context
    - name: Key to retrieve

  ## Returns
    - `{:ok, value}` if key exists
    - `{:ok, nil}` if key doesn't exist
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

  ## Arguments
    - context: The context
    - name: Key name
    - value: Value to set

  ## Returns
    - Updated context
  """
  @spec put_memory(t(), String.t(), any()) :: t()
  def put_memory(context, name, value) when is_binary(name) do
    %{context | memory: Map.put(context.memory, name, value)}
  end
end
