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
  """
  @spec run(String.t(), keyword()) ::
          {:ok, term(), map(), map()} | {:error, term()}
  def run(source, opts \\ []) do
    ctx = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})
    tools = Keyword.get(opts, :tools, %{})

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
      apply_memory_contract(value, memory)
    end
  end

  # Non-map result: no memory update
  defp apply_memory_contract(value, memory) when not is_map(value) do
    {:ok, value, %{}, memory}
  end

  # Map result: check for :result key
  defp apply_memory_contract(value, memory) when is_map(value) do
    {result_value, rest} = Map.pop(value, :result)
    new_memory = Map.merge(memory, rest)

    case result_value do
      nil ->
        # Map without :result → merge into memory, map is returned
        {:ok, value, rest, new_memory}

      _ ->
        # Map with :result → merge rest into memory, :result value returned
        {:ok, result_value, rest, new_memory}
    end
  end
end
