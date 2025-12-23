defmodule PtcRunner.Lisp do
  @moduledoc """
  Execute PTC programs written in Lisp DSL (Clojure subset).

  PtcRunner.Lisp enables LLMs to write safe programs that orchestrate tools
  and transform data inside a sandboxed environment using Lisp syntax.

  See the [PTC-Lisp Specification](ptc-lisp-specification.md) for the complete
  DSL reference and the [PTC-Lisp Overview](ptc-lisp-overview.md) for an introduction.

  ## Tool Registration

  Tools are functions that receive a map of arguments and return results.
  Note: tool names use kebab-case in Lisp (e.g., `"get-user"` not `"get_user"`):

      tools = %{
        "get-user" => fn %{"id" => id} -> MyApp.Users.get(id) end,
        "search" => fn %{"query" => q} -> MyApp.Search.run(q) end
      }

      PtcRunner.Lisp.run(~S|(call "get-user" {:id 123})|, tools: tools)

  **Contract:**
  - Receives: `map()` of arguments (may be empty `%{}`)
  - Returns: Any Elixir term (maps, lists, primitives)
  - Should not raise (return `{:error, reason}` for errors)
  """

  alias PtcRunner.Lisp.{Analyze, Env, Eval, Parser}

  @doc """
  Run a PTC-Lisp program.

  ## Parameters

  - `source`: PTC-Lisp source code as a string
  - `opts`: Keyword list of options
    - `:context` - Initial context map (default: %{})
    - `:memory` - Initial memory map (default: %{})
    - `:tools` - Map of tool names to functions (default: %{})
    - `:float_precision` - Number of decimal places for floats in result (default: nil = full precision)
    - `:timeout` - Timeout in milliseconds (default: 1000)
    - `:max_heap` - Max heap size in words (default: 1_250_000)

  ## Return Value

  On success, returns a 4-tuple:
  - `{:ok, result, memory_delta, new_memory}`
    - `result`: The value returned to the caller
    - `memory_delta`: Map of keys that changed
    - `new_memory`: Complete memory state after merge

  On error, returns:
  - `{:error, reason}` from parser, analyzer, evaluator, or resource limits

  ## Memory Contract

  The memory contract is applied only at the top level:
  - If result is not a map: `{:ok, value, %{}, memory}` (no memory update)
  - If result is a map without `:result`: merges map into memory, returns map as result
  - If result is a map with `:result`: merges remaining keys into memory, returns value from `:result`

  ## Float Precision

  When `:float_precision` is set, all floats in the result are rounded to that many decimal places.
  This is useful for LLM-facing applications where excessive precision wastes tokens.

      # Full precision (default)
      PtcRunner.Lisp.run("(/ 10 3)")
      #=> {:ok, 3.3333333333333335, %{}, %{}}

      # Rounded to 2 decimals
      PtcRunner.Lisp.run("(/ 10 3)", float_precision: 2)
      #=> {:ok, 3.33, %{}, %{}}

  ## Resource Limits

  Lisp programs execute with configurable timeout and memory limits:

      PtcRunner.Lisp.run(source, timeout: 5000, max_heap: 5_000_000)

  Exceeding limits returns an error:
  - `{:error, {:timeout, ms}}` - execution exceeded timeout
  - `{:error, {:memory_exceeded, bytes}}` - heap limit exceeded
  """
  @spec run(String.t(), keyword()) ::
          {:ok, term(), map(), map()} | {:error, term()}
  def run(source, opts \\ []) do
    ctx = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})
    tools = Keyword.get(opts, :tools, %{})
    float_precision = Keyword.get(opts, :float_precision)
    timeout = Keyword.get(opts, :timeout, 1000)
    max_heap = Keyword.get(opts, :max_heap, 1_250_000)

    tool_executor = fn name, args ->
      case Map.fetch(tools, name) do
        {:ok, fun} -> fun.(args)
        :error -> raise "Unknown tool: #{name}"
      end
    end

    with {:ok, raw_ast} <- Parser.parse(source),
         {:ok, core_ast} <- Analyze.analyze(raw_ast) do
      # Build Context for sandbox
      context = PtcRunner.Context.new(ctx, memory, tools)

      # Wrapper to adapt Lisp eval signature to sandbox's expected (ast, context) -> result
      eval_fn = fn _ast, sandbox_context ->
        Eval.eval(
          core_ast,
          sandbox_context.ctx,
          sandbox_context.memory,
          Env.initial(),
          tool_executor
        )
      end

      sandbox_opts = [
        timeout: timeout,
        max_heap: max_heap,
        eval_fn: eval_fn
      ]

      case PtcRunner.Sandbox.execute(core_ast, context, sandbox_opts) do
        {:ok, value, _metrics, eval_memory} ->
          apply_memory_contract(value, eval_memory, float_precision)

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Format an error tuple into a human-readable string.

  Useful for displaying errors to users or feeding back to LLMs for retry.

  ## Examples

      iex> PtcRunner.Lisp.format_error({:parse_error, "unexpected token"})
      "Parse error: unexpected token"

      iex> PtcRunner.Lisp.format_error({:eval_error, "undefined variable: x"})
      "Eval error: undefined variable: x"
  """
  @spec format_error(term()) :: String.t()
  def format_error({:parse_error, msg}), do: "Parse error: #{msg}"
  def format_error({:analysis_error, msg}), do: "Analysis error: #{msg}"
  def format_error({:eval_error, msg}), do: "Eval error: #{msg}"
  def format_error({:timeout, ms}), do: "Timeout: execution exceeded #{ms}ms limit"
  def format_error({:memory_exceeded, bytes}), do: "Memory exceeded: #{bytes} byte limit"
  def format_error({type, msg}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  # Non-map result: no memory update
  defp apply_memory_contract(value, memory, precision) when not is_map(value) do
    {:ok, round_floats(value, precision), %{}, memory}
  end

  # Map result: check for :result key
  defp apply_memory_contract(value, memory, precision) when is_map(value) do
    if Map.has_key?(value, :result) do
      # Map with :result → merge rest into memory, :result value returned
      result_value = Map.fetch!(value, :result)
      rest = Map.delete(value, :result)
      new_memory = Map.merge(memory, rest)
      {:ok, round_floats(result_value, precision), rest, new_memory}
    else
      # Map without :result → merge into memory, map is returned
      new_memory = Map.merge(memory, value)
      rounded_value = round_floats(value, precision)
      {:ok, rounded_value, value, new_memory}
    end
  end

  # Round floats recursively in nested structures
  defp round_floats(value, nil), do: value

  defp round_floats(value, precision) when is_float(value) do
    Float.round(value, precision)
  end

  defp round_floats(value, precision) when is_list(value) do
    Enum.map(value, &round_floats(&1, precision))
  end

  defp round_floats(value, precision) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, round_floats(v, precision)} end)
  end

  defp round_floats(value, _precision), do: value
end
