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

      with :ok <- validate_tools(tools) do
        context = Context.new(context_map, tools)

        sandbox_opts = [
          timeout: Keyword.get(opts, :timeout, 1000),
          max_heap: Keyword.get(opts, :max_heap, 1_250_000)
        ]

        Sandbox.execute(ast, context, sandbox_opts)
      end
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

  @doc """
  Formats an error into a human-readable message suitable for LLM feedback.

  This function converts internal error tuples into clear, actionable messages
  that help LLMs understand what went wrong and how to fix their programs.

  ## Examples

      iex> PtcRunner.format_error({:parse_error, "unexpected token"})
      "ParseError: unexpected token"

      iex> PtcRunner.format_error({:validation_error, "unknown operation"})
      "ValidationError: unknown operation"
  """
  @spec format_error(error() | any()) :: String.t()
  def format_error({:parse_error, msg}), do: "ParseError: #{msg}"
  def format_error({:validation_error, msg}), do: "ValidationError: #{msg}"
  def format_error({:timeout, ms}), do: "TimeoutError: execution exceeded #{ms}ms limit"
  def format_error({:memory_exceeded, bytes}), do: "MemoryError: exceeded #{bytes} byte limit"

  def format_error({:execution_error, msg}) when is_binary(msg) do
    cond do
      msg =~ "badmap" || msg =~ "expected a map" ->
        extract_type_error(msg)

      msg =~ "badkey" || msg =~ ~r/key .+ not found/ ->
        extract_key_error(msg)

      msg =~ "undefined_variable" ->
        extract_undefined_var_error(msg)

      msg =~ "badarith" ->
        "ArithmeticError: invalid arithmetic operation (e.g., division by zero or wrong types)"

      msg =~ "function_clause" ->
        "TypeError: function received unexpected argument types"

      true ->
        # Extract first meaningful line for generic errors
        msg
        |> String.split("\n")
        |> List.first()
        |> String.slice(0, 200)
        |> then(&"ExecutionError: #{&1}")
    end
  end

  def format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  # Extract type error details from badmap errors
  defp extract_type_error(msg) do
    # Try to extract the value that was received instead of a map
    cond do
      # Match: expected a map, got:\n\n    "value"
      match = Regex.run(~r/expected a map, got:\s*\n?\s*"([^"]+)"/s, msg) ->
        [_, value] = match
        "TypeError: expected an object but got: \"#{String.slice(value, 0, 50)}\""

      # Match: expected a map, got:\n\n    value (non-quoted)
      match = Regex.run(~r/expected a map, got:\s*\n?\s*([^\n"]+)/s, msg) ->
        [_, value] = match
        "TypeError: expected an object but got: #{String.trim(value) |> String.slice(0, 50)}"

      # Match badmap tuple: {:badmap, "value"}
      match = Regex.run(~r/badmap,\s*"([^"]+)"/, msg) ->
        [_, value] = match
        "TypeError: expected an object but got: \"#{String.slice(value, 0, 50)}\""

      true ->
        "TypeError: expected an object but got a different type"
    end
  end

  # Extract key error details
  defp extract_key_error(msg) do
    cond do
      # Match: key :atom not found
      match = Regex.run(~r/key\s+:(\w+)\s+not found/, msg) ->
        [_, key] = match
        "KeyError: field '#{key}' not found in object"

      # Match: key "string" not found
      match = Regex.run(~r/key\s+"([^"]+)"\s+not found/, msg) ->
        [_, key] = match
        "KeyError: field '#{key}' not found in object"

      true ->
        "KeyError: field not found in object"
    end
  end

  # Extract undefined variable details
  defp extract_undefined_var_error(msg) do
    case Regex.run(~r/undefined_variable.*[,{]?\s*"(\w+)"/, msg) do
      [_, var] -> "UndefinedVariable: '#{var}' is not defined in context"
      _ -> "UndefinedVariable: variable not found in context"
    end
  end

  defp validate_tools(tools) do
    invalid_tools =
      tools
      |> Enum.reject(fn {_name, fun} -> is_function(fun, 1) end)
      |> Enum.map(fn {name, _fun} -> name end)

    case invalid_tools do
      [] ->
        :ok

      names ->
        {:error,
         {:validation_error,
          "Tools must be functions with arity 1. Invalid: #{Enum.join(names, ", ")}"}}
    end
  end
end
