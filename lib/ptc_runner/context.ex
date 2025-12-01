defmodule PtcRunner.Context do
  @moduledoc """
  Manages variable bindings for program execution.

  Stores context variables and provides lookup functionality.
  """

  defstruct [:variables, :tools]

  @typedoc """
  Context structure containing variables and tool registry.
  """
  @type t :: %__MODULE__{
          variables: map(),
          tools: map()
        }

  @doc """
  Creates a new context with variables and tools.

  ## Arguments
    - variables: Map of variable names to values
    - tools: Map of tool names to functions (reserved for Phase 4)

  ## Returns
    - New Context struct
  """
  @spec new(map(), map()) :: t()
  def new(variables \\ %{}, tools \\ %{}) do
    %__MODULE__{
      variables: variables,
      tools: tools
    }
  end

  @doc """
  Retrieves a variable from context.

  Returns nil if variable doesn't exist, per architecture.md specifications.

  ## Arguments
    - context: The context
    - name: Variable name to retrieve

  ## Returns
    - `{:ok, value}` if variable exists
    - `{:ok, nil}` if variable doesn't exist
  """
  @spec get_var(t(), String.t()) :: {:ok, any()} | {:error, {atom(), String.t()}}
  def get_var(context, name) when is_binary(name) do
    {:ok, Map.get(context.variables, name)}
  end

  def get_var(_context, name) do
    {:error, {:execution_error, "Variable name must be a string, got #{inspect(name)}"}}
  end

  @doc """
  Sets a variable in context.

  ## Arguments
    - context: The context
    - name: Variable name
    - value: Value to set

  ## Returns
    - Updated context
  """
  @spec put_var(t(), String.t(), any()) :: t()
  def put_var(context, name, value) when is_binary(name) do
    %{context | variables: Map.put(context.variables, name, value)}
  end
end
