defmodule PtcRunner.Lisp.Eval do
  @moduledoc """
  Evaluates CoreAST into values.

  The eval layer recursively interprets CoreAST nodes, resolving variables
  from lexical environments, applying builtins and user functions, and
  handling control flow.
  """

  alias PtcRunner.Lisp.CoreAST

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
          | {:closure, [CoreAST.pattern()], CoreAST.t(), env()}

  @type runtime_error ::
          {:unbound_var, atom()}
          | {:not_callable, term()}
          | {:arity_mismatch, expected :: integer(), got :: integer()}
          | {:type_error, expected :: String.t(), got :: term()}
          | {:tool_error, tool_name :: String.t(), reason :: term()}
          | {:invalid_keyword_call, atom(), [term()]}
          | {:arity_error, String.t()}
          | {:destructure_error, String.t()}

  @spec eval(CoreAST.t(), map(), map(), env(), tool_executor()) ::
          {:ok, value(), map()} | {:error, runtime_error()}
  def eval(ast, ctx, memory, env, tool_executor) do
    do_eval(ast, ctx, memory, env, tool_executor)
  end

  # ============================================================
  # Literals
  # ============================================================

  defp do_eval(nil, _ctx, memory, _env, _tool_exec), do: {:ok, nil, memory}
  defp do_eval(true, _ctx, memory, _env, _tool_exec), do: {:ok, true, memory}
  defp do_eval(false, _ctx, memory, _env, _tool_exec), do: {:ok, false, memory}
  defp do_eval(n, _ctx, memory, _env, _tool_exec) when is_number(n), do: {:ok, n, memory}
  defp do_eval({:string, s}, _ctx, memory, _env, _tool_exec), do: {:ok, s, memory}
  defp do_eval({:keyword, k}, _ctx, memory, _env, _tool_exec), do: {:ok, k, memory}

  # ============================================================
  # Collections
  # ============================================================

  # Vectors: evaluate all elements
  defp do_eval({:vector, elems}, ctx, memory, env, tool_exec) do
    result =
      Enum.reduce_while(elems, {:ok, [], memory}, fn elem, {:ok, acc, mem} ->
        case do_eval(elem, ctx, mem, env, tool_exec) do
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
  defp do_eval({:map, pairs}, ctx, memory, env, tool_exec) do
    result =
      Enum.reduce_while(pairs, {:ok, [], memory}, fn {k_ast, v_ast}, {:ok, acc, mem} ->
        eval_map_pair(k_ast, v_ast, ctx, mem, env, tool_exec, acc)
      end)

    case result do
      {:ok, evaluated_pairs, memory2} -> {:ok, Map.new(evaluated_pairs), memory2}
      {:error, _} = err -> err
    end
  end

  # Sets: evaluate all elements, then create MapSet
  defp do_eval({:set, elems}, ctx, memory, env, tool_exec) do
    result =
      Enum.reduce_while(elems, {:ok, [], memory}, fn elem, {:ok, acc, mem} ->
        case do_eval(elem, ctx, mem, env, tool_exec) do
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
  defp do_eval({:var, name}, _ctx, memory, env, _tool_exec) do
    case Map.fetch(env, name) do
      {:ok, value} -> {:ok, value, memory}
      :error -> {:error, {:unbound_var, name}}
    end
  end

  # Context access: ctx/input → ctx[:input]
  defp do_eval({:ctx, key}, ctx, memory, _env, _tool_exec) do
    {:ok, flex_get(ctx, key), memory}
  end

  # Memory access: memory/results → memory[:results]
  defp do_eval({:memory, key}, _ctx, memory, _env, _tool_exec) do
    {:ok, flex_get(memory, key), memory}
  end

  # Short-circuit logic: and
  defp do_eval({:and, exprs}, ctx, memory, env, tool_exec) do
    do_eval_and(exprs, ctx, memory, env, tool_exec)
  end

  # Short-circuit logic: or
  defp do_eval({:or, exprs}, ctx, memory, env, tool_exec) do
    do_eval_or(exprs, ctx, memory, env, tool_exec)
  end

  # Conditional: if
  defp do_eval({:if, cond_ast, then_ast, else_ast}, ctx, memory, env, tool_exec) do
    with {:ok, cond_val, memory2} <- do_eval(cond_ast, ctx, memory, env, tool_exec) do
      if truthy?(cond_val) do
        do_eval(then_ast, ctx, memory2, env, tool_exec)
      else
        do_eval(else_ast, ctx, memory2, env, tool_exec)
      end
    end
  end

  # Let bindings
  defp do_eval({:let, bindings, body}, ctx, memory, env, tool_exec) do
    result =
      Enum.reduce_while(bindings, {:ok, env, memory}, fn {:binding, pattern, value_ast},
                                                         {:ok, acc_env, acc_mem} ->
        case do_eval(value_ast, ctx, acc_mem, acc_env, tool_exec) do
          {:ok, value, mem2} ->
            new_bindings = match_pattern(pattern, value)
            {:cont, {:ok, Map.merge(acc_env, new_bindings), mem2}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    case result do
      {:ok, new_env, memory2} -> do_eval(body, ctx, memory2, new_env, tool_exec)
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Function definition: fn
  # ============================================================

  defp do_eval({:fn, params, body}, _ctx, memory, env, _tool_exec) do
    # Closures now store patterns directly instead of just param names
    # This enables destructuring patterns in function parameters (Phase 2)
    # Capture the current environment (lexical scoping)
    {:ok, {:closure, params, body, env}, memory}
  end

  # ============================================================
  # Function calls
  # ============================================================

  defp do_eval({:call, fun_ast, arg_asts}, ctx, memory, env, tool_exec) do
    with {:ok, fun_val, memory1} <- do_eval(fun_ast, ctx, memory, env, tool_exec) do
      result =
        Enum.reduce_while(arg_asts, {:ok, [], memory1}, fn arg_ast, {:ok, acc, mem} ->
          case do_eval(arg_ast, ctx, mem, env, tool_exec) do
            {:ok, v, mem2} -> {:cont, {:ok, [v | acc], mem2}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        {:ok, arg_vals, memory2} ->
          apply_fun(fun_val, Enum.reverse(arg_vals), ctx, memory2, tool_exec)

        {:error, _} = err ->
          err
      end
    end
  end

  # ============================================================
  # Where predicates
  # ============================================================

  defp do_eval({:where, field_path, op, value_ast}, ctx, memory, env, tool_exec) do
    # Evaluate the comparison value (if not truthy check)
    case value_ast do
      nil ->
        accessor = build_field_accessor(field_path)
        fun = build_where_predicate(op, accessor, nil)
        {:ok, fun, memory}

      _ ->
        with {:ok, value, memory2} <- do_eval(value_ast, ctx, memory, env, tool_exec) do
          accessor = build_field_accessor(field_path)
          fun = build_where_predicate(op, accessor, value)
          {:ok, fun, memory2}
        end
    end
  end

  # ============================================================
  # Predicate combinators
  # ============================================================

  defp do_eval({:pred_combinator, kind, pred_asts}, ctx, memory, env, tool_exec) do
    result =
      Enum.reduce_while(pred_asts, {:ok, [], memory}, fn p_ast, {:ok, acc, mem} ->
        case do_eval(p_ast, ctx, mem, env, tool_exec) do
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

  # Tool calls
  defp do_eval({:call_tool, tool_name, args_ast}, ctx, memory, env, tool_exec) do
    with {:ok, args_map, memory2} <- do_eval(args_ast, ctx, memory, env, tool_exec) do
      # Call the tool executor provided by the host
      result = tool_exec.(tool_name, args_map)
      {:ok, result, memory2}
    end
  end

  # ============================================================
  # Evaluation helpers
  # ============================================================

  # Helper for map pair evaluation to reduce nesting
  defp eval_map_pair(k_ast, v_ast, ctx, mem, env, tool_exec, acc) do
    with {:ok, k, mem2} <- do_eval(k_ast, ctx, mem, env, tool_exec),
         {:ok, v, mem3} <- do_eval(v_ast, ctx, mem2, env, tool_exec) do
      {:cont, {:ok, [{k, v} | acc], mem3}}
    else
      {:error, _} = err -> {:halt, err}
    end
  end

  # ============================================================
  # Short-circuit logic helpers
  # ============================================================

  defp do_eval_and([], _ctx, memory, _env, _tool_exec), do: {:ok, true, memory}

  defp do_eval_and([e | rest], ctx, memory, env, tool_exec) do
    with {:ok, value, memory2} <- do_eval(e, ctx, memory, env, tool_exec) do
      if truthy?(value) do
        do_eval_and(rest, ctx, memory2, env, tool_exec)
      else
        # Short-circuit: return falsy value
        {:ok, value, memory2}
      end
    end
  end

  defp do_eval_or([], _ctx, memory, _env, _tool_exec), do: {:ok, nil, memory}

  defp do_eval_or([e | rest], ctx, memory, env, tool_exec) do
    with {:ok, value, memory2} <- do_eval(e, ctx, memory, env, tool_exec) do
      if truthy?(value) do
        # Short-circuit: return truthy value
        {:ok, value, memory2}
      else
        do_eval_or(rest, ctx, memory2, env, tool_exec)
      end
    end
  end

  # ============================================================
  # Pattern Matching for Let Bindings
  # ============================================================

  defp match_pattern({:var, name}, value) do
    %{name => value}
  end

  defp match_pattern({:destructure, {:keys, keys, defaults}}, value) when is_map(value) do
    Enum.reduce(keys, %{}, fn key, acc ->
      default = Keyword.get(defaults, key)

      val =
        case flex_fetch(value, key) do
          {:ok, v} -> v
          :error -> default
        end

      Map.put(acc, key, val)
    end)
  end

  defp match_pattern({:destructure, {:keys, _keys, _defaults}}, value) do
    raise "destructure error: expected map, got #{inspect(value)}"
  end

  defp match_pattern({:destructure, {:seq, patterns}}, value) when is_list(value) do
    if length(value) < length(patterns) do
      raise "destructure error: expected at least #{length(patterns)} elements, got #{length(value)}"
    end

    patterns
    |> Enum.zip(value)
    |> Enum.reduce(%{}, fn {pattern, val}, acc ->
      Map.merge(acc, match_pattern(pattern, val))
    end)
  end

  defp match_pattern({:destructure, {:seq, _}}, value) do
    raise "destructure error: expected list, got #{inspect(value)}"
  end

  defp match_pattern({:destructure, {:as, as_name, inner_pattern}}, value) do
    inner_bindings = match_pattern(inner_pattern, value)
    Map.put(inner_bindings, as_name, value)
  end

  # ============================================================
  # Function Application Dispatch
  # ============================================================

  # Keyword as function: (:key map) → Map.get(map, :key)
  defp apply_fun(k, args, _ctx, memory, _tool_exec) when is_atom(k) do
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

  # Closure application
  defp apply_fun({:closure, patterns, body, closure_env}, args, ctx, memory, tool_exec) do
    if length(patterns) != length(args) do
      {:error, {:arity_mismatch, length(patterns), length(args)}}
    else
      try do
        bindings =
          Enum.zip(patterns, args)
          |> Enum.reduce(%{}, fn {pattern, arg}, acc ->
            Map.merge(acc, match_pattern(pattern, arg))
          end)

        new_env = Map.merge(closure_env, bindings)
        do_eval(body, ctx, memory, new_env, tool_exec)
      rescue
        e in RuntimeError ->
          {:error, {:destructure_error, e.message}}
      end
    end
  end

  # Normal builtins: {:normal, fun}
  # Special handling for closures - convert them to Erlang functions
  defp apply_fun({:normal, fun}, args, ctx, memory, tool_exec) when is_function(fun) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, ctx, memory, tool_exec) end)

    try do
      {:ok, apply(fun, converted_args), memory}
    rescue
      FunctionClauseError ->
        # Provide a helpful error message for type mismatches
        {:error, type_error_for_args(fun, converted_args)}
    end
  end

  # Variadic builtins: {:variadic, fun2, identity}
  defp apply_fun({:variadic, fun2, identity}, args, _ctx, memory, _tool_exec)
       when is_function(fun2, 2) do
    result =
      case args do
        [] -> identity
        [x] -> x
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fun2)
      end

    {:ok, result, memory}
  end

  # Variadic requiring at least one arg: {:variadic_nonempty, fun2}
  defp apply_fun({:variadic_nonempty, _fun2}, [], _ctx, _memory, _tool_exec) do
    {:error, {:arity_error, "requires at least 1 argument"}}
  end

  defp apply_fun({:variadic_nonempty, fun2}, args, _ctx, memory, _tool_exec)
       when is_function(fun2, 2) do
    result =
      case args do
        [x] -> x
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fun2)
      end

    {:ok, result, memory}
  end

  # Special handling for unary minus
  defp apply_fun({:variadic, fun2, _identity}, [x], _ctx, memory, _tool_exec) do
    if fun2 == (&Kernel.-/2) do
      {:ok, -x, memory}
    else
      {:error, {:not_callable, fun2}}
    end
  end

  # Multi-arity builtins: select function based on argument count
  # Tuple {fun2, fun3} means index 0 = arity 2, index 1 = arity 3, etc.
  defp apply_fun({:multi_arity, funs}, args, ctx, memory, tool_exec) when is_tuple(funs) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, ctx, memory, tool_exec) end)
    arity = length(args)

    # Determine min_arity from first function in tuple
    min_arity = :erlang.fun_info(elem(funs, 0), :arity) |> elem(1)
    idx = arity - min_arity

    if idx >= 0 and idx < tuple_size(funs) do
      fun = elem(funs, idx)

      try do
        {:ok, apply(fun, converted_args), memory}
      rescue
        FunctionClauseError ->
          # Provide a helpful error message for type mismatches
          {:error, type_error_for_args(fun, converted_args)}
      end
    else
      arities = Enum.map(0..(tuple_size(funs) - 1), fn i -> i + min_arity end)
      {:error, {:arity_error, "expected arity #{inspect(arities)}, got #{arity}"}}
    end
  end

  # Plain function value (from user code or closures that escape)
  defp apply_fun(fun, args, _ctx, memory, _tool_exec) when is_function(fun) do
    {:ok, apply(fun, args), memory}
  end

  # Fallback: not callable
  defp apply_fun(other, _args, _ctx, _memory, _tool_exec) do
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
  # The closure must have 1 parameter (enforced at evaluation time)
  defp closure_to_fun({:closure, patterns, body, closure_env}, ctx, memory, tool_exec) do
    fn arg -> eval_closure_arg(arg, patterns, body, closure_env, ctx, memory, tool_exec) end
  end

  # Unwrap builtin function tuples so they can be passed to higher-order functions
  defp closure_to_fun({:normal, fun}, _ctx, _memory, _tool_exec) when is_function(fun) do
    fun
  end

  defp closure_to_fun({:variadic, fun, _identity}, _ctx, _memory, _tool_exec)
       when is_function(fun) do
    fun
  end

  defp closure_to_fun({:variadic_nonempty, fun}, _ctx, _memory, _tool_exec)
       when is_function(fun) do
    fun
  end

  # Non-closures pass through unchanged
  defp closure_to_fun(value, _ctx, _memory, _tool_exec) do
    value
  end

  # Helper to evaluate closure with a single argument
  defp eval_closure_arg(arg, patterns, body, closure_env, ctx, memory, tool_exec) do
    if length(patterns) != 1 do
      raise ArgumentError, "arity mismatch: expected 1, got #{length(patterns)}"
    end

    [pattern] = patterns

    try do
      bindings = match_pattern(pattern, arg)
      new_env = Map.merge(closure_env, bindings)

      case do_eval(body, ctx, memory, new_env, tool_exec) do
        {:ok, result, _} -> result
        {:error, _} = err -> raise inspect(err)
      end
    rescue
      e in RuntimeError ->
        reraise ArgumentError.exception("destructuring error: #{e.message}"), __STACKTRACE__
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

  defp describe_type(%MapSet{}), do: "set"
  defp describe_type(x) when is_list(x), do: "list"
  defp describe_type(x) when is_map(x), do: "map"
  defp describe_type(x) when is_binary(x), do: "string"
  defp describe_type(x) when is_number(x), do: "number"
  defp describe_type(x) when is_boolean(x), do: "boolean"
  defp describe_type(x) when is_atom(x), do: "keyword"
  defp describe_type(x) when is_function(x), do: "function"
  defp describe_type(nil), do: "nil"
  defp describe_type(_), do: "unknown"
end
