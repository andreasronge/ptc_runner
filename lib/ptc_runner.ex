defmodule PtcRunner do
  @moduledoc """
  A BEAM-native Programmatic Tool Calling (PTC) runner.

  PtcRunner enables LLMs to write safe programs that orchestrate tools
  and transform data inside a sandboxed environment.

  ## Examples

      iex> program = ~s({"program": {"op": "literal", "value": 42}})
      iex> {:ok, result, _metrics} = PtcRunner.run(program)
      iex> result
      42
  """

  alias PtcRunner.Context
  alias PtcRunner.Parser
  alias PtcRunner.Sandbox
  alias PtcRunner.Validator

  @typedoc """
  Execution metrics for a program run.
  """
  @type metrics :: %{
          duration_ms: integer(),
          memory_bytes: integer()
        }

  @typedoc """
  Error types returned by PtcRunner operations.
  """
  @type error ::
          {:parse_error, String.t()}
          | {:validation_error, String.t()}
          | {:execution_error, String.t()}
          | {:timeout, non_neg_integer()}
          | {:memory_exceeded, non_neg_integer()}

  @doc """
  Runs a PTC program and returns the result with metrics.

  ## Arguments
    - program: JSON string or parsed map representing the program
    - opts: Execution options

  ## Options
    - `:context` - Map of pre-bound variables (default: `%{}`)
    - `:tools` - Tool registry (default: `%{}`)
    - `:timeout` - Timeout in milliseconds (default: 1000)
    - `:max_heap` - Max heap size in words (default: 1_250_000)

  ## Returns
    - `{:ok, result, metrics}` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> {:ok, result, _metrics} = PtcRunner.run(~s({"program": {"op": "literal", "value": 42}}))
      iex> result
      42
  """
  @spec run(String.t() | map(), keyword()) ::
          {:ok, any(), metrics()} | {:error, error()}

  def run(program, opts \\ []) do
    with {:ok, ast} <- Parser.parse(program),
         :ok <- Validator.validate(ast) do
      context_map = Keyword.get(opts, :context, %{})
      tools = Keyword.get(opts, :tools, %{})
      context = Context.new(context_map, tools)

      sandbox_opts = [
        timeout: Keyword.get(opts, :timeout, 1000),
        max_heap: Keyword.get(opts, :max_heap, 1_250_000)
      ]

      Sandbox.execute(ast, context, sandbox_opts)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a PTC program, raising on error.

  ## Arguments
    - program: JSON string or parsed map representing the program
    - opts: Execution options (same as `run/2`)

  ## Returns
    - The result value (metrics are discarded)

  ## Raises
    - Raises an error if parsing, validation, or execution fails

  ## Examples

      iex> result = PtcRunner.run!(~s({"program": {"op": "literal", "value": 42}}))
      iex> result
      42
  """
  @spec run!(String.t() | map(), keyword()) :: any()

  def run!(program, opts \\ []) do
    case run(program, opts) do
      {:ok, result, _metrics} -> result
      {:error, reason} -> raise "PtcRunner error: #{inspect(reason)}"
    end
  end
end
