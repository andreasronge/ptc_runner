defmodule PtcRunner.Lisp do
  @moduledoc """
  Execute PTC programs written in Lisp DSL (Clojure subset).

  PTC-Lisp enables LLMs to write safe programs that orchestrate tools and transform
  data. Unlike raw code execution (Python, JavaScript), PTC-Lisp provides safety by
  design: no filesystem/network access, no unbounded recursion, and deterministic
  execution in isolated BEAM processes with resource limits.

  See the [PTC-Lisp Specification](ptc-lisp-specification.md) for the complete
  language reference.

  ## Tool Registration

  Tools are functions that receive a map of arguments and return results.
  Note: tool names use kebab-case in Lisp (e.g., `"get-user"` not `"get_user"`):

      tools = %{
        "get-user" => fn %{"id" => id} -> MyApp.Users.get(id) end,
        "search" => fn %{"query" => q} -> MyApp.Search.run(q) end
      }

      PtcRunner.Lisp.run(~S|(tool/get-user {:id 123})|, tools: tools)

  **Contract:**
  - Receives: `map()` of arguments (may be empty `%{}`)
  - Returns: Any Elixir term (maps, lists, primitives)
  - Should not raise (return `{:error, reason}` for errors)
  """

  alias PtcRunner.Lisp.{Analyze, DataKeys, Env, Eval, ExecutionError, Parser, SymbolCounter}
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Step
  alias PtcRunner.SubAgent.Signature
  alias PtcRunner.Tool

  @doc """
  Run a PTC-Lisp program.

  ## Parameters

  - `source`: PTC-Lisp source code as a string
  - `opts`: Keyword list of options
    - `:context` - Initial context map (default: %{})
    - `:memory` - Initial memory map (default: %{})
    - `:tools` - Map of tool names to functions (default: %{})
    - `:signature` - Optional signature string for return value validation
    - `:float_precision` - Number of decimal places for floats in result (default: nil = full precision)
    - `:timeout` - Timeout in milliseconds for entire sandbox execution (default: 1000)
    - `:pmap_timeout` - Timeout in milliseconds per pmap/pcalls task (default: 5000). Increase for LLM-backed tools.
    - `:max_heap` - Max heap size in words (default: 1_250_000)
    - `:max_symbols` - Max unique symbols/keywords allowed (default: 10_000)
    - `:max_print_length` - Max characters per `println` call (default: 2000)
    - `:filter_context` - Filter context to only include accessed data keys (default: true)
    - `:budget` - Budget info map for `(budget/remaining)` introspection (default: nil)
    - `:trace_context` - Trace context for nested agent tracing (default: nil)

  ## Return Value

  On success, returns:
  - `{:ok, Step.t()}` with:
    - `step.return`: The value returned to the caller
    - `step.memory`: Complete memory state after execution
    - `step.usage`: Execution metrics (duration_ms, memory_bytes)

  On error, returns:
  - `{:error, Step.t()}` with:
    - `step.fail.reason`: Error reason atom
    - `step.fail.message`: Human-readable error description
    - `step.memory`: Memory state at time of error

  ## Memory Contract

  The memory contract is applied only at the top level (via `apply_memory_contract/3`):
  - If result is not a map: `step.return` = value, no memory update
  - If result is a map without `:return`: merges map into memory, returns map as `step.return`
  - If result is a map with `:return`: merges remaining keys into memory, returns `:return` value as `step.return`

  **Related modules:**
  - `PtcRunner.SubAgent.Loop` - Uses this contract to persist memory across turns
  - `PtcRunner.Lisp.Eval` - Evaluates programs with user_ns (memory) symbol resolution

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

  ## Context Filtering

  By default, PTC-Lisp performs static analysis to identify which `data/xxx` keys are accessed
  by a program, then filters the context to only include those datasets. This significantly
  reduces memory pressure when the context contains large datasets that aren't used.

      # Only products is loaded into the sandbox, orders/employees are filtered out
      ctx = %{"products" => large_list, "orders" => large_list, "employees" => large_list}
      PtcRunner.Lisp.run("(count data/products)", context: ctx)

  Scalar context values (strings, numbers, nil) are always preserved as they typically
  represent metadata like prompts or configuration.

  Disable filtering if you need all context available (e.g., for dynamic data access):

      PtcRunner.Lisp.run(source, context: ctx, filter_context: false)

  See `PtcRunner.Lisp.DataKeys` for the static analysis implementation.
  """
  @spec run(String.t(), keyword()) ::
          {:ok, Step.t()} | {:error, Step.t()}
  def run(source, opts \\ []) do
    ctx = Keyword.get(opts, :context, %{})
    memory = Keyword.get(opts, :memory, %{})
    raw_tools = Keyword.get(opts, :tools, %{})
    signature_str = Keyword.get(opts, :signature)
    float_precision = Keyword.get(opts, :float_precision)
    timeout = Keyword.get(opts, :timeout, 1000)
    max_heap = Keyword.get(opts, :max_heap, 1_250_000)
    max_symbols = Keyword.get(opts, :max_symbols, 10_000)
    turn_history = Keyword.get(opts, :turn_history, [])
    max_print_length = Keyword.get(opts, :max_print_length)
    filter_context = Keyword.get(opts, :filter_context, true)
    budget = Keyword.get(opts, :budget)
    pmap_timeout = Keyword.get(opts, :pmap_timeout)
    trace_context = Keyword.get(opts, :trace_context)
    journal = Keyword.get(opts, :journal)
    tool_cache = Keyword.get(opts, :tool_cache, %{})

    # Normalize tools to Tool structs
    with {:ok, normalized_tools} <- normalize_tools(raw_tools),
         {:ok, parsed_signature} <- parse_signature(signature_str) do
      # Note: tool_executor handles {:error, reason} returns and unknown tools by raising
      # ExecutionError. This matches the behavior in SubAgent.Loop.ToolNormalizer,
      # which handles the SubAgent execution path.
      tool_executor = fn name, args ->
        case Map.fetch(normalized_tools, name) do
          {:ok, %Tool{function: fun}} ->
            case fun.(args) do
              {:ok, value} ->
                value

              {:error, reason} ->
                raise ExecutionError, reason: :tool_error, message: name, data: reason

              value ->
                value
            end

          :error ->
            available = Map.keys(normalized_tools) |> Enum.sort()
            raise ExecutionError, reason: :unknown_tool, message: name, data: available
        end
      end

      # Build tools_meta lookup: %{name => %{cache: bool}}
      tools_meta =
        Map.new(normalized_tools, fn {name, tool} -> {name, %{cache: tool.cache}} end)

      opts = %{
        ctx: ctx,
        memory: memory,
        normalized_tools: normalized_tools,
        tool_executor: tool_executor,
        parsed_signature: parsed_signature,
        signature_str: signature_str,
        float_precision: float_precision,
        timeout: timeout,
        max_heap: max_heap,
        max_symbols: max_symbols,
        turn_history: turn_history,
        max_print_length: max_print_length,
        filter_context: filter_context,
        budget: budget,
        pmap_timeout: pmap_timeout,
        trace_context: trace_context,
        journal: journal,
        tool_cache: tool_cache,
        tools_meta: tools_meta
      }

      execute_program(source, opts)
    else
      {:error, {:invalid_tool, tool_name, reason}} ->
        {:error,
         Step.error(:invalid_tool, "Tool '#{tool_name}': #{inspect(reason)}", memory, %{},
           journal: journal
         )}

      {:error, {:invalid_signature, msg}} ->
        {:error,
         Step.error(:parse_error, "Invalid signature: #{msg}", memory, %{}, journal: journal)}
    end
  end

  @doc """
  Validate PTC-Lisp source code without executing it.

  Parses and analyzes the source, then checks for undefined variables.
  Returns `:ok` if valid, or `{:error, messages}` with a list of error strings.

  ## Examples

      iex> PtcRunner.Lisp.validate("(and (map? data/result) (> (count data/result) 0))")
      :ok

      iex> PtcRunner.Lisp.validate("(and (map? foo) true)")
      {:error, ["foo"]}

      iex> PtcRunner.Lisp.validate("(let [x 1] (> x 0))")
      :ok
  """
  @spec validate(String.t()) :: :ok | {:error, [String.t()]}
  def validate(source) when is_binary(source) do
    with {:ok, raw_ast} <- Parser.parse(source),
         {:ok, core_ast} <- Analyze.analyze(raw_ast) do
      case collect_undefined_vars(core_ast, MapSet.new()) do
        [] -> :ok
        undefined -> {:error, Enum.uniq(undefined)}
      end
    else
      {:error, reason} -> {:error, [format_validate_error(reason)]}
    end
  end

  defp execute_program(source, opts) do
    %{
      ctx: ctx,
      memory: memory,
      normalized_tools: normalized_tools,
      tool_executor: tool_executor,
      parsed_signature: parsed_signature,
      signature_str: signature_str,
      float_precision: float_precision,
      timeout: timeout,
      max_heap: max_heap,
      max_symbols: max_symbols,
      turn_history: turn_history,
      max_print_length: max_print_length,
      filter_context: filter_context,
      budget: budget,
      pmap_timeout: pmap_timeout,
      trace_context: trace_context,
      journal: journal,
      tool_cache: tool_cache,
      tools_meta: tools_meta
    } = opts

    with {:ok, raw_ast} <- Parser.parse(source),
         :ok <- check_symbol_limit(raw_ast, max_symbols, memory, journal),
         {:ok, core_ast} <- Analyze.analyze(raw_ast) do
      # Filter context to only include data keys accessed by the program
      # This reduces memory pressure by not loading unused datasets
      filtered_ctx = if filter_context, do: DataKeys.filter_context(core_ast, ctx), else: ctx

      # Build Context for sandbox (turn_history passed for completeness, used via eval_fn)
      context = PtcRunner.Context.new(filtered_ctx, memory, normalized_tools, turn_history)

      # Build eval options (only include options if set)
      eval_opts =
        [
          max_print_length: max_print_length,
          budget: budget,
          pmap_timeout: pmap_timeout,
          trace_context: trace_context,
          journal: journal,
          tool_cache: tool_cache,
          tools_meta: tools_meta
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      # Wrapper to adapt Lisp eval signature to sandbox's expected (ast, context) -> result
      eval_fn = fn _ast, sandbox_context ->
        try do
          Eval.eval_with_context(
            core_ast,
            sandbox_context.ctx,
            sandbox_context.memory,
            Env.initial(),
            tool_executor,
            sandbox_context.turn_history,
            eval_opts
          )
        rescue
          e in ExecutionError ->
            {:error, {e.reason, e.message, e.data}}

          e in PtcRunner.ToolExecutionError ->
            # Tool error with eval_ctx preserved (contains recorded tool_calls)
            {:error, {:tool_error, e.tool_name, e.message}, e.eval_ctx}

          e ->
            # Catch unexpected exceptions in tool implementations and report as tool errors
            {:error, {:tool_error, "unknown", Exception.message(e)}}
        end
      end

      sandbox_opts = [
        timeout: timeout,
        max_heap: max_heap,
        eval_fn: eval_fn
      ]

      case PtcRunner.Sandbox.execute(core_ast, context, sandbox_opts) do
        {:ok, {:return_signal, value}, metrics, %EvalContext{} = eval_ctx} ->
          # For return signal, we return the value but wrap it in the sentinel for SubAgent to detect
          step =
            apply_memory_contract({:__ptc_return__, value}, float_precision, eval_ctx)

          {:ok, %{step | usage: metrics}}

        {:ok, {:fail_signal, value}, metrics, %EvalContext{} = eval_ctx} ->
          step =
            apply_memory_contract({:__ptc_fail__, value}, float_precision, eval_ctx)

          {:ok, %{step | usage: metrics}}

        {:ok, {:error_with_ctx, reason}, metrics, %EvalContext{} = eval_ctx} ->
          # Error with eval_ctx preserved (e.g., from tool execution error)
          reason_atom = if is_tuple(reason), do: elem(reason, 0), else: reason

          # Extract child_trace_ids from both direct tool calls and pmap/pcalls
          tool_child_traces =
            eval_ctx.tool_calls
            |> Enum.filter(&Map.has_key?(&1, :child_trace_id))
            |> Enum.map(& &1.child_trace_id)

          pmap_child_traces =
            eval_ctx.pmap_calls
            |> Enum.flat_map(& &1.child_trace_ids)

          child_traces = tool_child_traces ++ pmap_child_traces

          # Extract child_steps from tool calls and pmap/pcalls
          tool_child_steps =
            eval_ctx.tool_calls
            |> Enum.filter(&Map.has_key?(&1, :child_step))
            |> Enum.map(& &1.child_step)

          pmap_child_steps =
            eval_ctx.pmap_calls
            |> Enum.flat_map(&Map.get(&1, :child_steps, []))

          child_steps = tool_child_steps ++ pmap_child_steps

          # Strip child_step/child_steps from tool/pmap_calls
          cleaned_tool_calls = Enum.map(eval_ctx.tool_calls, &Map.delete(&1, :child_step))
          cleaned_pmap_calls = Enum.map(eval_ctx.pmap_calls, &Map.delete(&1, :child_steps))

          step = %Step{
            return: nil,
            fail: %{reason: reason_atom, message: format_error(reason)},
            memory: memory,
            signature: nil,
            usage: metrics,
            turns: nil,
            trace_id: nil,
            parent_trace_id: nil,
            field_descriptions: nil,
            prints: eval_ctx.prints,
            tool_calls: cleaned_tool_calls,
            pmap_calls: cleaned_pmap_calls,
            child_traces: child_traces,
            child_steps: child_steps,
            journal: eval_ctx.journal,
            summaries: eval_ctx.summaries,
            tool_cache: eval_ctx.tool_cache
          }

          {:error, step}

        {:ok, value, metrics, %EvalContext{} = eval_ctx} ->
          step =
            apply_memory_contract(value, float_precision, eval_ctx)

          step_with_usage = %{step | usage: metrics}

          # Validate signature if provided
          case validate_return_value(parsed_signature, signature_str, step_with_usage) do
            {:ok, validated_step} -> {:ok, validated_step}
            {:error, reason} -> {:error, reason}
          end

        {:error, {:timeout, ms}} ->
          {:error,
           Step.error(:timeout, "execution exceeded #{ms}ms limit", memory, %{}, journal: journal)}

        {:error, {:memory_exceeded, bytes}} ->
          {:error,
           Step.error(:memory_exceeded, "heap limit #{bytes} bytes exceeded", memory, %{},
             journal: journal
           )}

        {:error, {reason_atom, _, _} = reason} when is_atom(reason_atom) ->
          # Handle 3-tuple error format: {:error, {:type_error, message, data}}
          {:error, Step.error(reason_atom, format_error(reason), memory, %{}, journal: journal)}

        {:error, {reason_atom, _} = reason} when is_atom(reason_atom) ->
          # Handle 2-tuple error format: {:error, {:type_error, message}}
          {:error, Step.error(reason_atom, format_error(reason), memory, %{}, journal: journal)}
      end
    else
      {:error, {:parse_error, msg}} ->
        {:error, Step.error(:parse_error, msg, memory, %{}, journal: journal)}

      {:error, %Step{} = step} ->
        # Pass through Step errors from check_symbol_limit
        {:error, step}

      {:error, {reason_atom, _, _} = reason} when is_atom(reason_atom) ->
        # Preserve specific error atoms from Analyze phase (e.g., {:invalid_arity, :if, "msg"})
        {:error, Step.error(reason_atom, format_error(reason), memory, %{}, journal: journal)}

      {:error, {reason_atom, _} = reason} when is_atom(reason_atom) ->
        # Handle other 2-tuple errors from Analyze phase
        {:error, Step.error(reason_atom, format_error(reason), memory, %{}, journal: journal)}
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
  # Handle Eval errors with specific types
  def format_error({:unbound_var, name}) do
    msg = Helpers.format_closure_error({:unbound_var, name})
    # Lowercase first letter to match existing style
    <<first::utf8, rest::binary>> = msg
    <<String.downcase(<<first::utf8>>)::binary, rest::binary>>
  end

  def format_error({:not_callable, value}), do: "not callable: #{inspect(value, limit: 3)}"
  def format_error({:arity_error, msg}), do: "arity error: #{msg}"
  # Handle tool errors
  def format_error({:unknown_tool, name, []}), do: "Unknown tool: #{name}. No tools available."

  def format_error({:unknown_tool, name, available}),
    do: "Unknown tool: #{name}. Available tools: #{Enum.join(available, ", ")}"

  def format_error({:tool_error, name, reason}), do: "Tool '#{name}' failed: #{inspect(reason)}"
  # Handle other 3-tuple error formats from Eval: {type, message, data}
  def format_error({type, msg, _}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error({type, msg}) when is_atom(type) and is_binary(msg), do: "#{type}: #{msg}"
  def format_error(other), do: "Error: #{inspect(other, limit: 5)}"

  # V2 simplified memory contract: pass through all values unchanged.
  # Storage is explicit via `def` (values persist in user_ns).
  # No implicit map merge or :return key handling.
  defp apply_memory_contract(value, precision, %EvalContext{} = ctx) do
    reversed_tool_calls = Enum.reverse(ctx.tool_calls)
    reversed_pmap_calls = Enum.reverse(ctx.pmap_calls)

    # Extract child_trace_ids from both direct tool calls and pmap/pcalls
    tool_child_traces =
      reversed_tool_calls
      |> Enum.filter(&Map.has_key?(&1, :child_trace_id))
      |> Enum.map(& &1.child_trace_id)

    pmap_child_traces =
      reversed_pmap_calls
      |> Enum.flat_map(& &1.child_trace_ids)

    child_traces = tool_child_traces ++ pmap_child_traces

    # Extract child_steps from tool calls and pmap/pcalls
    tool_child_steps =
      reversed_tool_calls
      |> Enum.filter(&Map.has_key?(&1, :child_step))
      |> Enum.map(& &1.child_step)

    pmap_child_steps =
      reversed_pmap_calls
      |> Enum.flat_map(&Map.get(&1, :child_steps, []))

    child_steps = tool_child_steps ++ pmap_child_steps

    # Strip child_step/child_steps from tool/pmap_calls to avoid double storage
    cleaned_tool_calls = Enum.map(reversed_tool_calls, &Map.delete(&1, :child_step))
    cleaned_pmap_calls = Enum.map(reversed_pmap_calls, &Map.delete(&1, :child_steps))

    %Step{
      return: round_floats(value, precision),
      fail: nil,
      memory: ctx.user_ns,
      journal: ctx.journal,
      summaries: ctx.summaries,
      tool_cache: ctx.tool_cache,
      signature: nil,
      usage: nil,
      turns: nil,
      prints: Enum.reverse(ctx.prints),
      tool_calls: cleaned_tool_calls,
      pmap_calls: cleaned_pmap_calls,
      child_traces: child_traces,
      child_steps: child_steps
    }
  end

  # Round floats recursively in nested structures
  defp round_floats(value, nil), do: value

  defp round_floats(value, precision) when is_float(value) do
    Float.round(value, precision)
  end

  defp round_floats(value, precision) when is_list(value) do
    Enum.map(value, &round_floats(&1, precision))
  end

  defp round_floats(value, precision) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {k, round_floats(v, precision)} end)
  end

  # Handle sentinel tuples for return/fail signals
  defp round_floats({:__ptc_return__, inner}, precision) do
    {:__ptc_return__, round_floats(inner, precision)}
  end

  defp round_floats({:__ptc_fail__, inner}, precision) do
    {:__ptc_fail__, round_floats(inner, precision)}
  end

  defp round_floats(value, _precision), do: value

  # Check if symbol count exceeds limit
  defp check_symbol_limit(ast, max_symbols, memory, journal) do
    count = SymbolCounter.count(ast)

    if count <= max_symbols do
      :ok
    else
      {:error,
       Step.error(
         :symbol_limit_exceeded,
         "program contains #{count} unique symbols/keywords, exceeds limit of #{max_symbols}",
         memory,
         %{},
         journal: journal
       )}
    end
  end

  # Normalize tools from various formats to Tool structs
  defp normalize_tools(raw_tools) do
    Enum.reduce_while(raw_tools, {:ok, %{}}, fn {name, format}, {:ok, acc} ->
      case Tool.new(name, format) do
        {:ok, tool} -> {:cont, {:ok, Map.put(acc, name, tool)}}
        {:error, reason} -> {:halt, {:error, {:invalid_tool, name, reason}}}
      end
    end)
  end

  # Parse signature if provided
  defp parse_signature(nil), do: {:ok, nil}

  defp parse_signature(signature_str) when is_binary(signature_str) do
    case Signature.parse(signature_str) do
      {:ok, sig} -> {:ok, sig}
      {:error, msg} -> {:error, {:invalid_signature, msg}}
    end
  end

  # Validate return value against signature
  defp validate_return_value(nil, _signature_str, step), do: {:ok, step}

  defp validate_return_value(parsed_signature, signature_str, step) do
    case Signature.validate(parsed_signature, step.return) do
      :ok ->
        # Store the original signature string in the step
        {:ok, %{step | signature: signature_str}}

      {:error, errors} ->
        msg = format_validation_errors(errors)

        {:error,
         Step.error(:validation_error, msg, step.memory, %{},
           journal: step.journal,
           tool_cache: step.tool_cache
         )}
    end
  end

  # Format validation errors into a readable message
  defp format_validation_errors(errors) do
    Enum.map_join(errors, "; ", fn %{path: path, message: message} ->
      path_str = format_path(path)
      "#{path_str}: #{message}"
    end)
  end

  defp format_path([]), do: "return"
  defp format_path(path), do: "return." <> Enum.join(path, ".")

  # ============================================================
  # validate/1 helpers — walk CoreAST collecting undefined vars
  # ============================================================

  # Variable reference — check builtins and local scope
  defp collect_undefined_vars({:var, name}, scope) do
    if Env.builtin?(name) or MapSet.member?(scope, name) do
      []
    else
      [to_string(name)]
    end
  end

  # Data access — always valid
  defp collect_undefined_vars({:data, _key}, _scope), do: []

  # Literals
  defp collect_undefined_vars(nil, _scope), do: []
  defp collect_undefined_vars(n, _scope) when is_number(n), do: []
  defp collect_undefined_vars(b, _scope) when is_boolean(b), do: []
  defp collect_undefined_vars({:string, _}, _scope), do: []
  defp collect_undefined_vars({:keyword, _}, _scope), do: []
  defp collect_undefined_vars({:literal, _}, _scope), do: []
  defp collect_undefined_vars(a, _scope) when a in [:infinity, :negative_infinity, :nan], do: []

  # Let bindings — extend scope with bound vars
  defp collect_undefined_vars({:let, bindings, body}, scope) do
    {binding_errors, extended_scope} =
      Enum.reduce(bindings, {[], scope}, fn {:binding, pattern, value}, {errs, sc} ->
        value_errs = collect_undefined_vars(value, sc)
        new_scope = Enum.reduce(pattern_vars(pattern), sc, &MapSet.put(&2, &1))
        {errs ++ value_errs, new_scope}
      end)

    binding_errors ++ collect_undefined_vars(body, extended_scope)
  end

  # fn — extend scope with param vars
  defp collect_undefined_vars({:fn, params, body}, scope) do
    param_names = fn_param_vars(params)
    extended_scope = Enum.reduce(param_names, scope, &MapSet.put(&2, &1))
    collect_undefined_vars(body, extended_scope)
  end

  # loop — extend scope with binding vars
  defp collect_undefined_vars({:loop, bindings, body}, scope) do
    {binding_errors, extended_scope} =
      Enum.reduce(bindings, {[], scope}, fn {:binding, pattern, value}, {errs, sc} ->
        value_errs = collect_undefined_vars(value, sc)
        new_scope = Enum.reduce(pattern_vars(pattern), sc, &MapSet.put(&2, &1))
        {errs ++ value_errs, new_scope}
      end)

    binding_errors ++ collect_undefined_vars(body, extended_scope)
  end

  # Function call
  defp collect_undefined_vars({:call, target, args}, scope) do
    collect_undefined_vars(target, scope) ++
      Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  # Tool call
  defp collect_undefined_vars({:tool_call, _name, args}, scope) do
    Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  # def — add name to scope before recursing (enables recursive defn)
  defp collect_undefined_vars({:def, name, value, _meta}, scope) do
    collect_undefined_vars(value, MapSet.put(scope, name))
  end

  # Control flow
  defp collect_undefined_vars({:if, c, t, e}, scope) do
    collect_undefined_vars(c, scope) ++
      collect_undefined_vars(t, scope) ++ collect_undefined_vars(e, scope)
  end

  defp collect_undefined_vars({:do, exprs}, scope) do
    {errors, _final_scope} =
      Enum.reduce(exprs, {[], scope}, fn expr, {errs, sc} ->
        new_errs = collect_undefined_vars(expr, sc)

        new_sc =
          case expr do
            {:def, name, _value, _meta} -> MapSet.put(sc, name)
            _ -> sc
          end

        {errs ++ new_errs, new_sc}
      end)

    errors
  end

  defp collect_undefined_vars({:and, exprs}, scope) do
    Enum.flat_map(exprs, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:or, exprs}, scope) do
    Enum.flat_map(exprs, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:return, value}, scope) do
    collect_undefined_vars(value, scope)
  end

  defp collect_undefined_vars({:fail, value}, scope) do
    collect_undefined_vars(value, scope)
  end

  defp collect_undefined_vars({:recur, args}, scope) do
    Enum.flat_map(args, &collect_undefined_vars(&1, scope))
  end

  # Collections
  defp collect_undefined_vars({:vector, elems}, scope) do
    Enum.flat_map(elems, &collect_undefined_vars(&1, scope))
  end

  defp collect_undefined_vars({:map, pairs}, scope) do
    Enum.flat_map(pairs, fn {k, v} ->
      collect_undefined_vars(k, scope) ++ collect_undefined_vars(v, scope)
    end)
  end

  defp collect_undefined_vars({:set, elems}, scope) do
    Enum.flat_map(elems, &collect_undefined_vars(&1, scope))
  end

  # Predicates
  defp collect_undefined_vars({:where, _field, _op, value}, scope) when not is_nil(value) do
    collect_undefined_vars(value, scope)
  end

  defp collect_undefined_vars({:where, _field, _op, nil}, _scope), do: []

  defp collect_undefined_vars({:pred_combinator, _kind, predicates}, scope) do
    Enum.flat_map(predicates, &collect_undefined_vars(&1, scope))
  end

  # Juxt
  defp collect_undefined_vars({:juxt, fns}, scope) do
    Enum.flat_map(fns, &collect_undefined_vars(&1, scope))
  end

  # Parallel operations
  defp collect_undefined_vars({:pmap, fn_expr, coll_expr}, scope) do
    collect_undefined_vars(fn_expr, scope) ++ collect_undefined_vars(coll_expr, scope)
  end

  defp collect_undefined_vars({:pcalls, fn_exprs}, scope) do
    Enum.flat_map(fn_exprs, &collect_undefined_vars(&1, scope))
  end

  # Task/step operations
  defp collect_undefined_vars({:task, _id, body}, scope) do
    collect_undefined_vars(body, scope)
  end

  defp collect_undefined_vars({:task_dynamic, id_expr, body}, scope) do
    collect_undefined_vars(id_expr, scope) ++ collect_undefined_vars(body, scope)
  end

  defp collect_undefined_vars({:step_done, id, summary}, scope) do
    collect_undefined_vars(id, scope) ++ collect_undefined_vars(summary, scope)
  end

  defp collect_undefined_vars({:task_reset, id}, scope) do
    collect_undefined_vars(id, scope)
  end

  # Budget/turn history
  defp collect_undefined_vars({:budget_remaining}, _scope), do: []
  defp collect_undefined_vars({:turn_history, _n}, _scope), do: []

  # Catch-all for unhandled nodes
  defp collect_undefined_vars(_other, _scope), do: []

  # Extract variable names from fn params
  defp fn_param_vars(params) when is_list(params) do
    Enum.flat_map(params, &pattern_vars/1)
  end

  defp fn_param_vars({:variadic, leading, rest_pattern}) do
    Enum.flat_map(leading, &pattern_vars/1) ++ pattern_vars(rest_pattern)
  end

  # Extract all variable names from a destructuring pattern
  defp pattern_vars({:var, name}), do: [name]

  defp pattern_vars({:destructure, {:keys, keys, _defaults}}) do
    keys
  end

  defp pattern_vars({:destructure, {:map, keys, renames, _defaults}}) do
    keys ++
      Enum.flat_map(renames, fn {target_pattern, _source_key} -> pattern_vars(target_pattern) end)
  end

  defp pattern_vars({:destructure, {:as, name, inner}}) do
    [name | pattern_vars(inner)]
  end

  defp pattern_vars({:destructure, {:seq, patterns}}) do
    Enum.flat_map(patterns, &pattern_vars/1)
  end

  defp pattern_vars({:destructure, {:seq_rest, leading, rest}}) do
    Enum.flat_map(leading, &pattern_vars/1) ++ pattern_vars(rest)
  end

  defp pattern_vars(_other), do: []

  # Format errors from parse/analyze for validate/1
  defp format_validate_error({:parse_error, msg}), do: "Parse error: #{msg}"

  defp format_validate_error({:invalid_arity, _form, msg}), do: "Analysis error: #{msg}"

  defp format_validate_error({:invalid_placeholder, name}),
    do:
      "Analysis error: placeholder '#{name}' can only be used inside #() anonymous function syntax"

  defp format_validate_error({type, msg}) when is_atom(type) and is_binary(msg),
    do: "#{type}: #{msg}"

  defp format_validate_error(other), do: "Error: #{inspect(other)}"
end
