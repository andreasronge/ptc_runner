defmodule PtcRunner.Lisp.Eval do
  @moduledoc """
  Evaluates CoreAST into values.

  The eval layer recursively interprets CoreAST nodes, resolving variables
  from lexical environments, applying builtins and user functions, and
  handling control flow.

  ## Module Structure

  This module delegates to specialized submodules:
  - `Eval.Context` - Evaluation context struct
  - `Eval.Patterns` - Pattern matching for let bindings
  - `Eval.Where` - Where predicates and comparisons
  - `Eval.Apply` - Function application dispatch
  - `Eval.Helpers` - Type errors and utilities
  """

  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.Eval.{Apply, Patterns, Where}
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext

  import PtcRunner.Lisp.Runtime, only: [flex_get: 2]

  @type env :: %{atom() => term()}
  @type tool_executor :: (String.t(), map() -> term())

  @type value ::
          nil
          | boolean()
          | number()
          | String.t()
          | atom()
          | list()
          | map()
          | MapSet.t()
          | function()
          | {:closure, [CoreAST.pattern()], CoreAST.t(), env(), list()}

  @type runtime_error ::
          {:unbound_var, atom()}
          | {:not_callable, term()}
          | {:arity_mismatch, expected :: integer(), got :: integer()}
          | {:type_error, expected :: String.t(), got :: term()}
          | {:tool_error, tool_name :: String.t(), reason :: term()}
          | {:invalid_keyword_call, atom(), [term()]}
          | {:arity_error, String.t()}
          | {:destructure_error, String.t()}

  @spec eval(CoreAST.t(), map(), map(), env(), tool_executor(), list()) ::
          {:ok, value(), map()} | {:error, runtime_error()}
  def eval(ast, ctx, memory, env, tool_executor, turn_history \\ []) do
    eval_ctx = EvalContext.new(ctx, memory, env, tool_executor, turn_history)
    do_eval(ast, eval_ctx)
  end

  # ============================================================
  # Turn history access: *1, *2, *3
  # ============================================================

  # *1 returns the most recent result (index -1), *2 the second-most-recent (index -2), etc.
  # Returns nil if the turn doesn't exist (e.g., *1 on turn 1)
  defp do_eval({:turn_history, n}, %EvalContext{memory: memory, turn_history: turn_history})
       when n in [1, 2, 3] do
    value = Enum.at(turn_history, -n, nil)
    {:ok, value, memory}
  end

  # ============================================================
  # Literals
  # ============================================================

  defp do_eval(nil, %EvalContext{memory: memory}), do: {:ok, nil, memory}
  defp do_eval(true, %EvalContext{memory: memory}), do: {:ok, true, memory}
  defp do_eval(false, %EvalContext{memory: memory}), do: {:ok, false, memory}

  defp do_eval(n, %EvalContext{memory: memory}) when is_number(n),
    do: {:ok, n, memory}

  defp do_eval({:string, s}, %EvalContext{memory: memory}), do: {:ok, s, memory}
  defp do_eval({:keyword, k}, %EvalContext{memory: memory}), do: {:ok, k, memory}

  # ============================================================
  # Collections
  # ============================================================

  # Vectors: evaluate all elements
  defp do_eval({:vector, elems}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(elems, {:ok, [], eval_ctx.memory}, fn elem, {:ok, acc, mem} ->
        case do_eval(elem, EvalContext.update_memory(eval_ctx, mem)) do
          {:ok, v, mem2} -> {:cont, {:ok, [v | acc], mem2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, values, memory2} -> {:ok, Enum.reverse(values), memory2}
      {:error, _} = err -> err
    end
  end

  # Maps: evaluate all keys and values
  defp do_eval({:map, pairs}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(pairs, {:ok, [], eval_ctx.memory}, fn {k_ast, v_ast}, {:ok, acc, mem} ->
        eval_map_pair(k_ast, v_ast, EvalContext.update_memory(eval_ctx, mem), acc)
      end)

    case result do
      {:ok, evaluated_pairs, memory2} -> {:ok, Map.new(evaluated_pairs), memory2}
      {:error, _} = err -> err
    end
  end

  # Sets: evaluate all elements, then create MapSet
  defp do_eval({:set, elems}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(elems, {:ok, [], eval_ctx.memory}, fn elem, {:ok, acc, mem} ->
        case do_eval(elem, EvalContext.update_memory(eval_ctx, mem)) do
          {:ok, v, mem2} -> {:cont, {:ok, [v | acc], mem2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, values, memory2} -> {:ok, MapSet.new(values), memory2}
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Variables and namespace access
  # ============================================================

  # Local/global variable from environment
  defp do_eval({:var, name}, %EvalContext{memory: memory, env: env}) do
    case Map.fetch(env, name) do
      {:ok, value} -> {:ok, value, memory}
      :error -> {:error, {:unbound_var, name}}
    end
  end

  # Context access: ctx/input → ctx[:input]
  defp do_eval({:ctx, key}, %EvalContext{ctx: ctx, memory: memory}) do
    {:ok, flex_get(ctx, key), memory}
  end

  # Memory access: memory/results → memory[:results]
  defp do_eval({:memory, key}, %EvalContext{memory: memory}) do
    {:ok, flex_get(memory, key), memory}
  end

  # Memory put: (memory/put :key value)
  defp do_eval({:memory_put, key, value_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, value, memory2} <- do_eval(value_ast, eval_ctx) do
      {:ok, value, Map.put(memory2, key, value)}
    end
  end

  # Memory get: (memory/get :key)
  defp do_eval({:memory_get, key}, %EvalContext{memory: memory}) do
    {:ok, flex_get(memory, key), memory}
  end

  # Sequential evaluation: do
  defp do_eval({:do, exprs}, %EvalContext{} = eval_ctx) do
    do_eval_do(exprs, eval_ctx)
  end

  # Short-circuit logic: and
  defp do_eval({:and, exprs}, %EvalContext{} = eval_ctx) do
    do_eval_and(exprs, eval_ctx)
  end

  # Short-circuit logic: or
  defp do_eval({:or, exprs}, %EvalContext{} = eval_ctx) do
    do_eval_or(exprs, eval_ctx)
  end

  # Conditional: if
  defp do_eval({:if, cond_ast, then_ast, else_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, cond_val, memory2} <- do_eval(cond_ast, eval_ctx) do
      if Where.truthy?(cond_val) do
        do_eval(then_ast, EvalContext.update_memory(eval_ctx, memory2))
      else
        do_eval(else_ast, EvalContext.update_memory(eval_ctx, memory2))
      end
    end
  end

  # Let bindings
  defp do_eval({:let, bindings, body}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(bindings, {:ok, eval_ctx}, fn {:binding, pattern, value_ast},
                                                      {:ok, acc_ctx} ->
        case do_eval(value_ast, acc_ctx) do
          {:ok, value, mem2} ->
            case Patterns.match_pattern(pattern, value) do
              {:ok, new_bindings} ->
                {:cont,
                 {:ok,
                  acc_ctx
                  |> EvalContext.update_memory(mem2)
                  |> EvalContext.merge_env(new_bindings)}}

              {:error, _} = err ->
                {:halt, err}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    case result do
      {:ok, new_ctx} -> do_eval(body, new_ctx)
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Function definition: fn
  # ============================================================

  defp do_eval({:fn, params, body}, %EvalContext{
         memory: memory,
         env: env,
         turn_history: turn_history
       }) do
    # Capture the current environment and turn history (lexical scoping)
    {:ok, {:closure, params, body, env, turn_history}, memory}
  end

  # ============================================================
  # Function calls
  # ============================================================

  defp do_eval({:call, fun_ast, arg_asts}, %EvalContext{} = eval_ctx) do
    with {:ok, fun_val, memory1} <- do_eval(fun_ast, eval_ctx) do
      result =
        Enum.reduce_while(arg_asts, {:ok, [], memory1}, fn arg_ast, {:ok, acc, mem} ->
          case do_eval(arg_ast, EvalContext.update_memory(eval_ctx, mem)) do
            {:ok, v, mem2} -> {:cont, {:ok, [v | acc], mem2}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        {:ok, arg_vals, memory2} ->
          Apply.apply_fun(
            fun_val,
            Enum.reverse(arg_vals),
            EvalContext.update_memory(eval_ctx, memory2),
            &do_eval/2
          )

        {:error, _} = err ->
          err
      end
    end
  end

  # ============================================================
  # Where predicates
  # ============================================================

  defp do_eval({:where, field_path, op, value_ast}, %EvalContext{memory: memory} = eval_ctx) do
    # Evaluate the comparison value (if not truthy check)
    case value_ast do
      nil ->
        accessor = Where.build_field_accessor(field_path)
        fun = Where.build_where_predicate(op, accessor, nil)
        {:ok, fun, memory}

      _ ->
        with {:ok, value, memory2} <- do_eval(value_ast, eval_ctx) do
          accessor = Where.build_field_accessor(field_path)
          fun = Where.build_where_predicate(op, accessor, value)
          {:ok, fun, memory2}
        end
    end
  end

  # ============================================================
  # Predicate combinators
  # ============================================================

  defp do_eval({:pred_combinator, kind, pred_asts}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(pred_asts, {:ok, [], eval_ctx.memory}, fn p_ast, {:ok, acc, mem} ->
        case do_eval(p_ast, EvalContext.update_memory(eval_ctx, mem)) do
          {:ok, f, mem2} -> {:cont, {:ok, [f | acc], mem2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, pred_fns, memory2} ->
        fun = Where.build_pred_combinator(kind, Enum.reverse(pred_fns))
        {:ok, fun, memory2}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Function combinator: juxt
  # ============================================================

  defp do_eval({:juxt, func_asts}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(func_asts, {:ok, [], eval_ctx.memory}, fn f_ast, {:ok, acc, mem} ->
        case do_eval(f_ast, EvalContext.update_memory(eval_ctx, mem)) do
          {:ok, f, mem2} -> {:cont, {:ok, [f | acc], mem2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, fns, memory2} ->
        # Convert each fn to Erlang function (handles closures, keywords, builtins)
        erlang_fns = Enum.map(Enum.reverse(fns), &juxt_fn_to_erlang(&1, eval_ctx))
        fun = build_juxt_fn(erlang_fns)
        {:ok, fun, memory2}

      {:error, _} = err ->
        err
    end
  end

  # Tool calls
  defp do_eval({:call_tool, tool_name, args_ast}, %EvalContext{tool_exec: tool_exec} = eval_ctx) do
    with {:ok, args_map, memory2} <- do_eval(args_ast, eval_ctx) do
      # Call the tool executor provided by the host
      result = tool_exec.(tool_name, args_map)
      {:ok, result, memory2}
    end
  end

  # Tool invocation via ctx namespace: (ctx/tool-name args...)
  defp do_eval({:ctx_call, tool_name, arg_asts}, %EvalContext{tool_exec: tool_exec} = eval_ctx) do
    # Evaluate all arguments
    result =
      Enum.reduce_while(arg_asts, {:ok, [], eval_ctx.memory}, fn arg_ast, {:ok, acc, mem} ->
        case do_eval(arg_ast, EvalContext.update_memory(eval_ctx, mem)) do
          {:ok, v, mem2} -> {:cont, {:ok, [v | acc], mem2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, arg_vals, memory2} ->
        # Convert args list to map for tool executor
        args_map = build_args_map(Enum.reverse(arg_vals))
        # Convert atom to string for backward compatibility with tool_exec
        tool_result = tool_exec.(Atom.to_string(tool_name), args_map)
        {:ok, tool_result, memory2}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Evaluation helpers
  # ============================================================

  # Build args map from a list of evaluated arguments for tool calls.
  # - Single map argument: pass through as-is
  # - No arguments: return empty map
  # - Other cases: wrap in a list under :args key
  defp build_args_map([]), do: %{}
  defp build_args_map([arg]) when is_map(arg), do: arg
  defp build_args_map(args), do: %{args: args}

  # Helper for map pair evaluation to reduce nesting
  defp eval_map_pair(k_ast, v_ast, %EvalContext{} = eval_ctx, acc) do
    with {:ok, k, mem2} <- do_eval(k_ast, eval_ctx),
         {:ok, v, mem3} <- do_eval(v_ast, EvalContext.update_memory(eval_ctx, mem2)) do
      {:cont, {:ok, [{k, v} | acc], mem3}}
    else
      {:error, _} = err -> {:halt, err}
    end
  end

  # ============================================================
  # Sequential evaluation helpers
  # ============================================================

  defp do_eval_do([], %EvalContext{memory: memory}), do: {:ok, nil, memory}

  defp do_eval_do([e], %EvalContext{} = eval_ctx) do
    do_eval(e, eval_ctx)
  end

  defp do_eval_do([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, _value, memory2} <- do_eval(e, eval_ctx) do
      do_eval_do(rest, EvalContext.update_memory(eval_ctx, memory2))
    end
  end

  # ============================================================
  # Short-circuit logic helpers
  # ============================================================

  defp do_eval_and([], %EvalContext{memory: memory}), do: {:ok, true, memory}

  defp do_eval_and([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, value, memory2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        do_eval_and(rest, EvalContext.update_memory(eval_ctx, memory2))
      else
        # Short-circuit: return falsy value
        {:ok, value, memory2}
      end
    end
  end

  defp do_eval_or([], %EvalContext{memory: memory}), do: {:ok, nil, memory}

  defp do_eval_or([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, value, memory2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        # Short-circuit: return truthy value
        {:ok, value, memory2}
      else
        # Continue evaluating, tracking this value as last evaluated
        do_eval_or_rest(rest, value, EvalContext.update_memory(eval_ctx, memory2))
      end
    end
  end

  defp do_eval_or_rest([], last_value, %EvalContext{memory: memory}) do
    {:ok, last_value, memory}
  end

  defp do_eval_or_rest([e | rest], _last_value, %EvalContext{} = eval_ctx) do
    with {:ok, value, memory2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        # Short-circuit: return truthy value
        {:ok, value, memory2}
      else
        # Continue evaluating, tracking this value as last evaluated
        do_eval_or_rest(rest, value, EvalContext.update_memory(eval_ctx, memory2))
      end
    end
  end

  # ============================================================
  # Juxt helpers
  # ============================================================

  # Build juxt function that applies all functions and returns vector of results
  defp build_juxt_fn(fns), do: fn arg -> Enum.map(fns, & &1.(arg)) end

  # Convert a value to an Erlang function for use in juxt
  # Keywords need special handling as map accessors
  defp juxt_fn_to_erlang(k, %EvalContext{}) when is_atom(k) and not is_boolean(k) do
    fn m -> flex_get(m, k) end
  end

  defp juxt_fn_to_erlang(value, %EvalContext{} = eval_ctx) do
    Apply.closure_to_fun(value, eval_ctx, &do_eval/2)
  end
end
