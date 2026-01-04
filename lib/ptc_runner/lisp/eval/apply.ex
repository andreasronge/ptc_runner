defmodule PtcRunner.Lisp.Eval.Apply do
  @moduledoc """
  Function application dispatch for Lisp evaluation.

  Handles calling closures, keywords, sets, builtins, and plain functions.

  ## Supported function types

  - Keywords as map accessors: `(:key map)` → `Map.get(map, :key)`
  - Sets as membership check: `(set x)` → `x` or `nil`
  - Closures: user-defined functions
  - Builtins: `{:normal, fun}`, `{:variadic, fun, identity}`, etc.
  - Plain Erlang functions
  """

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.Patterns

  import PtcRunner.Lisp.Runtime, only: [flex_get: 2, flex_fetch: 2]

  @doc """
  Applies a function value to a list of arguments.
  """
  @spec apply_fun(term(), [term()], EvalContext.t(), (term(), EvalContext.t() -> term())) ::
          {:ok, term(), map()} | {:error, term()}
  def apply_fun(fun_val, args, eval_ctx, do_eval_fn) do
    do_apply_fun(fun_val, args, eval_ctx, do_eval_fn)
  end

  # Keyword as function: (:key map) → Map.get(map, :key)
  defp do_apply_fun(k, args, %EvalContext{memory: memory}, _do_eval_fn) when is_atom(k) do
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
  defp do_apply_fun(set, [arg], %EvalContext{memory: memory}, _do_eval_fn)
       when is_struct(set, MapSet) do
    {:ok, if(MapSet.member?(set, arg), do: arg, else: nil), memory}
  end

  defp do_apply_fun(set, args, %EvalContext{}, _do_eval_fn)
       when is_struct(set, MapSet) do
    {:error, {:arity_error, "set expects 1 argument, got #{length(args)}"}}
  end

  # Closure application (5-element tuple format with turn_history)
  defp do_apply_fun(
         {:closure, patterns, body, closure_env, closure_turn_history},
         args,
         %EvalContext{ctx: ctx, memory: memory, tool_exec: tool_exec},
         do_eval_fn
       ) do
    if length(patterns) != length(args) do
      {:error, {:arity_mismatch, length(patterns), length(args)}}
    else
      result =
        Enum.zip(patterns, args)
        |> Enum.reduce_while({:ok, %{}}, fn {pattern, arg}, {:ok, acc} ->
          case Patterns.match_pattern(pattern, arg) do
            {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        {:ok, bindings} ->
          new_env = Map.merge(closure_env, bindings)
          closure_ctx = EvalContext.new(ctx, memory, new_env, tool_exec, closure_turn_history)
          do_eval_fn.(body, closure_ctx)

        {:error, _} = err ->
          err
      end
    end
  end

  # Normal builtins: {:normal, fun}
  # Special handling for closures - convert them to Erlang functions
  defp do_apply_fun({:normal, fun}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_function(fun) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)

    try do
      {:ok, apply(fun, converted_args), eval_ctx.memory}
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
  defp do_apply_fun({:variadic, fun2, _identity}, [x], %EvalContext{memory: memory}, _do_eval_fn) do
    if fun2 == (&Kernel.-/2) do
      {:ok, -x, memory}
    else
      # For other variadic functions like *, single arg returns the arg itself
      {:ok, x, memory}
    end
  rescue
    ArithmeticError ->
      {:error, {:type_error, "expected number, got #{Helpers.describe_type(x)}", x}}
  end

  # Variadic builtins: {:variadic, fun2, identity}
  defp do_apply_fun({:variadic, fun2, identity}, args, %EvalContext{memory: memory}, _do_eval_fn)
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
        {:error, Helpers.type_error_for_args(fun2, args)}
      end
  end

  # Variadic requiring at least one arg: {:variadic_nonempty, fun2}
  defp do_apply_fun({:variadic_nonempty, _fun2}, [], %EvalContext{}, _do_eval_fn) do
    {:error, {:arity_error, "requires at least 1 argument"}}
  end

  defp do_apply_fun({:variadic_nonempty, fun2}, args, %EvalContext{memory: memory}, _do_eval_fn)
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
        {:error, Helpers.type_error_for_args(fun2, args)}
      end
  end

  # Multi-arity builtins: select function based on argument count
  # Tuple {fun2, fun3} means index 0 = arity 2, index 1 = arity 3, etc.
  defp do_apply_fun({:multi_arity, funs}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_tuple(funs) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)

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
          {:error, Helpers.type_error_for_args(fun, converted_args)}

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
  defp do_apply_fun(fun, args, %EvalContext{memory: memory}, _do_eval_fn) when is_function(fun) do
    {:ok, apply(fun, args), memory}
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

  def closure_to_fun({:variadic_nonempty, fun}, %EvalContext{}, _do_eval_fn)
      when is_function(fun) do
    fun
  end

  # Non-closures pass through unchanged
  def closure_to_fun(value, %EvalContext{}, _do_eval_fn) do
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
        eval_context.memory,
        new_env,
        eval_context.tool_exec,
        closure_turn_history
      )

    case do_eval_fn.(body, eval_ctx) do
      {:ok, result, _} -> result
      {:error, reason} -> raise RuntimeError, Helpers.format_closure_error(reason)
    end
  end
end
