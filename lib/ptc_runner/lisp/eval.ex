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
  defp do_eval({:turn_history, n}, %EvalContext{user_ns: user_ns, turn_history: turn_history})
       when n in [1, 2, 3] do
    value = Enum.at(turn_history, -n, nil)
    {:ok, value, user_ns}
  end

  # ============================================================
  # Literals
  # ============================================================

  defp do_eval(nil, %EvalContext{user_ns: user_ns}), do: {:ok, nil, user_ns}
  defp do_eval(true, %EvalContext{user_ns: user_ns}), do: {:ok, true, user_ns}
  defp do_eval(false, %EvalContext{user_ns: user_ns}), do: {:ok, false, user_ns}

  defp do_eval(n, %EvalContext{user_ns: user_ns}) when is_number(n),
    do: {:ok, n, user_ns}

  defp do_eval({:string, s}, %EvalContext{user_ns: user_ns}), do: {:ok, s, user_ns}
  defp do_eval({:keyword, k}, %EvalContext{user_ns: user_ns}), do: {:ok, k, user_ns}

  # ============================================================
  # Collections
  # ============================================================

  # Vectors: evaluate all elements
  defp do_eval({:vector, elems}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(elems, {:ok, [], eval_ctx.user_ns}, fn elem, {:ok, acc, ns} ->
        case do_eval(elem, EvalContext.update_user_ns(eval_ctx, ns)) do
          {:ok, v, ns2} -> {:cont, {:ok, [v | acc], ns2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, values, user_ns2} -> {:ok, Enum.reverse(values), user_ns2}
      {:error, _} = err -> err
    end
  end

  # Maps: evaluate all keys and values
  defp do_eval({:map, pairs}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(pairs, {:ok, [], eval_ctx.user_ns}, fn {k_ast, v_ast}, {:ok, acc, ns} ->
        eval_map_pair(k_ast, v_ast, EvalContext.update_user_ns(eval_ctx, ns), acc)
      end)

    case result do
      {:ok, evaluated_pairs, user_ns2} -> {:ok, Map.new(evaluated_pairs), user_ns2}
      {:error, _} = err -> err
    end
  end

  # Sets: evaluate all elements, then create MapSet
  defp do_eval({:set, elems}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(elems, {:ok, [], eval_ctx.user_ns}, fn elem, {:ok, acc, ns} ->
        case do_eval(elem, EvalContext.update_user_ns(eval_ctx, ns)) do
          {:ok, v, ns2} -> {:cont, {:ok, [v | acc], ns2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, values, user_ns2} -> {:ok, MapSet.new(values), user_ns2}
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Variables and namespace access
  # ============================================================

  # Local/global variable from environment
  defp do_eval({:var, name}, %EvalContext{user_ns: user_ns, env: env}) do
    case Map.fetch(env, name) do
      {:ok, value} -> {:ok, value, user_ns}
      :error -> {:error, {:unbound_var, name}}
    end
  end

  # Context access: ctx/input → ctx[:input]
  defp do_eval({:ctx, key}, %EvalContext{ctx: ctx, user_ns: user_ns}) do
    {:ok, flex_get(ctx, key), user_ns}
  end

  # Memory access: memory/results → memory[:results]
  defp do_eval({:memory, key}, %EvalContext{user_ns: user_ns}) do
    {:ok, flex_get(user_ns, key), user_ns}
  end

  # Memory put: (memory/put :key value)
  defp do_eval({:memory_put, key, value_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, value, user_ns2} <- do_eval(value_ast, eval_ctx) do
      {:ok, value, Map.put(user_ns2, key, value)}
    end
  end

  # Memory get: (memory/get :key)
  defp do_eval({:memory_get, key}, %EvalContext{user_ns: user_ns}) do
    {:ok, flex_get(user_ns, key), user_ns}
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
    with {:ok, cond_val, user_ns2} <- do_eval(cond_ast, eval_ctx) do
      if Where.truthy?(cond_val) do
        do_eval(then_ast, EvalContext.update_user_ns(eval_ctx, user_ns2))
      else
        do_eval(else_ast, EvalContext.update_user_ns(eval_ctx, user_ns2))
      end
    end
  end

  # Let bindings
  defp do_eval({:let, bindings, body}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(bindings, {:ok, eval_ctx}, fn {:binding, pattern, value_ast},
                                                      {:ok, acc_ctx} ->
        case do_eval(value_ast, acc_ctx) do
          {:ok, value, ns2} ->
            case Patterns.match_pattern(pattern, value) do
              {:ok, new_bindings} ->
                {:cont,
                 {:ok,
                  acc_ctx
                  |> EvalContext.update_user_ns(ns2)
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
         user_ns: user_ns,
         env: env,
         turn_history: turn_history
       }) do
    # Capture the current environment and turn history (lexical scoping)
    {:ok, {:closure, params, body, env, turn_history}, user_ns}
  end

  # ============================================================
  # Function calls
  # ============================================================

  defp do_eval({:call, fun_ast, arg_asts}, %EvalContext{} = eval_ctx) do
    with {:ok, fun_val, user_ns1} <- do_eval(fun_ast, eval_ctx) do
      result =
        Enum.reduce_while(arg_asts, {:ok, [], user_ns1}, fn arg_ast, {:ok, acc, ns} ->
          case do_eval(arg_ast, EvalContext.update_user_ns(eval_ctx, ns)) do
            {:ok, v, ns2} -> {:cont, {:ok, [v | acc], ns2}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        {:ok, arg_vals, user_ns2} ->
          Apply.apply_fun(
            fun_val,
            Enum.reverse(arg_vals),
            EvalContext.update_user_ns(eval_ctx, user_ns2),
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

  defp do_eval({:where, field_path, op, value_ast}, %EvalContext{user_ns: user_ns} = eval_ctx) do
    # Evaluate the comparison value (if not truthy check)
    case value_ast do
      nil ->
        accessor = Where.build_field_accessor(field_path)
        fun = Where.build_where_predicate(op, accessor, nil)
        {:ok, fun, user_ns}

      _ ->
        with {:ok, value, user_ns2} <- do_eval(value_ast, eval_ctx) do
          accessor = Where.build_field_accessor(field_path)
          fun = Where.build_where_predicate(op, accessor, value)
          {:ok, fun, user_ns2}
        end
    end
  end

  # ============================================================
  # Predicate combinators
  # ============================================================

  defp do_eval({:pred_combinator, kind, pred_asts}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(pred_asts, {:ok, [], eval_ctx.user_ns}, fn p_ast, {:ok, acc, ns} ->
        case do_eval(p_ast, EvalContext.update_user_ns(eval_ctx, ns)) do
          {:ok, f, ns2} -> {:cont, {:ok, [f | acc], ns2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, pred_fns, user_ns2} ->
        fun = Where.build_pred_combinator(kind, Enum.reverse(pred_fns))
        {:ok, fun, user_ns2}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Function combinator: juxt
  # ============================================================

  defp do_eval({:juxt, func_asts}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(func_asts, {:ok, [], eval_ctx.user_ns}, fn f_ast, {:ok, acc, ns} ->
        case do_eval(f_ast, EvalContext.update_user_ns(eval_ctx, ns)) do
          {:ok, f, ns2} -> {:cont, {:ok, [f | acc], ns2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, fns, user_ns2} ->
        # Convert each fn to Erlang function (handles closures, keywords, builtins)
        erlang_fns = Enum.map(Enum.reverse(fns), &juxt_fn_to_erlang(&1, eval_ctx))
        fun = build_juxt_fn(erlang_fns)
        {:ok, fun, user_ns2}

      {:error, _} = err ->
        err
    end
  end

  # Tool calls
  defp do_eval({:call_tool, tool_name, args_ast}, %EvalContext{tool_exec: tool_exec} = eval_ctx) do
    with {:ok, args_map, user_ns2} <- do_eval(args_ast, eval_ctx) do
      # Call the tool executor provided by the host
      result = tool_exec.(tool_name, args_map)
      {:ok, result, user_ns2}
    end
  end

  # Tool invocation via ctx namespace: (ctx/tool-name args...)
  defp do_eval({:ctx_call, tool_name, arg_asts}, %EvalContext{tool_exec: tool_exec} = eval_ctx) do
    # Evaluate all arguments
    result =
      Enum.reduce_while(arg_asts, {:ok, [], eval_ctx.user_ns}, fn arg_ast, {:ok, acc, ns} ->
        case do_eval(arg_ast, EvalContext.update_user_ns(eval_ctx, ns)) do
          {:ok, v, ns2} -> {:cont, {:ok, [v | acc], ns2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, arg_vals, user_ns2} ->
        # Convert args list to map for tool executor
        args_map = build_args_map(Enum.reverse(arg_vals))
        # Convert atom to string for backward compatibility with tool_exec
        tool_result = tool_exec.(Atom.to_string(tool_name), args_map)
        {:ok, tool_result, user_ns2}

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
    with {:ok, k, ns2} <- do_eval(k_ast, eval_ctx),
         {:ok, v, ns3} <- do_eval(v_ast, EvalContext.update_user_ns(eval_ctx, ns2)) do
      {:cont, {:ok, [{k, v} | acc], ns3}}
    else
      {:error, _} = err -> {:halt, err}
    end
  end

  # ============================================================
  # Sequential evaluation helpers
  # ============================================================

  defp do_eval_do([], %EvalContext{user_ns: user_ns}), do: {:ok, nil, user_ns}

  defp do_eval_do([e], %EvalContext{} = eval_ctx) do
    do_eval(e, eval_ctx)
  end

  defp do_eval_do([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, _value, user_ns2} <- do_eval(e, eval_ctx) do
      do_eval_do(rest, EvalContext.update_user_ns(eval_ctx, user_ns2))
    end
  end

  # ============================================================
  # Short-circuit logic helpers
  # ============================================================

  defp do_eval_and([], %EvalContext{user_ns: user_ns}), do: {:ok, true, user_ns}

  defp do_eval_and([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, value, user_ns2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        do_eval_and(rest, EvalContext.update_user_ns(eval_ctx, user_ns2))
      else
        # Short-circuit: return falsy value
        {:ok, value, user_ns2}
      end
    end
  end

  defp do_eval_or([], %EvalContext{user_ns: user_ns}), do: {:ok, nil, user_ns}

  defp do_eval_or([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, value, user_ns2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        # Short-circuit: return truthy value
        {:ok, value, user_ns2}
      else
        # Continue evaluating, tracking this value as last evaluated
        do_eval_or_rest(rest, value, EvalContext.update_user_ns(eval_ctx, user_ns2))
      end
    end
  end

  defp do_eval_or_rest([], last_value, %EvalContext{user_ns: user_ns}) do
    {:ok, last_value, user_ns}
  end

  defp do_eval_or_rest([e | rest], _last_value, %EvalContext{} = eval_ctx) do
    with {:ok, value, user_ns2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        # Short-circuit: return truthy value
        {:ok, value, user_ns2}
      else
        # Continue evaluating, tracking this value as last evaluated
        do_eval_or_rest(rest, value, EvalContext.update_user_ns(eval_ctx, user_ns2))
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
