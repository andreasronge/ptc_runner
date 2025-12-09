defmodule PtcRunner.Lisp do
  @moduledoc "Main entry point for PTC-Lisp execution"

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

  ## Return Value

  On success, returns a 4-tuple:
  - `{:ok, result, memory_delta, new_memory}`
    - `result`: The value returned to the caller
    - `memory_delta`: Map of keys that changed
    - `new_memory`: Complete memory state after merge

  On error, returns:
  - `{:error, reason}` from parser, analyzer, or evaluator

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
  """
  @spec run(String.t(), keyword()) ::
          {:ok, term(), map(), map()} | {:error, term()}
  def run(source, opts \\ []) do
    ctx = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})
    tools = Keyword.get(opts, :tools, %{})
    float_precision = Keyword.get(opts, :float_precision)

    tool_executor = fn name, args ->
      case Map.fetch(tools, name) do
        {:ok, fun} -> fun.(args)
        :error -> raise "Unknown tool: #{name}"
      end
    end

    with {:ok, raw_ast} <- Parser.parse(source),
         {:ok, core_ast} <- Analyze.analyze(raw_ast),
         {:ok, value, _eval_memory} <-
           Eval.eval(core_ast, ctx, memory, Env.initial(), tool_executor) do
      apply_memory_contract(value, memory, float_precision)
    end
  end

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
