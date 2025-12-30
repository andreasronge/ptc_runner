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
  alias PtcRunner.Step

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

  On success, returns:
  - `{:ok, Step.t()}` with:
    - `step.return`: The value returned to the caller
    - `step.memory_delta`: Map of keys that changed
    - `step.memory`: Complete memory state after merge
    - `step.usage`: Execution metrics (duration_ms, memory_bytes)

  On error, returns:
  - `{:error, Step.t()}` with:
    - `step.fail.reason`: Error reason atom
    - `step.fail.message`: Human-readable error description
    - `step.memory`: Memory state at time of error

  ## Memory Contract

  The memory contract is applied only at the top level:
  - If result is not a map: `step.return` = value, no memory update
  - If result is a map without `:return`: merges map into memory, returns map as `step.return`
  - If result is a map with `:return`: merges remaining keys into memory, returns `:return` value as `step.return`

  ## Float Precision

  When `:float_precision` is set, all floats in the result are rounded to that many decimal places.
  This is useful for LLM-facing applications where excessive precision wastes tokens.

      # Full precision (default)
      {:ok, step} = PtcRunner.Lisp.run("(/ 10 3)")
      step.return
      #=> 3.3333333333333335

      # Rounded to 2 decimals
      {:ok, step} = PtcRunner.Lisp.run("(/ 10 3)", float_precision: 2)
      step.return
      #=> 3.33

  ## Resource Limits

  Lisp programs execute with configurable timeout and memory limits:

      PtcRunner.Lisp.run(source, timeout: 5000, max_heap: 5_000_000)

  Exceeding limits returns an error:
  - `{:error, {:timeout, ms}}` - execution exceeded timeout
  - `{:error, {:memory_exceeded, bytes}}` - heap limit exceeded
  """
  @spec run(String.t(), keyword()) ::
          {:ok, Step.t()} | {:error, Step.t()}
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
        {:ok, value, metrics, eval_memory} ->
          step = apply_memory_contract(value, eval_memory, float_precision)
          {:ok, %{step | usage: metrics}}

        {:error, {:timeout, ms}} ->
          {:error, Step.error(:timeout, "execution exceeded #{ms}ms limit", memory)}

        {:error, {:memory_exceeded, bytes}} ->
          {:error, Step.error(:memory_exceeded, "heap limit #{bytes} bytes exceeded", memory)}

        {:error, {reason_atom, _, _} = reason} when is_atom(reason_atom) ->
          # Handle 3-tuple error format: {:error, {:type_error, message, data}}
          {:error, Step.error(reason_atom, format_error(reason), memory)}

        {:error, {reason_atom, _} = reason} when is_atom(reason_atom) ->
          # Handle 2-tuple error format: {:error, {:type_error, message}}
          {:error, Step.error(reason_atom, format_error(reason), memory)}
      end
    else
      {:error, {:parse_error, msg}} ->
        {:error, Step.error(:parse_error, msg, %{})}

      {:error, {reason_atom, _, _} = reason} when is_atom(reason_atom) ->
        # Preserve specific error atoms from Analyze phase (e.g., {:invalid_arity, :if, "msg"})
        {:error, Step.error(reason_atom, format_error(reason), %{})}

      {:error, {reason_atom, _} = reason} when is_atom(reason_atom) ->
        # Handle other 2-tuple errors from Analyze phase
        {:error, Step.error(reason_atom, format_error(reason), %{})}
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

  def format_error({:invalid_placeholder, name}),
    do:
      "Analysis error: placeholder '#{name}' can only be used inside #() anonymous function syntax"

  def format_error({:timeout, ms}), do: "Timeout: execution exceeded #{ms}ms limit"
  def format_error({:memory_exceeded, bytes}), do: "Memory exceeded: #{bytes} byte limit"
  # Handle Analyze errors: {:invalid_arity, atom, message}
  def format_error({:invalid_arity, _atom, msg}) when is_binary(msg), do: "Analysis error: #{msg}"
  # Handle other 3-tuple error formats from Eval: {type, message, data}
  def format_error({type, msg, _}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error({type, msg}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  # Non-map result: no memory update
  defp apply_memory_contract(value, memory, precision) when not is_map(value) do
    %Step{
      return: round_floats(value, precision),
      fail: nil,
      memory: memory,
      memory_delta: %{},
      signature: nil,
      usage: nil,
      trace: nil
    }
  end

  # Map result: check for :return key
  defp apply_memory_contract(value, memory, precision) when is_map(value) do
    if Map.has_key?(value, :return) do
      # Map with :return → merge rest into memory, :return value returned
      return_value = Map.fetch!(value, :return)
      rest = Map.delete(value, :return)
      new_memory = Map.merge(memory, rest)

      %Step{
        return: round_floats(return_value, precision),
        fail: nil,
        memory: new_memory,
        memory_delta: rest,
        signature: nil,
        usage: nil,
        trace: nil
      }
    else
      # Map without :return → merge into memory, map is returned
      new_memory = Map.merge(memory, value)
      rounded_value = round_floats(value, precision)

      %Step{
        return: rounded_value,
        fail: nil,
        memory: new_memory,
        memory_delta: value,
        signature: nil,
        usage: nil,
        trace: nil
      }
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
