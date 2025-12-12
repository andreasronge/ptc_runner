defmodule PtcRunner.Json do
  @moduledoc """
  Execute PTC programs written in JSON DSL.

  PtcRunner.Json enables LLMs to write safe programs that orchestrate tools
  and transform data inside a sandboxed environment using JSON syntax.

  See the [PTC-JSON Specification](ptc-json-specification.md) for the complete
  DSL reference and the [Guide](guide.md) for architecture overview.

  ## Tool Registration

  Tools are functions that receive a map of arguments and return results:

      tools = %{
        "get_user" => fn %{"id" => id} -> MyApp.Users.get(id) end,
        "search" => fn %{"query" => q, "limit" => n} -> MyApp.Search.run(q, limit: n) end
      }

      PtcRunner.Json.run(program, tools: tools)

  **Contract:**
  - Receives: `map()` of arguments (may be empty `%{}`)
  - Returns: Any Elixir term (maps, lists, primitives)
  - Should not raise (return `{:error, reason}` for errors)

  ## Error Handling

  Use `format_error/1` to convert errors into LLM-friendly messages:

      case PtcRunner.Json.run(program, tools: tools) do
        {:ok, result, _, _} -> handle_success(result)
        {:error, error} -> retry_with_feedback(format_error(error))
      end

  ## Examples

      iex> program = ~s({"program": {"op": "literal", "value": 42}})
      iex> {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      iex> result
      42
  """

  alias PtcRunner.Context
  alias PtcRunner.Json.Parser
  alias PtcRunner.Json.Validator
  alias PtcRunner.Sandbox

  @typedoc """
  Execution metrics for a program run.
  """
  @type metrics :: %{
          duration_ms: integer(),
          memory_bytes: integer()
        }

  @typedoc """
  Error types returned by PtcRunner.Json operations.
  """
  @type error ::
          {:parse_error, String.t()}
          | {:validation_error, String.t()}
          | {:execution_error, String.t()}
          | {:timeout, non_neg_integer()}
          | {:memory_exceeded, non_neg_integer()}

  @doc """
  Runs a PTC program and returns the result with metrics and memory.

  ## Arguments
    - program: JSON string or parsed map representing the program
    - opts: Execution options

  ## Options
    - `:context` - Map of external context data (default: `%{}`)
    - `:memory` - Map of initial memory state (default: `%{}`)
    - `:tools` - Tool registry (default: `%{}`)
    - `:timeout` - Timeout in milliseconds (default: 1000)
    - `:max_heap` - Max heap size in words (default: 1_250_000)

  ## Returns
    - `{:ok, result, memory_delta, new_memory}` on success
    - `{:error, reason}` on failure

  The return format follows the memory contract:
  - If result is not a map: `memory_delta` is empty, `new_memory` is unchanged
  - If result is a map with `"result"` key: `"result"` value is returned, other keys merged to memory
  - If result is a map with `:result` key: `:result` value is returned, other keys merged to memory
  - If result is a map without `"result"` or `:result`: result is returned as-is, merged to memory

  ## Examples

      iex> {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(~s({"program": {"op": "literal", "value": 42}}))
      iex> result
      42
  """
  @spec run(String.t() | map(), keyword()) ::
          {:ok, any(), map(), map()} | {:error, error()}

  def run(program, opts \\ []) do
    with {:ok, ast} <- Parser.parse(program),
         :ok <- Validator.validate(ast) do
      ctx = Keyword.get(opts, :context, %{})
      memory = Keyword.get(opts, :memory, %{})
      tools = Keyword.get(opts, :tools, %{})

      with :ok <- validate_tools(tools) do
        context = Context.new(ctx, memory, tools)

        sandbox_opts = [
          timeout: Keyword.get(opts, :timeout, 1000),
          max_heap: Keyword.get(opts, :max_heap, 1_250_000)
        ]

        case Sandbox.execute(ast, context, sandbox_opts) do
          {:ok, value, _metrics, eval_memory} ->
            apply_memory_contract(value, eval_memory)

          {:error, _} = err ->
            err
        end
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Apply memory contract: non-map result = no memory update
  defp apply_memory_contract(value, memory) when not is_map(value) do
    {:ok, value, %{}, memory}
  end

  # Apply memory contract: map result with "result" key
  defp apply_memory_contract(value, memory) when is_map(value) do
    cond do
      Map.has_key?(value, "result") ->
        # Map with "result" → extract "result" value, merge rest into memory
        result_value = Map.fetch!(value, "result")
        rest = Map.delete(value, "result")
        new_memory = Map.merge(memory, rest)
        {:ok, result_value, rest, new_memory}

      Map.has_key?(value, :result) ->
        # Map with :result (atom key) → merge rest into memory, :result value returned
        result_value = Map.fetch!(value, :result)
        rest = Map.delete(value, :result)
        new_memory = Map.merge(memory, rest)
        {:ok, result_value, rest, new_memory}

      true ->
        # Map without "result" or :result → merge into memory, map is returned
        new_memory = Map.merge(memory, value)
        {:ok, value, value, new_memory}
    end
  end

  @doc """
  Runs a PTC program, raising on error.

  ## Arguments
    - program: JSON string or parsed map representing the program
    - opts: Execution options (same as `run/2`)

  ## Returns
    - The result value (memory is discarded)

  ## Raises
    - Raises an error if parsing, validation, or execution fails

  ## Examples

      iex> result = PtcRunner.Json.run!(~s({"program": {"op": "literal", "value": 42}}))
      iex> result
      42
  """
  @spec run!(String.t() | map(), keyword()) :: any()

  def run!(program, opts \\ []) do
    case run(program, opts) do
      {:ok, result, _memory_delta, _new_memory} -> result
      {:error, reason} -> raise "PtcRunner error: #{inspect(reason)}"
    end
  end

  @doc """
  Formats an error into a human-readable message suitable for LLM feedback.

  This function converts internal error tuples into clear, actionable messages
  that help LLMs understand what went wrong and how to fix their programs.

  ## Examples

      iex> PtcRunner.Json.format_error({:parse_error, "unexpected token"})
      "ParseError: unexpected token"

      iex> PtcRunner.Json.format_error({:validation_error, "unknown operation"})
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
