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

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.Patterns
  alias PtcRunner.Lisp.Format

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

  # Keyword as function: (:key map) → Map.get(map, :key)
  defp do_apply_fun(k, args, %EvalContext{} = eval_ctx, _do_eval_fn) when is_atom(k) do
    case args do
      [m] when is_map(m) ->
        {:ok, flex_get(m, k), eval_ctx}

      [m, default] when is_map(m) ->
        case flex_fetch(m, k) do
          {:ok, val} -> {:ok, val, eval_ctx}
          :error -> {:ok, default, eval_ctx}
        end

      [nil] ->
        {:ok, nil, eval_ctx}

      [nil, default] ->
        {:ok, default, eval_ctx}

      _ ->
        {:error, {:invalid_keyword_call, k, args}}
    end
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

  # Closure application (5-element tuple format with turn_history)
  defp do_apply_fun(
         {:closure, patterns, _body, _env, _th} = closure,
         args,
         %EvalContext{} = eval_ctx,
         do_eval_fn
       ) do
    if length(patterns) != length(args) do
      {:error, {:arity_mismatch, length(patterns), length(args)}}
    else
      execute_closure(closure, args, eval_ctx, do_eval_fn)
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
  defp do_apply_fun({:special, :println}, args, eval_ctx, _do_eval_fn) do
    message =
      Enum.map_join(args, " ", fn
        s when is_binary(s) -> s
        v -> Format.to_clojure(v) |> elem(0)
      end)

    {:ok, nil, EvalContext.append_print(eval_ctx, message)}
  end

  # Normal builtins: {:normal, fun}
  # Special handling for closures - convert them to Erlang functions
  defp do_apply_fun({:normal, fun}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_function(fun) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)

    try do
      {:ok, apply(fun, converted_args), eval_ctx}
    rescue
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

      e in BadFunctionError ->
        # Catch attempts to use non-functions as functions (e.g., :keyword passed to map)
        {:error, {:type_error, Exception.message(e), converted_args}}
    end
  end

  # Special handling for unary minus: (- x) means negation, not (identity - x)
  defp do_apply_fun(
         {:variadic, fun2, _identity},
         [x],
         %EvalContext{} = eval_ctx,
         _do_eval_fn
       ) do
    if fun2 == (&Kernel.-/2) do
      {:ok, -x, eval_ctx}
    else
      # For other variadic functions like *, single arg returns the arg itself
      {:ok, x, eval_ctx}
    end
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
        [x] -> x
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result, eval_ctx}
  rescue
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
         {:variadic_nonempty, _name, fun2},
         args,
         %EvalContext{} = eval_ctx,
         _do_eval_fn
       )
       when is_function(fun2, 2) do
    result =
      case args do
        [x] -> x
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result, eval_ctx}
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
        {:error, Helpers.type_error_for_args(fun2, args)}
      end
  end

  # Collect builtins: pass all args as a list to unary function
  defp do_apply_fun({:collect, fun}, args, %EvalContext{} = eval_ctx, _do_eval_fn)
       when is_function(fun, 1) do
    {:ok, fun.(args), eval_ctx}
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
        {:ok, apply(fun, converted_args), eval_ctx}
      rescue
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

  defp do_apply_fun(fun, args, %EvalContext{} = eval_ctx, _do_eval_fn)
       when is_function(fun) do
    {:ok, apply(fun, args), eval_ctx}
  end

  # Map as function: (map :key) → Map.get(map, :key)
  defp do_apply_fun(m, args, %EvalContext{} = eval_ctx, _do_eval_fn) when is_map(m) do
    case args do
      [k] when is_atom(k) ->
        {:ok, flex_get(m, k), eval_ctx}

      [k, default] when is_atom(k) ->
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

  @doc """
  Converts Lisp closures to Erlang functions for use with higher-order functions.

  Creates functions with appropriate arity based on number of patterns.
  Also unwraps builtin function tuples.
  """
  @spec closure_to_fun(term(), EvalContext.t(), (term(), EvalContext.t() -> term())) :: term()
  def closure_to_fun(
        {:closure, patterns, body, closure_env, closure_turn_history},
        %EvalContext{} = eval_context,
        do_eval_fn
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
            closure_turn_history,
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
            closure_turn_history,
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
            closure_turn_history,
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
            closure_turn_history,
            do_eval_fn
          )
        end

      n ->
        raise RuntimeError, "closures with more than 3 parameters not supported (got #{n})"
    end
  end

  # Unwrap builtin function tuples so they can be passed to higher-order functions
  def closure_to_fun({:normal, fun}, %EvalContext{}, _do_eval_fn)
      when is_function(fun) do
    fun
  end

  def closure_to_fun({:variadic, fun, _identity}, %EvalContext{}, _do_eval_fn)
      when is_function(fun) do
    fun
  end

  def closure_to_fun({:variadic_nonempty, _name, fun}, %EvalContext{}, _do_eval_fn)
      when is_function(fun) do
    fun
  end

  def closure_to_fun({:collect, fun}, %EvalContext{}, _do_eval_fn)
      when is_function(fun) do
    fun
  end

  # Special forms like println - convert to a function
  # Note: println side effects are lost when used in HOFs like map (same as pmap)
  def closure_to_fun({:special, :println}, %EvalContext{}, _do_eval_fn) do
    fn arg ->
      # Side effect is lost, but at least it doesn't error
      # User should use doseq pattern instead: (doseq [x coll] (println x))
      # For now, just return nil like println does
      _ = arg
      nil
    end
  end

  # Non-closures pass through unchanged
  def closure_to_fun(value, %EvalContext{}, _do_eval_fn) do
    value
  end

  # ============================================================
  # Internal Helpers
  # ============================================================

  defp last_arg_to_list(nil),
    do: {:error, {:type_error, "apply expects collection as last argument, got nil", nil}}

  defp last_arg_to_list(list) when is_list(list), do: {:ok, list}
  defp last_arg_to_list(%MapSet{} = s), do: {:ok, MapSet.to_list(s)}

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
         closure_turn_history,
         do_eval_fn
       ) do
    if length(args) != length(patterns) do
      raise RuntimeError,
            "closure arity mismatch: expected #{length(patterns)}, got #{length(args)}"
    end

    # Match each argument against its corresponding pattern
    bindings =
      Enum.zip(patterns, args)
      |> Enum.reduce(%{}, fn {pattern, arg}, acc ->
        case Patterns.match_pattern(pattern, arg) do
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
        eval_context.user_ns,
        new_env,
        eval_context.tool_exec,
        closure_turn_history
      )

    case do_eval_fn.(body, eval_ctx) do
      {:ok, result, _} -> result
      {:error, reason} -> raise RuntimeError, Helpers.format_closure_error(reason)
    end
  end

  # ============================================================
  # Closure Execution Helpers
  # ============================================================

  defp execute_closure(
         {:closure, patterns, body, closure_env, closure_turn_history} = closure,
         args,
         %EvalContext{ctx: ctx, user_ns: user_ns, tool_exec: tool_exec} = caller_ctx,
         do_eval_fn
       ) do
    case bind_args(patterns, args) do
      {:ok, bindings} ->
        new_env = Map.merge(closure_env, bindings)
        closure_ctx = EvalContext.new(ctx, user_ns, new_env, tool_exec, closure_turn_history)

        # Use iteration limit and prints from caller context
        closure_ctx = %{
          closure_ctx
          | loop_limit: caller_ctx.loop_limit,
            prints: caller_ctx.prints
        }

        do_eval_fn.(body, closure_ctx)

      {:error, _} = err ->
        err
    end
  catch
    {:recur_signal, new_args, prints} ->
      # Arity check for recur
      if length(patterns) != length(new_args) do
        {:error, {:arity_mismatch, length(patterns), length(new_args)}}
      else
        # Check iteration limit
        case EvalContext.increment_iteration(caller_ctx) do
          {:ok, updated_caller_ctx} ->
            # Preserve prints from this iteration and recurse
            updated_caller_ctx = %{updated_caller_ctx | prints: prints}
            execute_closure(closure, new_args, updated_caller_ctx, do_eval_fn)

          {:error, :loop_limit_exceeded} ->
            {:error, {:loop_limit_exceeded, caller_ctx.loop_limit}}
        end
      end
  end

  defp bind_args(patterns, args) do
    Enum.zip(patterns, args)
    |> Enum.reduce_while({:ok, %{}}, fn {pattern, arg}, {:ok, acc} ->
      case Patterns.match_pattern(pattern, arg) do
        {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Format arities list for human-readable error messages
  defp format_arities([n]), do: "#{n}"
  defp format_arities([a, b]), do: "#{a} or #{b}"
  defp format_arities(arities), do: Enum.join(arities, ", ")
end
