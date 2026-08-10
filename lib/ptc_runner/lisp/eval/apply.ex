defmodule PtcRunner.Lisp.Eval.Apply do
  @moduledoc """
  Function application dispatch for Lisp evaluation.

  Handles calling closures, keywords, maps, sets, builtins, and plain functions.

  ## Supported function types

  - Keywords as map accessors: `(:key map)` → `Map.get(map, :key)`
  - Maps as keyword accessors: `(map :key)` → `Map.get(map, :key)`
  - Sets as membership check: `(set x)` → `x` or `nil`
  - Closures: user-defined functions
  - Builtins: `{:normal, fun}`, `{:variadic, fun, identity}`, etc.
  - Plain Erlang functions
  """

  alias PtcRunner.Lisp.Env.Builtin
  alias PtcRunner.Lisp.Eval.Abort
  alias PtcRunner.Lisp.Eval.CapabilityResult
  alias PtcRunner.Lisp.Eval.Capture
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.HostContext
  alias PtcRunner.Lisp.Eval.Patterns
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Introspection
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Condition, as: JavaCondition
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Prelude.Contract
  alias PtcRunner.Lisp.PreludeClosure
  alias PtcRunner.Lisp.Runtime.Args
  alias PtcRunner.Lisp.Runtime.Math
  alias PtcRunner.Lisp.Runtime.Predicates
  alias PtcRunner.Lisp.RuntimeCallable

  @hof_callback_error :__ptc_hof_callback_error__
  alias PtcRunner.Lisp.TypeVocabulary

  import PtcRunner.Lisp.Runtime, only: [flex_get: 2, flex_fetch: 2]

  @doc """
  Applies a function value to a list of arguments.
  """
  @spec apply_fun(term(), [term()], EvalContext.t(), (term(), EvalContext.t() ->
                                                        {:ok, term(), EvalContext.t()}
                                                        | {:error, term()})) ::
          {:ok, term(), EvalContext.t()} | {:error, term()}
  def apply_fun(fun_val, args, eval_ctx, do_eval_fn) do
    do_apply_fun(fun_val, args, eval_ctx, do_eval_fn)
  end

  defp do_apply_fun(
         %Builtin{name: name, binding: {:normal, fun}} = builtin,
         args,
         %EvalContext{} = eval_ctx,
         do_eval_fn
       )
       when name in [:fnil, :complement, :constantly] and is_function(fun) do
    with :ok <- validate_builtin_args!(builtin, args, eval_ctx, do_eval_fn) do
      try do
        with_side_effect_stash(eval_ctx, do_eval_fn, fn -> apply(fun, args) end)
      rescue
        e in Abort -> reraise_hof_callback_error(e, args, __STACKTRACE__)
        FunctionClauseError -> {:error, Helpers.type_error_for_args(fun, args)}
        e in BadArityError -> {:error, {:arity_error, Exception.message(e)}}
        e in RuntimeError -> {:error, {:type_error, Exception.message(e), args}}
      end
    end
  end

  defp do_apply_fun(
         %Builtin{name: name, binding: {:collect, fun}} = builtin,
         args,
         %EvalContext{} = eval_ctx,
         do_eval_fn
       )
       when name in [:comp, :partial, :"every-pred", :"some-fn"] and is_function(fun, 1) do
    with :ok <- validate_builtin_args!(builtin, args, eval_ctx, do_eval_fn) do
      try do
        with_side_effect_stash(eval_ctx, do_eval_fn, fn -> fun.(args) end)
      rescue
        e in Abort -> reraise_hof_callback_error(e, args, __STACKTRACE__)
        FunctionClauseError -> {:error, Helpers.type_error_for_args(fun, args)}
        e in RuntimeError -> {:error, {:type_error, Exception.message(e), args}}
      end
    end
  end

  defp do_apply_fun(%Builtin{} = builtin, args, %EvalContext{} = eval_ctx, do_eval_fn) do
    with {:ok, prepared_args} <- prepare_builtin_arguments(builtin, args),
         :ok <- validate_builtin_args!(builtin, prepared_args, eval_ctx, do_eval_fn) do
      do_apply_fun(Builtin.unwrap(builtin), prepared_args, eval_ctx, do_eval_fn)
    end
  end

  defp do_apply_fun(%RuntimeCallable{} = callable, args, %EvalContext{} = eval_ctx, do_eval_fn) do
    callable
    |> RuntimeCallable.bind(eval_ctx, do_eval_fn)
    |> RuntimeCallable.invoke(args, eval_ctx)
  end

  defp do_apply_fun(
         %JavaCallable{} = callable,
         args,
         %EvalContext{} = eval_ctx,
         _do_eval_fn
       ) do
    case JavaCallable.invoke(callable, args) do
      {:ok, value, _overload_id} -> {:ok, value, eval_ctx}
      {:error, condition} -> {:error, JavaCondition.evaluator_error(condition)}
    end
  end

  # nil is not callable: (nil x), (apply nil ...), and ((comp nil) x) raise
  # rather than treating nil as a keyword accessor (GAP-S109, GAP-S135).
  defp do_apply_fun(nil, _args, %EvalContext{}, _do_eval_fn) do
    {:error, {:not_callable, nil}}
  end

  # Keyword as function: (:key map) → Map.get(map, :key)
  defp do_apply_fun(k, args, %EvalContext{} = eval_ctx, _do_eval_fn) when is_atom(k) do
    apply_keyword(k, args, eval_ctx)
  end

  defp do_apply_fun(%LispKeyword{} = k, args, %EvalContext{} = eval_ctx, _do_eval_fn) do
    apply_keyword(k, args, eval_ctx)
  end

  # Set as function: (#{1 2 3} x) → checks membership, returns element or nil
  defp do_apply_fun(set, [arg], %EvalContext{} = eval_ctx, _do_eval_fn)
       when is_struct(set, MapSet) do
    {:ok, if(MapSet.member?(set, arg), do: arg, else: nil), eval_ctx}
  end

  defp do_apply_fun(set, args, %EvalContext{}, _do_eval_fn)
       when is_struct(set, MapSet) do
    {:error, {:arity_error, "set expects 1 argument, got #{length(args)}"}}
  end

  # Closure application (6-element tuple format with turn_history and metadata)
  defp do_apply_fun(
         {:closure, patterns, _body, _env, _th, metadata} = closure,
         args,
         %EvalContext{} = eval_ctx,
         do_eval_fn
       ) do
    case check_arity(patterns, args) do
      :ok ->
        Contract.validate_input!(metadata, args, eval_ctx)
        eval_ctx = count_prelude_entry_metadata(metadata, eval_ctx)

        case execute_closure(closure, args, eval_ctx, do_eval_fn) do
          {:ok, result, final_ctx} = success ->
            Contract.validate_output!(metadata, result, final_ctx)
            success

          {:error, _} = error ->
            error
        end

      {:error, _} = err ->
        err
    end
  end

  # Special builtin: apply
  defp do_apply_fun({:special, :apply}, args, eval_ctx, do_eval_fn) do
    case args do
      [fun | rest] when rest != [] ->
        {fixed_args, [last_arg]} = Enum.split(rest, -1)

        case last_arg_to_list(last_arg) do
          {:ok, expanded_list} ->
            apply_fun(fun, fixed_args ++ expanded_list, eval_ctx, do_eval_fn)

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, {:arity_error, "apply expects at least 2 arguments, got #{length(args)}"}}
    end
  end

  # Special builtin: println
  # Detects char lists (from `(take n string)`) and joins them back into strings
  defp do_apply_fun({:special, :println}, args, eval_ctx, _do_eval_fn) do
    message =
      Enum.map_join(args, " ", fn
        s when is_binary(s) -> s
        v -> format_for_println(v)
      end)

    {:ok, nil, EvalContext.append_print(eval_ctx, message)}
  end

  # Special builtins: prelude introspection (dir/apropos/doc/export-meta).
  # `Introspection.invoke/3` owns validation and answers for this path and for
  # `Runtime.Callable`'s higher-order path alike, so the two cannot drift.
  defp do_apply_fun({:special, op}, args, eval_ctx, _do_eval_fn)
       when op in [:dir, :apropos, :doc, :export_meta] do
    case Introspection.invoke(op, args, eval_ctx) do
      {:ok, value} -> {:ok, value, eval_ctx}
      {:print, text} -> {:ok, nil, EvalContext.append_print(eval_ctx, text)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Normal builtins: {:normal, fun}
  # Special handling for closures - convert them to Erlang functions
  defp do_apply_fun({:normal, fun}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_function(fun) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)

    try do
      with_side_effect_stash(eval_ctx, do_eval_fn, fn -> apply(fun, converted_args) end)
    rescue
      e in Abort ->
        reraise_hof_callback_error(e, converted_args, __STACKTRACE__)

      FunctionClauseError ->
        # Provide a helpful error message for type mismatches
        {:error, Helpers.type_error_for_args(fun, converted_args)}

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

      e in ArithmeticError ->
        {:error, {:arithmetic_error, Exception.message(e)}}

      e in BadFunctionError ->
        # Catch attempts to use non-functions as functions (e.g., :keyword passed to map)
        {:error, {:type_error, Exception.message(e), converted_args}}
    end
  end

  # Unary variadic builtins still route through Math for validation and
  # operator-specific single-argument behavior.
  defp do_apply_fun(
         {:variadic, fun2, _identity},
         [x],
         %EvalContext{} = eval_ctx,
         _do_eval_fn
       ) do
    {:ok, Math.unary_variadic(fun2, x), eval_ctx}
  rescue
    ArithmeticError ->
      {:error, {:type_error, "expected number, got #{Helpers.describe_type(x)}", x}}
  end

  # Variadic builtins: {:variadic, fun2, identity}
  defp do_apply_fun(
         {:variadic, fun2, identity},
         args,
         %EvalContext{} = eval_ctx,
         _do_eval_fn
       )
       when is_function(fun2, 2) do
    result =
      case args do
        [] -> identity
        [x] -> Math.unary_variadic(fun2, x)
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result, eval_ctx}
  rescue
    e in Abort ->
      reraise_hof_callback_error(e, args, __STACKTRACE__)

    ArithmeticError ->
      # Distinguish between type errors (nil/non-number) and arithmetic errors (e.g., overflow)
      if Enum.all?(args, &is_number/1) do
        {:error, {:arithmetic_error, "bad argument in arithmetic expression"}}
      else
        {:error, Helpers.type_error_for_args(fun2, args)}
      end
  end

  # Variadic requiring at least one arg: {:variadic_nonempty, name, fun2}
  defp do_apply_fun({:variadic_nonempty, name, _fun2}, [], %EvalContext{}, _do_eval_fn) do
    {:error, {:arity_error, "#{name} requires at least 1 argument, got 0"}}
  end

  defp do_apply_fun(
         {:variadic_nonempty, name, fun2},
         args,
         %EvalContext{} = eval_ctx,
         _do_eval_fn
       )
       when is_function(fun2, 2) do
    result =
      case args do
        [x] -> Math.unary_variadic_nonempty(name, fun2, x)
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result, eval_ctx}
  rescue
    e in Abort ->
      reraise_hof_callback_error(e, args, __STACKTRACE__)

    e in ArithmeticError ->
      # Distinguish between type errors (nil/non-number) and arithmetic errors
      if Enum.all?(args, &is_number/1) do
        # Check for division by zero specifically. Either the inner function
        # raised with a "division by zero" message (Math.divide / Math.quot /
        # Math.remainder / Math.mod) or any divisor in the tail is integer 0.
        msg =
          cond do
            String.contains?(Exception.message(e), "division by zero") ->
              "division by zero"

            Enum.any?(tl(args), &(&1 === 0)) ->
              "division by zero"

            true ->
              "bad argument in arithmetic expression"
          end

        {:error, {:arithmetic_error, msg}}
      else
        {:error, Helpers.type_error_for_args(fun2, args)}
      end
  end

  # Collect builtins: pass all args as a list to unary function
  defp do_apply_fun({:collect, fun}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_function(fun, 1) do
    # Convert any closures/builtins in args to callable functions
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)

    try do
      with_side_effect_stash(eval_ctx, do_eval_fn, fn -> fun.(converted_args) end)
    rescue
      e in Abort ->
        reraise_hof_callback_error(e, converted_args, __STACKTRACE__)

      FunctionClauseError ->
        # A bad argument shape inside a collect builtin (e.g. (update-in [1 2]
        # [] f) routing a vector root through flex_update_in's integer-key
        # clauses) must surface as a recoverable type error, not leak the
        # internal module/function name as a raw :runtime_error. Mirrors the
        # {:normal} and {:multi_arity} handlers so all builtin dispatch shapes
        # fail consistently.
        {:error, Helpers.type_error_for_args(fun, converted_args)}
    end
  end

  # Multi-arity builtins: select function based on argument count
  # Tuple {fun2, fun3} means index 0 = arity 2, index 1 = arity 3, etc.
  defp do_apply_fun({:multi_arity, name, funs}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_atom(name) and is_tuple(funs) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)

    arity = length(args)

    # Determine min_arity from first function in tuple
    min_arity = :erlang.fun_info(elem(funs, 0), :arity) |> elem(1)
    idx = arity - min_arity

    if idx >= 0 and idx < tuple_size(funs) do
      fun = elem(funs, idx)

      try do
        with_side_effect_stash(eval_ctx, do_eval_fn, fn -> apply(fun, converted_args) end)
      rescue
        e in Abort ->
          reraise_hof_callback_error(e, converted_args, __STACKTRACE__)

        FunctionClauseError ->
          # Provide a helpful error message for type mismatches
          {:error, Helpers.type_error_for_args(fun, converted_args)}

        e in RuntimeError ->
          # Catch errors from closure evaluation (destructuring, arity, eval errors)
          {:error, {:type_error, Exception.message(e), converted_args}}
      end
    else
      arities = Enum.map(0..(tuple_size(funs) - 1), fn i -> i + min_arity end)

      {:error,
       {:arity_error, "#{name} expects #{format_arities(arities)} argument(s), got #{arity}"}}
    end
  end

  defp do_apply_fun(fun, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_function(fun) do
    with_side_effect_stash(eval_ctx, do_eval_fn, fn -> apply(fun, args) end)
  end

  defp do_apply_fun({:juxt_fn, fns}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_list(fns) do
    Enum.reduce_while(fns, {:ok, [], eval_ctx}, fn fun, {:ok, acc, ctx} ->
      case do_apply_fun(fun, args, ctx, do_eval_fn) do
        {:ok, value, next_ctx} -> {:cont, {:ok, [value | acc], next_ctx}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values, next_ctx} -> {:ok, Enum.reverse(values), next_ctx}
      {:error, _} = error -> error
    end
  end

  defp do_apply_fun({:partial_fn, f, fixed}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_list(fixed) do
    do_apply_fun(f, fixed ++ args, eval_ctx, do_eval_fn)
  end

  defp do_apply_fun({:comp_fn, []}, args, %EvalContext{} = eval_ctx, do_eval_fn) do
    do_apply_fun({:normal, &Predicates.identity/1}, args, eval_ctx, do_eval_fn)
  end

  defp do_apply_fun({:comp_fn, fns}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_list(fns) do
    [last_fn | rest] = Enum.reverse(fns)

    case do_apply_fun(last_fn, args, eval_ctx, do_eval_fn) do
      {:ok, value, next_ctx} ->
        apply_comp_rest(rest, value, next_ctx, do_eval_fn)

      {:error, _} = error ->
        error
    end
  end

  defp do_apply_fun({:complement_fn, f}, args, %EvalContext{} = eval_ctx, do_eval_fn) do
    case do_apply_fun(f, args, eval_ctx, do_eval_fn) do
      {:ok, value, next_ctx} -> {:ok, not truthy?(value), next_ctx}
      {:error, _} = error -> error
    end
  end

  defp do_apply_fun({:constantly_fn, value}, _args, %EvalContext{} = eval_ctx, _do_eval_fn),
    do: {:ok, value, eval_ctx}

  defp do_apply_fun({:every_pred_fn, preds}, vals, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_list(preds) do
    Enum.reduce_while(preds, {:ok, true, eval_ctx}, fn pred, {:ok, _acc, ctx} ->
      case every_pred_values(pred, vals, ctx, do_eval_fn) do
        {:ok, true, next_ctx} -> {:cont, {:ok, true, next_ctx}}
        {:ok, false, next_ctx} -> {:halt, {:ok, false, next_ctx}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp do_apply_fun({:some_fn, fns}, vals, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_list(fns) do
    Enum.reduce_while(fns, {:ok, nil, eval_ctx}, fn f, {:ok, last_result, ctx} ->
      case some_fn_values(f, vals, last_result, ctx, do_eval_fn) do
        {:found, result, next_ctx} -> {:halt, {:ok, result, next_ctx}}
        {:ok, result, next_ctx} -> {:cont, {:ok, result, next_ctx}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp do_apply_fun({:fnil_fn, f, default}, args, %EvalContext{} = eval_ctx, do_eval_fn) do
    do_apply_fun(f, substitute_nil(args, default), eval_ctx, do_eval_fn)
  end

  # Map as function: (map key) → Map.get(map, key)
  # Supports any key type (atoms, strings, integers, etc.) like Clojure
  defp do_apply_fun(m, args, %EvalContext{} = eval_ctx, _do_eval_fn)
       when is_map(m) and not is_struct(m) do
    case args do
      [k] ->
        {:ok, flex_get(m, k), eval_ctx}

      [k, default] ->
        case flex_fetch(m, k) do
          {:ok, val} -> {:ok, val, eval_ctx}
          :error -> {:ok, default, eval_ctx}
        end

      _ ->
        {:error, {:invalid_map_call, m, args}}
    end
  end

  # Fallback: not callable
  defp do_apply_fun(other, _args, %EvalContext{}, _do_eval_fn) do
    {:error, {:not_callable, other}}
  end

  defp prepare_builtin_arguments(%Builtin{name: name}, args) do
    case JavaPrimitive.prepare_arguments(name, args) do
      {:ok, values} -> {:ok, values}
      {:error, :invalid_java_value} -> {:error, {:invalid_java_value, :primitive}}
    end
  end

  defp apply_keyword(k, args, %EvalContext{} = eval_ctx) do
    case args do
      [m] when is_map(m) and not is_struct(m) ->
        {:ok, flex_get(m, k), eval_ctx}

      [m, default] when is_map(m) and not is_struct(m) ->
        case flex_fetch(m, k) do
          {:ok, val} -> {:ok, val, eval_ctx}
          :error -> {:ok, default, eval_ctx}
        end

      [nil] ->
        {:ok, nil, eval_ctx}

      [nil, default] ->
        {:ok, default, eval_ctx}

      # Clojure returns nil for keyword lookup on non-map types: (:key "string") → nil
      [_] ->
        {:ok, nil, eval_ctx}

      [_, default] ->
        {:ok, default, eval_ctx}

      _ ->
        {:error, {:invalid_keyword_call, k, args}}
    end
  end

  defp maybe_validate_builtin_args(%Builtin{binding: {:normal, fun}} = builtin, args) do
    if function_arity(fun) == length(args), do: validate_builtin_args(builtin, args), else: :ok
  end

  defp maybe_validate_builtin_args(%Builtin{binding: {:multi_arity, _name, funs}} = builtin, args) do
    arity = length(args)
    min_arity = function_arity(elem(funs, 0))
    idx = arity - min_arity

    if idx >= 0 and idx < tuple_size(funs), do: validate_builtin_args(builtin, args), else: :ok
  end

  defp maybe_validate_builtin_args(%Builtin{binding: {:variadic_nonempty, _name, _fun}}, []) do
    :ok
  end

  defp maybe_validate_builtin_args(%Builtin{name: :"merge-with"}, []) do
    {:error, {:arity_error, "merge-with requires at least 1 argument, got 0"}}
  end

  defp maybe_validate_builtin_args(%Builtin{} = builtin, args),
    do: validate_builtin_args(builtin, args)

  defp validate_builtin_args(builtin, args) do
    Args.validate!(builtin, args)
    :ok
  end

  defp validate_builtin_args!(builtin, args, eval_ctx, do_eval_fn) do
    HostContext.with_context(eval_ctx, do_eval_fn, fn ->
      maybe_validate_builtin_args(builtin, args)
    end)
  end

  defp function_arity(fun), do: :erlang.fun_info(fun, :arity) |> elem(1)

  defp check_arity({:variadic, leading, _rest}, args) do
    if length(args) >= length(leading) do
      :ok
    else
      {:error, {:arity_mismatch, "#{length(leading)}+", length(args)}}
    end
  end

  defp check_arity(patterns, args) when is_list(patterns) do
    if length(patterns) == length(args) do
      :ok
    else
      {:error, {:arity_mismatch, length(patterns), length(args)}}
    end
  end

  @doc """
  Converts Lisp closures to Erlang functions for use with higher-order functions.

  Creates functions with appropriate arity based on number of patterns.
  Also unwraps builtin function tuples.
  """
  @spec closure_to_fun(term(), EvalContext.t(), (term(), EvalContext.t() -> term())) :: term()
  def closure_to_fun(
        {:closure, patterns, body, closure_env, _closure_turn_history, metadata} = closure,
        %EvalContext{} = eval_context,
        do_eval_fn
      ) do
    # Self-recursion: a named fn must be visible under its own name inside
    # its body. `do_execute_closure` binds this at call time; for HOF use
    # (Enum.map etc.) we wire it directly into the captured env so the
    # var resolver finds it via the locals path (closure_locals adds
    # fn_name to locals from metadata).
    closure_env = bind_self_recursion(closure_env, metadata, closure)
    # For variadic closures, we provide wrappers for common arities (0-3)
    # as long as they satisfy the minimum arity (length of leading patterns).
    # For fixed closures, we use the exact arity.

    min_arity =
      case patterns do
        {:variadic, leading, _} -> length(leading)
        _ when is_list(patterns) -> length(patterns)
      end

    if is_list(patterns) do
      # Fixed arity closures
      case min_arity do
        0 ->
          fn ->
            eval_closure_args(
              [],
              patterns,
              body,
              closure_env,
              eval_context,
              metadata,
              do_eval_fn
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
              metadata,
              do_eval_fn
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
              metadata,
              do_eval_fn
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
              metadata,
              do_eval_fn
            )
          end

        n ->
          raise RuntimeError, "closures with more than 3 parameters not supported (got #{n})"
      end
    else
      # Variadic closures have no fixed arity, but an Erlang anonymous function
      # does, and the receiving HOF calls it at one specific arity. Since a
      # single anonymous function cannot cover several arities, we commit to the
      # narrowest one the closure accepts: 1 covers `map`-shaped callers, 2
      # covers `reduce`-shaped ones. A closure needing 3 or more has no
      # representation here and raises rather than silently mis-dispatching.
      cond do
        min_arity <= 1 ->
          fn arg1 ->
            eval_closure_args(
              [arg1],
              patterns,
              body,
              closure_env,
              eval_context,
              metadata,
              do_eval_fn
            )
          end

        min_arity == 2 ->
          fn arg1, arg2 ->
            eval_closure_args(
              [arg1, arg2],
              patterns,
              body,
              closure_env,
              eval_context,
              metadata,
              do_eval_fn
            )
          end

        true ->
          raise RuntimeError, "Variadic closures with min_arity > 2 not supported in HOFs yet"
      end
    end
  end

  # Pass through builtin function tuples so Callable.call/2 can dispatch correctly
  # This preserves variadic/identity information for proper multi-arity handling
  def closure_to_fun({:normal, _} = builtin, %EvalContext{}, _do_eval_fn), do: builtin
  def closure_to_fun({:variadic, _, _} = builtin, %EvalContext{}, _do_eval_fn), do: builtin

  def closure_to_fun({:variadic_nonempty, _, _} = builtin, %EvalContext{}, _do_eval_fn),
    do: builtin

  def closure_to_fun({:multi_arity, _, _} = builtin, %EvalContext{}, _do_eval_fn), do: builtin
  def closure_to_fun({:collect, _} = builtin, %EvalContext{}, _do_eval_fn), do: builtin
  def closure_to_fun(%Builtin{} = builtin, %EvalContext{}, _do_eval_fn), do: builtin

  def closure_to_fun(%RuntimeCallable{} = callable, %EvalContext{}, _do_eval_fn), do: callable
  def closure_to_fun(%JavaCallable{} = callable, %EvalContext{}, _do_eval_fn), do: callable

  def closure_to_fun({:juxt_fn, fns}, %EvalContext{} = eval_ctx, do_eval_fn) when is_list(fns) do
    {:juxt_fn, Enum.map(fns, &closure_to_fun(&1, eval_ctx, do_eval_fn))}
  end

  def closure_to_fun({:partial_fn, f, fixed}, %EvalContext{} = eval_ctx, do_eval_fn)
      when is_list(fixed) do
    {:partial_fn, closure_to_fun(f, eval_ctx, do_eval_fn),
     Enum.map(fixed, &closure_to_fun(&1, eval_ctx, do_eval_fn))}
  end

  def closure_to_fun({:comp_fn, fns}, %EvalContext{} = eval_ctx, do_eval_fn) when is_list(fns) do
    {:comp_fn, Enum.map(fns, &closure_to_fun(&1, eval_ctx, do_eval_fn))}
  end

  def closure_to_fun({:complement_fn, f}, %EvalContext{} = eval_ctx, do_eval_fn) do
    {:complement_fn, closure_to_fun(f, eval_ctx, do_eval_fn)}
  end

  def closure_to_fun({:constantly_fn, _value} = callable, %EvalContext{}, _do_eval_fn),
    do: callable

  def closure_to_fun({:every_pred_fn, preds}, %EvalContext{} = eval_ctx, do_eval_fn)
      when is_list(preds) do
    {:every_pred_fn, Enum.map(preds, &closure_to_fun(&1, eval_ctx, do_eval_fn))}
  end

  def closure_to_fun({:some_fn, fns}, %EvalContext{} = eval_ctx, do_eval_fn) when is_list(fns) do
    {:some_fn, Enum.map(fns, &closure_to_fun(&1, eval_ctx, do_eval_fn))}
  end

  def closure_to_fun({:fnil_fn, f, default}, %EvalContext{} = eval_ctx, do_eval_fn) do
    {:fnil_fn, closure_to_fun(f, eval_ctx, do_eval_fn),
     closure_to_fun(default, eval_ctx, do_eval_fn)}
  end

  # Special forms like println - convert to a function
  def closure_to_fun(
        {:special, :println},
        %EvalContext{} = eval_ctx,
        _do_eval_fn
      ) do
    fn arg ->
      message =
        case arg do
          s when is_binary(s) -> s
          v -> format_for_println(v)
        end

      _updated_context = EvalContext.append_print(eval_ctx, message)

      nil
    end
  end

  # Introspection specials are deliberately NOT converted to BEAM functions
  # here. `Runtime.Callable.call/2` dispatches them from the argument list, so
  # the tuple keeps both of `dir`'s arities — a unary wrapper would make
  # `(let [f (identity dir)] (f))` fail an arity that `(dir)` accepts — and it
  # resolves its visibility filter from the context it RUNS under. Capturing
  # the converting context would let a privileged prelude export hand
  # session-authored code the prelude's unrestricted view under
  # `strict_transitive_calls`.

  # Non-closures pass through unchanged
  def closure_to_fun(value, %EvalContext{}, _do_eval_fn) do
    value
  end

  # ============================================================
  # Internal Helpers
  # ============================================================

  # Detect char lists (result of `(take n string)`) and join them for readable output
  defp format_for_println(list) when is_list(list) do
    if char_list?(list) do
      Enum.join(list)
    else
      Format.to_clojure(list) |> elem(0)
    end
  end

  defp format_for_println(v), do: Format.to_clojure(v) |> elem(0)

  defp apply_comp_rest(rest, value, %EvalContext{} = eval_ctx, do_eval_fn) do
    Enum.reduce_while(rest, {:ok, value, eval_ctx}, fn f, {:ok, acc, ctx} ->
      case do_apply_fun(f, [acc], ctx, do_eval_fn) do
        {:ok, value, next_ctx} -> {:cont, {:ok, value, next_ctx}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp substitute_nil([nil | rest], default), do: [default | rest]
  defp substitute_nil(args, _default), do: args

  defp every_pred_values(_pred, [], %EvalContext{} = eval_ctx, _do_eval_fn),
    do: {:ok, true, eval_ctx}

  defp every_pred_values(pred, [value | rest], %EvalContext{} = eval_ctx, do_eval_fn) do
    case do_apply_fun(pred, [value], eval_ctx, do_eval_fn) do
      {:ok, result, next_ctx} ->
        if truthy?(result) do
          every_pred_values(pred, rest, next_ctx, do_eval_fn)
        else
          {:ok, false, next_ctx}
        end

      {:error, _} = error ->
        error
    end
  end

  defp some_fn_values(_f, [], last_result, %EvalContext{} = eval_ctx, _do_eval_fn),
    do: {:ok, last_result, eval_ctx}

  defp some_fn_values(f, [value | rest], _last_result, %EvalContext{} = eval_ctx, do_eval_fn) do
    case do_apply_fun(f, [value], eval_ctx, do_eval_fn) do
      {:ok, result, next_ctx} ->
        if truthy?(result) do
          {:found, result, next_ctx}
        else
          some_fn_values(f, rest, result, next_ctx, do_eval_fn)
        end

      {:error, _} = error ->
        error
    end
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  # A char list is a list where all elements are single-character strings
  defp char_list?([]), do: false

  defp char_list?(list) do
    Enum.all?(list, fn
      s when is_binary(s) -> String.length(s) == 1
      _ -> false
    end)
  end

  defp last_arg_to_list(nil),
    do: {:error, {:type_error, "apply expects collection as last argument, got nil", nil}}

  defp last_arg_to_list(list) when is_list(list), do: {:ok, list}
  defp last_arg_to_list(%MapSet{} = s), do: {:ok, MapSet.to_list(s)}

  defp last_arg_to_list(m) when is_map(m) and not is_struct(m) do
    # Convert map to [key, value] pairs per Clojure seqable semantics
    {:ok, Enum.map(m, fn {k, v} -> [k, v] end)}
  end

  defp last_arg_to_list(other),
    do:
      {:error,
       {:type_error,
        "apply expects collection as last argument, got #{Helpers.describe_type(other)}", other}}

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
         metadata,
         do_eval_fn
       ) do
    eval_context = Capture.materialize_context(eval_context)
    caller_baseline = eval_context

    case check_arity(patterns, args) do
      :ok ->
        :ok

      {:error, {:arity_mismatch, expected, actual}} ->
        raise RuntimeError, "closure arity mismatch: expected #{expected}, got #{actual}"
    end

    Contract.validate_input!(metadata, args, eval_context)
    eval_context = count_prelude_entry_metadata(metadata, eval_context)

    # Match each argument against its corresponding pattern
    bindings =
      case bind_args(patterns, args) do
        {:ok, bindings} ->
          bindings

        {:error, {:destructure_error, reason}} ->
          raise RuntimeError, "destructure error: #{reason}"
      end

    new_env = Map.merge(closure_env, bindings)

    # A prelude-export closure used as a HOF value runs against its private
    # prelude env (resolved from the attached prelude by namespace name); the HOF
    # path returns a value, not a context, so any `(def ...)` writes the isolated
    # env and is discarded.
    prelude_ns = prelude_ns_tag(metadata)
    prelude_origin = prelude_error_origin(metadata)

    closure_user_ns =
      case prelude_ns do
        nil -> EvalContext.current_prelude_caller_user_ns(eval_context) || eval_context.user_ns
        ns -> prelude_ns_env(eval_context.prelude, ns)
      end

    eval_ctx =
      EvalContext.new(
        eval_context.ctx,
        closure_user_ns,
        new_env,
        eval_context.tool_exec,
        eval_context.turn_history,
        max_print_length: eval_context.max_print_length,
        pmap_timeout: eval_context.pmap_timeout,
        pmap_max_concurrency: eval_context.pmap_max_concurrency,
        # Security H1: propagate the sandbox cap, the FIXED per-worker
        # heap cap, and the shared worker-slot budget so a nested
        # pmap/pcalls invoked from inside this closure caps and counts
        # its workers against the same global budget.
        max_heap: eval_context.max_heap,
        worker_max_heap: eval_context.worker_max_heap,
        parallel_budget: eval_context.parallel_budget,
        max_tool_call_result_bytes: eval_context.max_tool_call_result_bytes,
        tools_meta: eval_context.tools_meta
      )

    eval_ctx =
      %{
        eval_ctx
        | locals: closure_locals(metadata, bindings),
          effects: eval_context.effects,
          # Security H1: propagate the shared parallel deadline so a
          # nested pmap/pcalls inside this closure inherits it.
          pmap_deadline: eval_context.pmap_deadline
      }
      |> EvalContext.inherit_prelude(eval_context)
      |> maybe_push_prelude_origin(metadata, eval_context)
      |> Capture.materialize_context()

    # A `(return …)`/`(fail …)` inside a value-position closure throws the
    # callback context. Catch it at the HOF boundary where the closure metadata
    # is still in scope and restore the caller's lexical/namespace/authority
    # scope before it propagates. Prelude exports additionally tag returned
    # closures and sanitize private errors.
    try do
      case do_eval_fn.(body, eval_ctx) do
        {:ok, result, final_ctx} ->
          contract_ctx = restore_hof_caller(final_ctx, caller_baseline)
          Contract.validate_output!(metadata, result, contract_ctx)
          # Tag a returned closure so its private-helper references still resolve
          # when the HOF result is applied later.
          PreludeClosure.tag_namespace(result, prelude_ns)

        {:error, reason} ->
          raise_closure_error(maybe_sanitize_private_error(reason, prelude_ns, prelude_origin))
      end
    rescue
      error in Abort ->
        callback = %{
          patterns: patterns,
          body: body,
          closure_env: closure_env,
          metadata: metadata,
          do_eval_fn: do_eval_fn
        }

        handle_hof_abort(
          error,
          {prelude_ns, prelude_origin},
          caller_baseline,
          callback,
          __STACKTRACE__
        )
    end
  end

  defp handle_hof_abort(
         %Abort{outcome: {:control, :return, value, %EvalContext{} = abort_ctx}},
         {prelude_ns, _prelude_origin},
         caller_baseline,
         %{metadata: metadata},
         _stacktrace
       ) do
    restored_ctx =
      abort_ctx
      |> restore_hof_caller(caller_baseline)
      |> Capture.materialize_context()

    value = PreludeClosure.tag_namespace(value, prelude_ns)

    if prelude_ns do
      Contract.validate_output!(metadata, value, restored_ctx)
    end

    Abort.control!(:return, value, restored_ctx)
  end

  defp handle_hof_abort(
         %Abort{outcome: {:control, :fail, value, %EvalContext{} = abort_ctx}},
         _prelude_ns,
         caller_baseline,
         _callback,
         _stacktrace
       ) do
    restored_ctx =
      abort_ctx
      |> restore_hof_caller(caller_baseline)
      |> Capture.materialize_context()

    Abort.control!(:fail, value, restored_ctx)
  end

  defp handle_hof_abort(
         %Abort{outcome: {:control, :recur, new_args, %EvalContext{} = abort_ctx}},
         _prelude_ns,
         caller_baseline,
         %{
           patterns: patterns,
           body: body,
           closure_env: closure_env,
           metadata: metadata,
           do_eval_fn: do_eval_fn
         },
         _stacktrace
       ) do
    recur_hof_closure(
      new_args,
      abort_ctx.effects,
      patterns,
      body,
      closure_env,
      caller_baseline,
      metadata,
      do_eval_fn
    )
  end

  defp handle_hof_abort(
         %Abort{outcome: {:error, reason, %EvalContext{} = abort_ctx}},
         {prelude_ns, prelude_origin},
         caller_baseline,
         _callback,
         _stacktrace
       ) do
    restored_ctx = restore_hof_caller(abort_ctx, caller_baseline)
    reason = maybe_sanitize_private_error(reason, prelude_ns, prelude_origin)

    if passthrough_hof_error?(reason) do
      Abort.error!(reason, restored_ctx)
    else
      Abort.error!({@hof_callback_error, Helpers.format_closure_error(reason)}, restored_ctx)
    end
  end

  defp handle_hof_abort(%Abort{} = error, _ns, _context, _callback, stacktrace),
    do: reraise(error, stacktrace)

  defp passthrough_hof_error?(reason) do
    case reason do
      {kind, _detail} -> kind in passthrough_hof_error_kinds()
      {kind, _detail, _data} -> kind in passthrough_hof_error_kinds()
      {kind, _index, _detail, _data} -> kind in passthrough_hof_error_kinds()
      _other -> false
    end
  end

  defp passthrough_hof_error_kinds do
    [
      @hof_callback_error,
      :tool_error,
      :type_error,
      :unknown_tool,
      :invalid_tool_args,
      :private_tool_unauthorized,
      :private_tool_args_error,
      :prelude_contract_error,
      :pmap_error,
      :pcalls_error,
      :memory_exceeded,
      :timeout,
      :parallel_capacity_exceeded,
      :loop_limit_exceeded,
      :tool_call_limit_exceeded
    ]
  end

  defp recur_hof_closure(
         new_args,
         effects,
         patterns,
         body,
         closure_env,
         %EvalContext{} = caller_ctx,
         metadata,
         do_eval_fn
       ) do
    recur_patterns =
      case patterns do
        {:variadic, leading, rest} -> leading ++ [rest]
        fixed -> fixed
      end

    case check_arity(recur_patterns, new_args) do
      :ok ->
        case EvalContext.increment_iteration(caller_ctx) do
          {:ok, next_ctx} ->
            next_ctx = EvalContext.restore_recur_effects(next_ctx, effects)

            eval_closure_args(
              new_args,
              recur_patterns,
              body,
              closure_env,
              next_ctx,
              metadata,
              do_eval_fn
            )

          {:error, :loop_limit_exceeded} ->
            raise_closure_error({:loop_limit_exceeded, caller_ctx.loop_limit})
        end

      {:error, reason} ->
        raise_closure_error(reason)
    end
  end

  defp count_prelude_entry_metadata(%{prelude_ref: ref}, eval_context) when is_binary(ref),
    do: EvalContext.increment_prelude_call(eval_context, ref)

  defp count_prelude_entry_metadata(_metadata, eval_context), do: eval_context

  # Stable nested-parallel failures cross the host callback via the evaluator's
  # single abort carrier. Other closure errors keep the public HOF type-error
  # classification by using the existing RuntimeError adapter.
  @spec raise_closure_error(term()) :: no_return()
  defp raise_closure_error({atom, _} = reason)
       when atom in [:memory_exceeded, :timeout, :parallel_capacity_exceeded] do
    HostContext.error!(reason)
  end

  defp raise_closure_error({atom, _, _} = reason)
       when atom in [:memory_exceeded, :timeout, :parallel_capacity_exceeded] do
    HostContext.error!(reason)
  end

  defp raise_closure_error(reason) do
    HostContext.error!({@hof_callback_error, Helpers.format_closure_error(reason)})
  end

  @spec reraise_hof_callback_error(Abort.t(), [term()], Exception.stacktrace()) :: no_return()
  defp reraise_hof_callback_error(
         %Abort{outcome: {:error, {@hof_callback_error, message}, %EvalContext{} = context}},
         args,
         _stacktrace
       ) do
    Abort.error!({:type_error, message, args}, context)
  end

  defp reraise_hof_callback_error(%Abort{} = error, _args, stacktrace),
    do: reraise(error, stacktrace)

  defp with_side_effect_stash(%EvalContext{} = eval_ctx, do_eval_fn, fun)
       when is_function(do_eval_fn, 2) and is_function(fun, 0) do
    case HostContext.run_value(eval_ctx, do_eval_fn, fun) do
      {:ok, result, final_ctx} ->
        {:ok, result, final_ctx}

      {:raise, kind, reason, stacktrace, final_ctx} ->
        reraise_captured(kind, reason, stacktrace, final_ctx)
    end
  end

  defp reraise_captured(kind, reason, stacktrace, _final_ctx),
    do: :erlang.raise(kind, reason, stacktrace)

  # ============================================================
  # Closure Execution Helpers
  # ============================================================

  # Locals for the closure body = lexically-captured names ∪ this call's
  # arg bindings ∪ the fn's own name (named fns only). Without this, the
  # `:var` resolver would lose precedence for shadowed names (e.g. a let
  # binding shadowing a later `def`).
  @doc false
  def closure_locals(meta, bindings) do
    captured = Map.get(meta, :captured_locals, MapSet.new())
    arg_names = bindings |> Map.keys() |> MapSet.new()
    base = MapSet.union(captured, arg_names)

    case meta do
      %{fn_name: name} -> MapSet.put(base, name)
      _ -> base
    end
  end

  # For named fns, wire the closure to its own name in `env` so that
  # `(:var fn_name)` inside the body resolves via the locals path
  # (closure_locals puts fn_name into locals from metadata).
  @doc false
  def bind_self_recursion(env, %{fn_name: name}, closure), do: Map.put(env, name, closure)
  def bind_self_recursion(env, _meta, _closure), do: env

  defp execute_closure(closure, args, eval_ctx, do_eval_fn) do
    {:closure, patterns, _body, _env, _th, _meta} = closure
    do_execute_closure(closure, patterns, args, eval_ctx, do_eval_fn)
  end

  # The `user_ns` a closure body runs against, and what to restore on return. A
  # prelude-export closure (tagged `:prelude_ns_env`) runs against its private
  # env and restores the caller's namespace; any other closure runs against the
  # caller's `user_ns` and keeps whatever it produced.
  defp prelude_run_scope(%{prelude_ns: ns}, _user_ns, caller_ctx),
    do: {prelude_ns_env(caller_ctx.prelude, ns), caller_ctx.user_ns}

  defp prelude_run_scope(_meta, user_ns, caller_ctx) do
    case EvalContext.current_prelude_caller_user_ns(caller_ctx) do
      nil -> {user_ns, :keep}
      caller_user_ns -> {caller_user_ns, user_ns}
    end
  end

  defp restored_user_ns(:keep, final_ctx), do: final_ctx.user_ns
  defp restored_user_ns(ns, _final_ctx), do: ns

  # Resolve a prelude namespace's private env from the attached prelude artifact.
  # The closure carries only the (public) namespace NAME, never the env itself,
  # so private helpers stay out of user-visible values.
  defp prelude_ns_env(nil, _ns), do: %{}

  defp prelude_ns_env(prelude, ns) do
    prelude.private_env
    |> Map.get(ns, %{})
    |> PreludeClosure.tag_internal_environment(ns)
  end

  # The prelude namespace name a closure was tagged with (value-position export),
  # or `nil` for an ordinary user closure.
  defp prelude_ns_tag(%{prelude_ns: ns}), do: ns
  defp prelude_ns_tag(_meta), do: nil

  defp maybe_push_prelude_origin(
         %EvalContext{} = context,
         %{
           prelude_ref: ref,
           prelude_ns: ns,
           prelude_tool_refs: tool_refs
         },
         %EvalContext{} = caller_ctx
       )
       when is_binary(ref) and is_binary(ns) and is_list(tool_refs) do
    caller_user_ns = EvalContext.current_prelude_caller_user_ns(caller_ctx) || caller_ctx.user_ns

    context
    |> EvalContext.push_prelude_caller_user_ns(caller_user_ns)
    |> EvalContext.push_prelude_origin(%{ref: ref, namespace: ns, tool_refs: tool_refs})
  end

  defp maybe_push_prelude_origin(%EvalContext{} = context, %{prelude_internal: true}, _caller_ctx) do
    context
  end

  defp maybe_push_prelude_origin(%EvalContext{} = context, %{prelude_ns: ns}, _caller_ctx)
       when is_binary(ns) do
    EvalContext.push_prelude_returned_origin(context, ns)
  end

  defp maybe_push_prelude_origin(%EvalContext{} = context, _meta, _caller_ctx) do
    EvalContext.push_user_origin(context)
  end

  # Restore caller lexical, namespace, and authority scope on every expected
  # direct closure exit. Successful ordinary calls retain their namespace
  # writes in the success path above; errors and control signals do not expose
  # callback-local writes. Prelude closures likewise discard their private
  # namespace wholesale.
  defp restore_direct_caller(
         %EvalContext{} = closure_ctx,
         %EvalContext{} = caller_ctx,
         _meta
       ) do
    %{
      caller_ctx
      | effects: closure_ctx.effects,
        iteration_count: closure_ctx.iteration_count,
        failure_origin: closure_ctx.failure_origin
    }
  end

  # Restore the caller's non-effect scope around a context produced by a closure
  # converted for host HOF use. Converted closures start with the caller's
  # cumulative effects; materialization replaces them with the active frame's
  # authoritative cumulative value when capture is present.
  defp restore_hof_caller(%EvalContext{} = closure_ctx, %EvalContext{} = caller_ctx) do
    closure_ctx = Capture.materialize_context(closure_ctx)

    %{
      caller_ctx
      | effects: closure_ctx.effects,
        iteration_count: caller_ctx.iteration_count + closure_ctx.iteration_count,
        failure_origin: closure_ctx.failure_origin
    }
  end

  # Re-throw a `(return …)`/`(fail …)` signal that escaped a value-position
  # closure after restoring the caller scope. Prelude exports additionally
  # discard their private namespace and tag returned closures.
  @spec rethrow_export_abort(atom(), term(), EvalContext.t(), map(), EvalContext.t()) ::
          no_return()
  defp rethrow_export_abort(signal, value, thrown_ctx, meta, caller_ctx) do
    restored_ctx = restore_direct_caller(thrown_ctx, caller_ctx, meta)

    case prelude_ns_tag(meta) do
      nil ->
        Abort.control!(signal, value, restored_ctx)

      ns ->
        tagged = if signal == :return, do: PreludeClosure.tag_namespace(value, ns), else: value

        if signal == :return do
          Contract.validate_output!(meta, tagged, restored_ctx)
        end

        Abort.control!(signal, tagged, restored_ctx)
    end
  end

  defp do_execute_closure(
         {:closure, _closure_patterns, body, closure_env, _closure_turn_history, meta} = closure,
         binding_patterns,
         args,
         %EvalContext{ctx: ctx, user_ns: user_ns, tool_exec: tool_exec} = caller_ctx,
         do_eval_fn
       ) do
    case bind_args(binding_patterns, args) do
      {:ok, bindings} ->
        new_env = Map.merge(closure_env, bindings)

        # Named fn: bind the closure to its own name for self-recursion
        new_env =
          case meta do
            %{fn_name: name} -> Map.put(new_env, name, closure)
            _ -> new_env
          end

        # A prelude-export closure (tagged with `:prelude_ns_env`) runs against
        # its private prelude env as `user_ns`, restoring the caller's namespace
        # on return so it cannot read or write user bindings (value-position
        # isolation, mirroring the direct `(crm/export ...)` call path).
        {closure_user_ns, restore_user_ns} = prelude_run_scope(meta, user_ns, caller_ctx)

        closure_ctx =
          EvalContext.new(ctx, closure_user_ns, new_env, tool_exec, caller_ctx.turn_history)
          |> EvalContext.inherit_prelude(caller_ctx)

        # Carry accumulated state from caller so tool_calls/cache aren't lost across closure calls.
        # `locals` is rebuilt from the closure's lexical capture + this invocation's
        # arg bindings + (for named fns) the fn's own name. Builtins no longer live
        # in `env`, so the `:var` resolver falls through to Env.builtin? for them.
        closure_ctx =
          %{
            closure_ctx
            | locals: closure_locals(meta, bindings),
              loop_limit: caller_ctx.loop_limit,
              effects: caller_ctx.effects,
              max_print_length: caller_ctx.max_print_length,
              pmap_timeout: caller_ctx.pmap_timeout,
              pmap_max_concurrency: caller_ctx.pmap_max_concurrency,
              # Security H1: propagate the heap caps + shared worker-slot
              # budget into nested closure evaluation so a nested
              # pmap/pcalls caps and counts its workers, and the shared
              # deadline so nested calls share one wall clock.
              max_heap: caller_ctx.max_heap,
              worker_max_heap: caller_ctx.worker_max_heap,
              parallel_budget: caller_ctx.parallel_budget,
              pmap_deadline: caller_ctx.pmap_deadline,
              tools_meta: caller_ctx.tools_meta,
              # Propagate the ledger cap so tool calls inside a closure (e.g. the
              # paginated-read fold's `(map (fn [_] (tool/...)) ...)`) honor the
              # caller's cap instead of resetting to the struct default.
              max_tool_call_result_bytes: caller_ctx.max_tool_call_result_bytes
          }
          |> maybe_push_prelude_origin(meta, caller_ctx)

        case do_eval_fn.(body, closure_ctx) do
          {:ok, result, final_ctx} ->
            # Capture return type and update user_ns if this closure is a named function
            final_ctx = update_closure_return_type(closure, result, final_ctx)
            # Restore caller's env AND locals — without restoring locals, a
            # param name that shadowed a top-level def would stay in the
            # caller's `locals` set after the call, making subsequent
            # lookups of that name resolve to (a missing) env entry instead
            # of falling through to user_ns. For a prelude-export closure also
            # restore the caller's user_ns (discarding any `(def ...)` the export
            # made), keeping the namespace isolated, and tag a returned closure so
            # its private-helper references still resolve when applied later.
            {:ok, PreludeClosure.tag_namespace(result, prelude_ns_tag(meta)),
             %{
               final_ctx
               | env: caller_ctx.env,
                 locals: caller_ctx.locals,
                 user_ns: restored_user_ns(restore_user_ns, final_ctx),
                 origin_stack: caller_ctx.origin_stack
             }}

          {:error, reason} ->
            Abort.error!(
              maybe_sanitize_private_error(
                reason,
                prelude_ns_tag(meta),
                prelude_error_origin(meta)
              ),
              caller_ctx
            )
        end

      {:error, reason} ->
        Abort.error!(
          maybe_sanitize_private_error(reason, prelude_ns_tag(meta), prelude_error_origin(meta)),
          caller_ctx
        )
    end
  rescue
    error in Abort ->
      handle_direct_closure_abort(error, closure, meta, caller_ctx, do_eval_fn, __STACKTRACE__)
  end

  defp handle_direct_closure_abort(
         %Abort{outcome: {:control, :return, value, %EvalContext{} = abort_ctx}},
         _closure,
         meta,
         caller_ctx,
         _do_eval_fn,
         _stacktrace
       ),
       do: rethrow_export_abort(:return, value, abort_ctx, meta, caller_ctx)

  defp handle_direct_closure_abort(
         %Abort{outcome: {:control, :fail, value, %EvalContext{} = abort_ctx}},
         _closure,
         meta,
         caller_ctx,
         _do_eval_fn,
         _stacktrace
       ),
       do: rethrow_export_abort(:fail, value, abort_ctx, meta, caller_ctx)

  defp handle_direct_closure_abort(
         %Abort{outcome: {:control, :recur, new_args, %EvalContext{} = abort_ctx}},
         closure,
         _meta,
         caller_ctx,
         do_eval_fn,
         _stacktrace
       ) do
    # For recur, variadic functions behave like fixed-arity functions
    # where the & rest pattern is the last parameter.
    {:closure, closure_patterns, _, _, _, _} = closure

    recur_patterns =
      case closure_patterns do
        {:variadic, leading, rest} -> leading ++ [rest]
        others -> others
      end

    case check_arity(recur_patterns, new_args) do
      :ok ->
        # Check iteration limit
        case EvalContext.increment_iteration(caller_ctx) do
          {:ok, updated_caller_ctx} ->
            updated_caller_ctx =
              EvalContext.restore_recur_effects(updated_caller_ctx, abort_ctx.effects)

            do_execute_closure(
              closure,
              recur_patterns,
              new_args,
              updated_caller_ctx,
              do_eval_fn
            )

          {:error, :loop_limit_exceeded} ->
            {:error, {:loop_limit_exceeded, caller_ctx.loop_limit}}
        end

      {:error, {:arity_mismatch, expected, actual}} ->
        {:error, {:arity_mismatch, expected, actual}}
    end
  end

  defp handle_direct_closure_abort(
         %Abort{outcome: {:error, reason, %EvalContext{} = abort_ctx}},
         _closure,
         meta,
         caller_ctx,
         _do_eval_fn,
         _stacktrace
       ) do
    restored_ctx = restore_direct_caller(abort_ctx, caller_ctx, meta)

    reason =
      maybe_sanitize_private_error(reason, prelude_ns_tag(meta), prelude_error_origin(meta))

    Abort.error!(reason, restored_ctx)
  end

  defp handle_direct_closure_abort(
         %Abort{} = error,
         _closure,
         _meta,
         _caller_ctx,
         _do_eval_fn,
         stacktrace
       ),
       do: reraise(error, stacktrace)

  defp maybe_sanitize_private_error(reason, nil, _origin), do: reason

  defp maybe_sanitize_private_error(reason, _prelude_ns, origin),
    do: Helpers.sanitize_private_error(reason, origin)

  defp prelude_error_origin(%{prelude_ref: ref}) when is_binary(ref), do: %{ref: ref}

  defp prelude_error_origin(%{prelude_ns: namespace}) when is_binary(namespace),
    do: %{namespace: namespace}

  defp prelude_error_origin(_metadata), do: nil

  # Update closure metadata with return type if closure exists in user_ns
  defp update_closure_return_type(
         {:closure, params, body, env, th, _old_meta} = _closure,
         result,
         %EvalContext{user_ns: user_ns} = ctx
       ) do
    return_type = derive_type(result)

    # Find entries in user_ns that match this closure (same params, body, env, th)
    updated_user_ns =
      Enum.reduce(user_ns, user_ns, fn
        {name, {:closure, ^params, ^body, ^env, ^th, old_meta}}, acc ->
          new_meta = Map.put(old_meta, :return_type, return_type)
          Map.put(acc, name, {:closure, params, body, env, [], new_meta})

        _, acc ->
          acc
      end)

    %{ctx | user_ns: updated_user_ns}
  end

  defp derive_type(value), do: TypeVocabulary.type_of(value)

  defp bind_args({:variadic, leading, rest_pattern}, args) do
    {leading_args, rest_args} = Enum.split(args, length(leading))
    rest_args = Enum.map(rest_args, &unwrap_capability_argument/1)

    leading_res = match_capability_zipped(leading, leading_args)

    case leading_res do
      {:ok, leading_bindings} ->
        case Patterns.coerce_for_pattern(rest_pattern, rest_args) do
          {:error, _} = err ->
            err

          rest_value ->
            case Patterns.match_pattern(rest_pattern, rest_value) do
              {:ok, rest_bindings} -> {:ok, Map.merge(leading_bindings, rest_bindings)}
              {:error, _} = err -> err
            end
        end

      err ->
        err
    end
  end

  defp bind_args(patterns, args) when is_list(patterns) do
    match_capability_zipped(patterns, args)
  end

  defp match_capability_zipped(patterns, values) do
    Enum.zip(patterns, values)
    |> Enum.reduce_while({:ok, %{}}, fn {pattern, value}, {:ok, acc} ->
      case match_capability_argument(pattern, value) do
        {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp match_capability_argument(pattern, %CapabilityResult{value: value} = result) do
    case Patterns.match_pattern(pattern, value) do
      {:ok, bindings} ->
        {:ok, preserve_capability_binding(bindings, pattern, result)}

      {:error, _} = error ->
        error
    end
  end

  defp match_capability_argument(pattern, value), do: Patterns.match_pattern(pattern, value)

  defp unwrap_capability_argument(%CapabilityResult{value: value}), do: value
  defp unwrap_capability_argument(value), do: value

  defp preserve_capability_binding(bindings, {:var, name}, result),
    do: Map.put(bindings, name, result)

  defp preserve_capability_binding(
         bindings,
         {:destructure, {:as, name, _inner_pattern}},
         result
       ),
       do: Map.put(bindings, name, result)

  defp preserve_capability_binding(bindings, _pattern, _result), do: bindings

  # Format arities list for human-readable error messages
  defp format_arities([n]), do: "#{n}"
  defp format_arities([a, b]), do: "#{a} or #{b}"
  defp format_arities(arities), do: Enum.join(arities, ", ")
end
