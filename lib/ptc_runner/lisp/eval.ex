defmodule PtcRunner.Lisp.Eval do
  @moduledoc """
  Evaluates CoreAST into values.

  The eval layer recursively interprets CoreAST nodes, resolving variables
  from lexical environments, applying builtins and user functions, and
  handling control flow.
  """

  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext

  import PtcRunner.Lisp.Runtime, only: [flex_get: 2, flex_fetch: 2, flex_get_in: 2]

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
      if truthy?(cond_val) do
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
            case match_pattern(pattern, value) do
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
          apply_fun(fun_val, Enum.reverse(arg_vals), EvalContext.update_memory(eval_ctx, memory2))

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
        accessor = build_field_accessor(field_path)
        fun = build_where_predicate(op, accessor, nil)
        {:ok, fun, memory}

      _ ->
        with {:ok, value, memory2} <- do_eval(value_ast, eval_ctx) do
          accessor = build_field_accessor(field_path)
          fun = build_where_predicate(op, accessor, value)
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
        fun = build_pred_combinator(kind, Enum.reverse(pred_fns))
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

  # ============================================================
  # Evaluation helpers
  # ============================================================

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
      if truthy?(value) do
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
      if truthy?(value) do
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
      if truthy?(value) do
        # Short-circuit: return truthy value
        {:ok, value, memory2}
      else
        # Continue evaluating, tracking this value as last evaluated
        do_eval_or_rest(rest, value, EvalContext.update_memory(eval_ctx, memory2))
      end
    end
  end

  # ============================================================
  # Pattern Matching for Let Bindings
  # ============================================================

  defp match_pattern({:var, name}, value) do
    {:ok, %{name => value}}
  end

  defp match_pattern({:destructure, {:keys, keys, defaults}}, value) when is_map(value) do
    bindings =
      Enum.reduce(keys, %{}, fn key, acc ->
        default = Keyword.get(defaults, key)

        val =
          case flex_fetch(value, key) do
            {:ok, v} -> v
            :error -> default
          end

        Map.put(acc, key, val)
      end)

    {:ok, bindings}
  end

  defp match_pattern({:destructure, {:keys, _keys, _defaults}}, value) do
    {:error, {:destructure_error, "expected map, got #{inspect(value)}"}}
  end

  defp match_pattern({:destructure, {:map, keys, renames, defaults}}, value) when is_map(value) do
    # First extract keys
    keys_bindings =
      Enum.reduce(keys, %{}, fn key, acc ->
        default = Keyword.get(defaults, key)

        val =
          case flex_fetch(value, key) do
            {:ok, v} -> v
            :error -> default
          end

        Map.put(acc, key, val)
      end)

    # Then extract renames
    renames_bindings =
      Enum.reduce(renames, %{}, fn {bind_name, source_key}, acc ->
        default = Keyword.get(defaults, bind_name)

        val =
          case flex_fetch(value, source_key) do
            {:ok, v} -> v
            :error -> default
          end

        Map.put(acc, bind_name, val)
      end)

    {:ok, Map.merge(keys_bindings, renames_bindings)}
  end

  defp match_pattern({:destructure, {:map, _keys, _renames, _defaults}}, value) do
    {:error, {:destructure_error, "expected map, got #{inspect(value)}"}}
  end

  defp match_pattern({:destructure, {:seq, patterns}}, value) when is_list(value) do
    if length(value) < length(patterns) do
      {:error,
       {:destructure_error,
        "expected at least #{length(patterns)} elements, got #{length(value)}"}}
    else
      patterns
      |> Enum.zip(value)
      |> Enum.reduce_while({:ok, %{}}, fn {pattern, val}, {:ok, acc} ->
        case match_pattern(pattern, val) do
          {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp match_pattern({:destructure, {:seq, _}}, value) do
    {:error, {:destructure_error, "expected list, got #{inspect(value)}"}}
  end

  defp match_pattern({:destructure, {:as, as_name, inner_pattern}}, value) do
    case match_pattern(inner_pattern, value) do
      {:ok, inner_bindings} -> {:ok, Map.put(inner_bindings, as_name, value)}
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Function Application Dispatch
  # ============================================================

  # Keyword as function: (:key map) → Map.get(map, :key)
  defp apply_fun(k, args, %EvalContext{memory: memory}) when is_atom(k) do
    case args do
      [m] when is_map(m) ->
        {:ok, flex_get(m, k), memory}

      [m, default] when is_map(m) ->
        case flex_fetch(m, k) do
          {:ok, val} -> {:ok, val, memory}
          :error -> {:ok, default, memory}
        end

      [nil] ->
        {:ok, nil, memory}

      [nil, default] ->
        {:ok, default, memory}

      _ ->
        {:error, {:invalid_keyword_call, k, args}}
    end
  end

  # Set as function: (#{1 2 3} x) → checks membership, returns element or nil
  defp apply_fun(set, [arg], %EvalContext{memory: memory})
       when is_struct(set, MapSet) do
    {:ok, if(MapSet.member?(set, arg), do: arg, else: nil), memory}
  end

  defp apply_fun(set, args, %EvalContext{})
       when is_struct(set, MapSet) do
    {:error, {:arity_error, "set expects 1 argument, got #{length(args)}"}}
  end

  # Closure application (new 5-element tuple format with turn_history)
  defp apply_fun(
         {:closure, patterns, body, closure_env, closure_turn_history},
         args,
         %EvalContext{ctx: ctx, memory: memory, tool_exec: tool_exec}
       ) do
    if length(patterns) != length(args) do
      {:error, {:arity_mismatch, length(patterns), length(args)}}
    else
      result =
        Enum.zip(patterns, args)
        |> Enum.reduce_while({:ok, %{}}, fn {pattern, arg}, {:ok, acc} ->
          case match_pattern(pattern, arg) do
            {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        {:ok, bindings} ->
          new_env = Map.merge(closure_env, bindings)
          closure_ctx = EvalContext.new(ctx, memory, new_env, tool_exec, closure_turn_history)
          do_eval(body, closure_ctx)

        {:error, _} = err ->
          err
      end
    end
  end

  # Normal builtins: {:normal, fun}
  # Special handling for closures - convert them to Erlang functions
  defp apply_fun({:normal, fun}, args, %EvalContext{} = eval_ctx)
       when is_function(fun) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx) end)

    try do
      {:ok, apply(fun, converted_args), eval_ctx.memory}
    rescue
      FunctionClauseError ->
        # Provide a helpful error message for type mismatches
        {:error, type_error_for_args(fun, converted_args)}

      e in BadArityError ->
        # Extract function name and format a cleaner message
        msg = Exception.message(e)

        clean_msg =
          case Regex.run(~r/&[\w.]+\.(\w+)\/(\d+).*called with (\d+)/, msg) do
            [_, func, expected, actual] ->
              "#{func} expects #{expected} argument(s), got #{actual}"

            _ ->
              msg
          end

        {:error, {:arity_error, clean_msg}}

      e in RuntimeError ->
        # Catch errors from closure evaluation (destructuring, arity, eval errors)
        {:error, {:type_error, Exception.message(e), converted_args}}

      e in BadFunctionError ->
        # Catch attempts to use non-functions as functions (e.g., :keyword passed to map)
        {:error, {:type_error, Exception.message(e), converted_args}}
    end
  end

  # Special handling for unary minus: (- x) means negation, not (identity - x)
  defp apply_fun({:variadic, fun2, _identity}, [x], %EvalContext{memory: memory}) do
    if fun2 == (&Kernel.-/2) do
      {:ok, -x, memory}
    else
      # For other variadic functions like *, single arg returns the arg itself
      {:ok, x, memory}
    end
  rescue
    ArithmeticError ->
      {:error, {:type_error, "expected number, got #{describe_type(x)}", x}}
  end

  # Variadic builtins: {:variadic, fun2, identity}
  defp apply_fun({:variadic, fun2, identity}, args, %EvalContext{memory: memory})
       when is_function(fun2, 2) do
    result =
      case args do
        [] -> identity
        [x] -> x
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result, memory}
  rescue
    ArithmeticError ->
      # Distinguish between type errors (nil/non-number) and arithmetic errors (e.g., overflow)
      if Enum.all?(args, &is_number/1) do
        {:error, {:arithmetic_error, "bad argument in arithmetic expression"}}
      else
        {:error, type_error_for_args(fun2, args)}
      end
  end

  # Variadic requiring at least one arg: {:variadic_nonempty, fun2}
  defp apply_fun({:variadic_nonempty, _fun2}, [], %EvalContext{}) do
    {:error, {:arity_error, "requires at least 1 argument"}}
  end

  defp apply_fun({:variadic_nonempty, fun2}, args, %EvalContext{memory: memory})
       when is_function(fun2, 2) do
    result =
      case args do
        [x] -> x
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result, memory}
  rescue
    ArithmeticError ->
      # Distinguish between type errors (nil/non-number) and arithmetic errors
      if Enum.all?(args, &is_number/1) do
        # Check for division by zero specifically
        msg =
          if fun2 == (&Kernel.//2) and Enum.any?(tl(args), &(&1 == 0)) do
            "division by zero"
          else
            "bad argument in arithmetic expression"
          end

        {:error, {:arithmetic_error, msg}}
      else
        {:error, type_error_for_args(fun2, args)}
      end
  end

  # Multi-arity builtins: select function based on argument count
  # Tuple {fun2, fun3} means index 0 = arity 2, index 1 = arity 3, etc.
  defp apply_fun({:multi_arity, funs}, args, %EvalContext{} = eval_ctx)
       when is_tuple(funs) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx) end)

    arity = length(args)

    # Determine min_arity from first function in tuple
    min_arity = :erlang.fun_info(elem(funs, 0), :arity) |> elem(1)
    idx = arity - min_arity

    if idx >= 0 and idx < tuple_size(funs) do
      fun = elem(funs, idx)

      try do
        {:ok, apply(fun, converted_args), eval_ctx.memory}
      rescue
        FunctionClauseError ->
          # Provide a helpful error message for type mismatches
          {:error, type_error_for_args(fun, converted_args)}

        e in RuntimeError ->
          # Catch errors from closure evaluation (destructuring, arity, eval errors)
          {:error, {:type_error, Exception.message(e), converted_args}}
      end
    else
      arities = Enum.map(0..(tuple_size(funs) - 1), fn i -> i + min_arity end)
      {:error, {:arity_error, "expected arity #{inspect(arities)}, got #{arity}"}}
    end
  end

  # Plain function value (from user code or closures that escape)
  defp apply_fun(fun, args, %EvalContext{memory: memory}) when is_function(fun) do
    {:ok, apply(fun, args), memory}
  end

  # Fallback: not callable
  defp apply_fun(other, _args, %EvalContext{}) do
    {:error, {:not_callable, other}}
  end

  # ============================================================
  # Helper Functions
  # ============================================================

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  defp build_field_accessor({:field, segments}) do
    path =
      Enum.map(segments, fn
        {:keyword, k} -> k
        {:string, s} -> s
      end)

    fn row -> flex_get_in(row, path) end
  end

  defp build_where_predicate(:truthy, accessor, _value),
    do: fn row -> truthy?(accessor.(row)) end

  defp build_where_predicate(:eq, accessor, value),
    do: fn row -> safe_eq(accessor.(row), value) end

  defp build_where_predicate(:not_eq, accessor, value),
    do: fn row -> not safe_eq(accessor.(row), value) end

  defp build_where_predicate(:gt, accessor, value),
    do: fn row -> safe_cmp(accessor.(row), value, :>) end

  defp build_where_predicate(:lt, accessor, value),
    do: fn row -> safe_cmp(accessor.(row), value, :<) end

  defp build_where_predicate(:gte, accessor, value),
    do: fn row -> safe_cmp(accessor.(row), value, :>=) end

  defp build_where_predicate(:lte, accessor, value),
    do: fn row -> safe_cmp(accessor.(row), value, :<=) end

  defp build_where_predicate(:includes, accessor, value),
    do: fn row -> safe_includes(accessor.(row), value) end

  defp build_where_predicate(:in, accessor, value),
    do: fn row -> safe_in(accessor.(row), value) end

  defp build_pred_combinator(:all_of, []), do: fn _row -> true end
  defp build_pred_combinator(:any_of, []), do: fn _row -> false end
  defp build_pred_combinator(:none_of, []), do: fn _row -> true end

  defp build_pred_combinator(:all_of, fns),
    do: fn row -> Enum.all?(fns, & &1.(row)) end

  defp build_pred_combinator(:any_of, fns),
    do: fn row -> Enum.any?(fns, & &1.(row)) end

  defp build_pred_combinator(:none_of, fns),
    do: fn row -> not Enum.any?(fns, & &1.(row)) end

  # Build juxt function that applies all functions and returns vector of results
  defp build_juxt_fn(fns), do: fn arg -> Enum.map(fns, & &1.(arg)) end

  # Convert a value to an Erlang function for use in juxt
  # Keywords need special handling as map accessors
  defp juxt_fn_to_erlang(k, %EvalContext{}) when is_atom(k) and not is_boolean(k) do
    fn m -> flex_get(m, k) end
  end

  defp juxt_fn_to_erlang(value, %EvalContext{} = eval_ctx) do
    closure_to_fun(value, eval_ctx)
  end

  # Nil-safe comparison helpers
  defp safe_eq(nil, nil), do: true
  defp safe_eq(nil, _), do: false
  defp safe_eq(_, nil), do: false

  defp safe_eq(a, b) do
    a_normalized = normalize_for_comparison(a)
    b_normalized = normalize_for_comparison(b)
    a_normalized == b_normalized
  end

  defp safe_cmp(nil, _, _op), do: false
  defp safe_cmp(_, nil, _op), do: false
  defp safe_cmp(a, b, :>), do: a > b
  defp safe_cmp(a, b, :<), do: a < b
  defp safe_cmp(a, b, :>=), do: a >= b
  defp safe_cmp(a, b, :<=), do: a <= b

  # `in` operator: field value is member of collection
  defp safe_in(nil, _coll), do: false

  defp safe_in(value, coll) when is_list(coll) do
    normalized_value = normalize_for_comparison(value)

    Enum.any?(coll, fn item ->
      normalize_for_comparison(item) == normalized_value
    end)
  end

  defp safe_in(_, _), do: false

  # `includes` operator: collection includes value
  defp safe_includes(nil, _value), do: false

  defp safe_includes(coll, value) when is_list(coll) do
    normalized_value = normalize_for_comparison(value)

    Enum.any?(coll, fn item ->
      normalize_for_comparison(item) == normalized_value
    end)
  end

  defp safe_includes(coll, value) when is_binary(coll) and is_binary(value) do
    String.contains?(coll, value)
  end

  defp safe_includes(_, _), do: false

  # Coerce keywords to strings for comparison, but preserve other types
  # This allows LLM-generated keywords to match string data values
  defp normalize_for_comparison(value) when is_atom(value) and not is_boolean(value) do
    to_string(value)
  end

  defp normalize_for_comparison(value), do: value

  # Convert Lisp closures to Erlang functions for use with higher-order functions
  # Creates functions with appropriate arity based on number of patterns
  # Handles 5-tuple closure format: {:closure, patterns, body, closure_env, turn_history}
  defp closure_to_fun(
         {:closure, patterns, body, closure_env, closure_turn_history},
         %EvalContext{} = eval_context
       ) do
    case length(patterns) do
      0 ->
        fn ->
          eval_closure_args(
            [],
            patterns,
            body,
            closure_env,
            eval_context,
            closure_turn_history
          )
        end

      1 ->
        fn arg1 ->
          eval_closure_args(
            [arg1],
            patterns,
            body,
            closure_env,
            eval_context,
            closure_turn_history
          )
        end

      2 ->
        fn arg1, arg2 ->
          eval_closure_args(
            [arg1, arg2],
            patterns,
            body,
            closure_env,
            eval_context,
            closure_turn_history
          )
        end

      3 ->
        fn arg1, arg2, arg3 ->
          eval_closure_args(
            [arg1, arg2, arg3],
            patterns,
            body,
            closure_env,
            eval_context,
            closure_turn_history
          )
        end

      n ->
        raise RuntimeError, "closures with more than 3 parameters not supported (got #{n})"
    end
  end

  # Unwrap builtin function tuples so they can be passed to higher-order functions
  defp closure_to_fun({:normal, fun}, %EvalContext{})
       when is_function(fun) do
    fun
  end

  defp closure_to_fun({:variadic, fun, _identity}, %EvalContext{})
       when is_function(fun) do
    fun
  end

  defp closure_to_fun({:variadic_nonempty, fun}, %EvalContext{})
       when is_function(fun) do
    fun
  end

  # Non-closures pass through unchanged
  defp closure_to_fun(value, %EvalContext{}) do
    value
  end

  # Helper to evaluate closure with multiple arguments.
  # This function is used inside Erlang functions passed to builtins like Enum.map/reduce,
  # so it must raise (not return error tuples) to signal errors.
  # The raised RuntimeError is caught in apply_fun and converted to an error tuple.
  defp eval_closure_args(
         args,
         patterns,
         body,
         closure_env,
         %EvalContext{} = eval_context,
         closure_turn_history
       ) do
    if length(args) != length(patterns) do
      raise RuntimeError,
            "closure arity mismatch: expected #{length(patterns)}, got #{length(args)}"
    end

    # Match each argument against its corresponding pattern
    bindings =
      Enum.zip(patterns, args)
      |> Enum.reduce(%{}, fn {pattern, arg}, acc ->
        case match_pattern(pattern, arg) do
          {:ok, bindings} ->
            Map.merge(acc, bindings)

          {:error, {:destructure_error, reason}} ->
            raise RuntimeError, "destructure error: #{reason}"
        end
      end)

    new_env = Map.merge(closure_env, bindings)

    eval_ctx =
      EvalContext.new(
        eval_context.ctx,
        eval_context.memory,
        new_env,
        eval_context.tool_exec,
        closure_turn_history
      )

    case do_eval(body, eval_ctx) do
      {:ok, result, _} -> result
      {:error, reason} -> raise RuntimeError, format_closure_error(reason)
    end
  end

  # Generate type error for FunctionClauseError in builtins
  defp type_error_for_args(fun, args) do
    fun_name = function_name(fun)
    type_descriptions = Enum.map(args, &describe_type/1)

    case {fun_name, args} do
      # Sequence functions that don't support sets
      {name, [_, %MapSet{}]}
      when name in [:take, :drop, :sort_by, :pluck] ->
        {:type_error, "#{name} does not support sets (sets are unordered)", hd(tl(args))}

      {name, [_, %MapSet{}]}
      when name in [:take_while, :drop_while] ->
        {:type_error, "#{name} does not support sets (sets are unordered)", hd(tl(args))}

      {name, [%MapSet{}]}
      when name in [:first, :last, :nth, :reverse, :distinct, :flatten, :sort] ->
        {:type_error, "#{name} does not support sets (sets are unordered)", hd(args)}

      # update_vals with swapped arguments (function, map) instead of (map, function)
      {:update_vals, [f, m]} when is_function(f) and is_map(m) ->
        {:type_error,
         "update-vals expects (map, function) but got (function, map). " <>
           "Use -> (thread-first) instead of ->> (thread-last) with update-vals", args}

      _ ->
        {:type_error, "invalid argument types: #{Enum.join(type_descriptions, ", ")}", args}
    end
  end

  defp function_name(fun) when is_function(fun) do
    case Function.info(fun, :name) do
      {:name, name} -> name
      _ -> :unknown
    end
  end

  defp describe_type(nil), do: "nil"
  defp describe_type(%MapSet{}), do: "set"
  defp describe_type(x) when is_list(x), do: "list"
  defp describe_type(x) when is_map(x), do: "map"
  defp describe_type(x) when is_binary(x), do: "string"
  defp describe_type(x) when is_number(x), do: "number"
  defp describe_type(x) when is_boolean(x), do: "boolean"
  defp describe_type(x) when is_atom(x), do: "keyword"
  defp describe_type(x) when is_function(x), do: "function"
  defp describe_type(_), do: "unknown"

  # Format closure errors with helpful messages
  defp format_closure_error({:unbound_var, name}) do
    var_str = to_string(name)

    # Check for common underscore/hyphen confusion
    if String.contains?(var_str, "_") do
      suggested = String.replace(var_str, "_", "-")
      "Undefined variable: #{var_str}. Hint: Use hyphens not underscores (try: #{suggested})"
    else
      "Undefined variable: #{var_str}"
    end
  end

  defp format_closure_error(reason), do: "closure error: #{inspect(reason)}"
end
