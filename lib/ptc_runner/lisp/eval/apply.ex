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
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Eval.Patterns
  alias PtcRunner.Lisp.ExecutionError
  require PtcRunner.Lisp.ExecutionError
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Args
  alias PtcRunner.Lisp.Runtime.Math
  alias PtcRunner.Lisp.Runtime.SpecialValues
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.SubAgent.Namespace.TypeVocabulary

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

  defp do_apply_fun(%Builtin{} = builtin, args, %EvalContext{} = eval_ctx, do_eval_fn) do
    with :ok <- maybe_validate_builtin_args(builtin, args) do
      do_apply_fun(Builtin.unwrap(builtin), args, eval_ctx, do_eval_fn)
    end
  end

  defp do_apply_fun(%RuntimeCallable{} = callable, args, %EvalContext{} = eval_ctx, do_eval_fn) do
    callable
    |> RuntimeCallable.bind(eval_ctx, do_eval_fn)
    |> RuntimeCallable.invoke(args, eval_ctx)
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
         {:closure, patterns, _body, _env, _th, _meta} = closure,
         args,
         %EvalContext{} = eval_ctx,
         do_eval_fn
       ) do
    case check_arity(patterns, args) do
      :ok -> execute_closure(closure, args, eval_ctx, do_eval_fn)
      {:error, _} = err -> err
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

  # Normal builtins: {:normal, fun}
  # Special handling for closures - convert them to Erlang functions
  defp do_apply_fun({:normal, fun}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_function(fun) do
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)

    try do
      with_side_effect_stash(eval_ctx, do_eval_fn, fn -> apply(fun, converted_args) end)
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

      e in PtcRunner.Lisp.TypeError ->
        {:error, {:type_error, Exception.message(e), converted_args}}

      e in ExecutionError ->
        # A nested pmap/pcalls failure (`:memory_exceeded` / `:timeout`)
        # raised through a closure run by a regular HOF (map/filter/...).
        # Surface its stable reason instead of letting it crash the
        # sandbox as `:execution_error`. Non-parallel ExecutionErrors
        # (e.g. tool errors) are re-raised to keep their semantics.
        reraise_unless_parallel(e, __STACKTRACE__)

      e in ArithmeticError ->
        {:error, {:arithmetic_error, Exception.message(e)}}

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
    {:ok, unary_variadic(fun2, x), eval_ctx}
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
        [x] -> unary_variadic(fun2, x)
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

    e in PtcRunner.Lisp.TypeError ->
      {:error, {:type_error, Exception.message(e), args}}
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
        [x] -> unary_variadic_nonempty(name, fun2, x)
        [x, y] -> fun2.(x, y)
        [h | t] -> Enum.reduce(t, h, fn x, acc -> fun2.(acc, x) end)
      end

    {:ok, result, eval_ctx}
  rescue
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

    e in PtcRunner.Lisp.TypeError ->
      {:error, {:type_error, Exception.message(e), args}}
  end

  # Collect builtins: pass all args as a list to unary function
  defp do_apply_fun({:collect, fun}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_function(fun, 1) do
    # Convert any closures/builtins in args to callable functions
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)

    try do
      with_side_effect_stash(eval_ctx, do_eval_fn, fn -> fun.(converted_args) end)
    rescue
      FunctionClauseError ->
        # A bad argument shape inside a collect builtin (e.g. (update-in [1 2]
        # [] f) routing a vector root through flex_update_in's integer-key
        # clauses) must surface as a recoverable type error, not leak the
        # internal module/function name as a raw :runtime_error. Mirrors the
        # {:normal} and {:multi_arity} handlers so all builtin dispatch shapes
        # fail consistently.
        {:error, Helpers.type_error_for_args(fun, converted_args)}

      e in ExecutionError ->
        {:error, execution_error_tuple(e)}

      e in PtcRunner.Lisp.TypeError ->
        {:error, {:type_error, Exception.message(e), args}}
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
        FunctionClauseError ->
          # Provide a helpful error message for type mismatches
          {:error, Helpers.type_error_for_args(fun, converted_args)}

        e in RuntimeError ->
          # Catch errors from closure evaluation (destructuring, arity, eval errors)
          {:error, {:type_error, Exception.message(e), converted_args}}

        e in ExecutionError ->
          # See the `{:normal, fun}` clause: surface nested parallel
          # `:memory_exceeded` / `:timeout` rather than crash the sandbox.
          reraise_unless_parallel(e, __STACKTRACE__)

        e in PtcRunner.Lisp.TypeError ->
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

  # Map as function: (map key) → Map.get(map, key)
  # Supports any key type (atoms, strings, integers, etc.) like Clojure
  defp do_apply_fun(m, args, %EvalContext{} = eval_ctx, _do_eval_fn) when is_map(m) do
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

  defp apply_keyword(k, args, %EvalContext{} = eval_ctx) do
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
  rescue
    e in PtcRunner.Lisp.TypeError -> {:error, {:type_error, Exception.message(e), args}}
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

  defp unary_variadic(fun2, x) do
    cond do
      fun2 == (&Kernel.-/2) or fun2 == (&Math.subtract/2) -> Math.subtract([x])
      fun2 == (&Math.add/2) -> unary_plus(x)
      fun2 == (&Math.multiply/2) -> fun2.(x, 1)
      true -> x
    end
  end

  defp unary_plus(x) when is_number(x), do: x
  defp unary_plus(x), do: if(SpecialValues.special?(x), do: x, else: Math.add(x, 0))

  defp unary_variadic_nonempty(:/, fun2, x), do: fun2.(1, x)
  defp unary_variadic_nonempty(:-, _fun2, x), do: Math.subtract([x])
  defp unary_variadic_nonempty(_name, _fun2, x), do: x

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
      # Variadic closures - we don't know what arity the HOF wants,
      # but we can check the call-time arity.
      # Wait, HOFs like Enum.map expect a function of SPECIFIC arity.
      # We can't return "any" arity. We'll return a 1-arity function by default
      # if it's compatible, as it's the most common for HOFs.
      # If they need 2 (reduce) or 3, it gets tricky.

      # Let's try to return a 1-arity function if min_arity <= 1.
      # If min_arity > 1, we might need a 2-arity or 3-arity.
      # For now, we'll support the same 0-3 arity range, but the USER
      # must choose the right one? No, we have to return one function.

      # Actually, since we don't know, we'll return a 1-arity one if possible.
      # If they need 2-arity, this will fail.
      # A better approach might be to have builtins that use closure_to_fun
      # specify the arity they need. But closure_to_fun is also used in other places.

      # Clojure's variadic functions are actually multi-arity functions.
      # For now, let's assume 1-arity is what's wanted if it's variadic and min_arity <= 1.
      # If it's used in reduce, it needs 2.

      # Let's check how builtins use it. reduce uses 2. map uses 1.
      # We could return a function that supports multiple arities IF we use def
      # but we are returning an anonymous function.

      # Wait, I can't return multiple arities.
      # I'll default to 1-arity for now, and maybe 2-arity if min_arity is 2.
      # This is a limitation of converting to Erlang functions.
      # Variadic closures
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

  # Special forms like println - convert to a function
  def closure_to_fun({:special, :println}, %EvalContext{}, _do_eval_fn) do
    fn arg ->
      message =
        case arg do
          s when is_binary(s) -> s
          v -> format_for_println(v)
        end

      # Stash the print in the process dictionary for HOF side-effect collection
      case Process.get(:__ptc_hof_stack, []) do
        [top | rest] ->
          updated = %{top | prints: [message | top.prints]}
          Process.put(:__ptc_hof_stack, [updated | rest])

        [] ->
          :ok
      end

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

  # Detect char lists (result of `(take n string)`) and join them for readable output
  defp format_for_println(list) when is_list(list) do
    if char_list?(list) do
      Enum.join(list, "")
    else
      Format.to_clojure(list) |> elem(0)
    end
  end

  defp format_for_println(v), do: Format.to_clojure(v) |> elem(0)

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

  defp last_arg_to_list(m) when is_map(m) do
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
    case check_arity(patterns, args) do
      :ok ->
        :ok

      {:error, {:arity_mismatch, expected, actual}} ->
        raise RuntimeError, "closure arity mismatch: expected #{expected}, got #{actual}"
    end

    # Match each argument against its corresponding pattern
    bindings =
      case bind_args(patterns, args) do
        {:ok, bindings} ->
          bindings

        {:error, {:destructure_error, reason}} ->
          raise RuntimeError, "destructure error: #{reason}"
      end

    new_env = Map.merge(closure_env, bindings)

    eval_ctx =
      EvalContext.new(
        eval_context.ctx,
        eval_context.user_ns,
        new_env,
        eval_context.tool_exec,
        eval_context.turn_history,
        pmap_timeout: eval_context.pmap_timeout,
        pmap_max_concurrency: eval_context.pmap_max_concurrency,
        # Security H1: propagate the sandbox cap, the FIXED per-worker
        # heap cap, and the shared worker-slot budget so a nested
        # pmap/pcalls invoked from inside this closure caps and counts
        # its workers against the same global budget.
        max_heap: eval_context.max_heap,
        worker_max_heap: eval_context.worker_max_heap,
        parallel_budget: eval_context.parallel_budget,
        discovery_exec: eval_context.discovery_exec
      )

    eval_ctx = %{
      eval_ctx
      | locals: closure_locals(metadata, bindings),
        # Security H1: propagate the shared parallel deadline so a
        # nested pmap/pcalls inside this closure inherits it.
        pmap_deadline: eval_context.pmap_deadline
    }

    case do_eval_fn.(body, eval_ctx) do
      {:ok, result, final_ctx} ->
        # Stash side effects (tool_calls, prints) in process dictionary
        # so they survive the Erlang HOF boundary (closure_to_fun returns only a value)
        stash_side_effects(final_ctx)
        result

      {:error, reason} ->
        raise_closure_error(reason)
    end
  end

  # A closure-eval error from a *nested* pmap/pcalls (heap kill, shared
  # deadline, exhausted worker budget) is raised as `ExecutionError`
  # carrying the structured reason, so the surrounding pmap/pcalls worker
  # can re-surface the stable atom instead of flattening it into a
  # string. Every other closure error keeps the legacy `RuntimeError`
  # shape that `do_apply_fun/4`'s rescue clauses convert into `{:error,
  # ...}`. Parallel errors arrive as 2- or 3-tuples.
  @spec raise_closure_error(term()) :: no_return()
  defp raise_closure_error({atom, _} = reason)
       when atom in ExecutionError.stable_parallel_reasons() do
    raise_parallel_closure_error(atom, reason)
  end

  defp raise_closure_error({atom, _, _} = reason)
       when atom in ExecutionError.stable_parallel_reasons() do
    raise_parallel_closure_error(atom, reason)
  end

  defp raise_closure_error(reason) do
    raise RuntimeError, Helpers.format_closure_error(reason)
  end

  @spec raise_parallel_closure_error(atom(), term()) :: no_return()
  defp raise_parallel_closure_error(atom, reason) do
    raise PtcRunner.Lisp.ExecutionError,
      reason: atom,
      message: Helpers.format_closure_error(reason)
  end

  # Side-effect accumulation via Process dictionary.
  # When closures run inside Erlang HOFs (Enum.reduce, Enum.map, etc.),
  # the eval context is lost because the wrapper function can only return a value.
  # We stash tool_calls and prints in the process dictionary so the HOF caller
  # can collect them after the HOF completes.
  #
  # Uses a stack to handle nested HOFs: each HOF pushes a fresh accumulator,
  # inner HOFs push/pop their own level, and the outer HOF collects everything.

  defp with_side_effect_stash(%EvalContext{} = eval_ctx, do_eval_fn, fun)
       when is_function(do_eval_fn, 2) and is_function(fun, 0) do
    push_side_effect_stash()

    try do
      result = RuntimeCallable.with_context(eval_ctx, do_eval_fn, fun)
      {:ok, result, pop_side_effects(eval_ctx)}
    rescue
      e ->
        drop_side_effect_stash()
        reraise e, __STACKTRACE__
    catch
      kind, reason ->
        drop_side_effect_stash()
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp push_side_effect_stash do
    stack = Process.get(:__ptc_hof_stack, [])

    Process.put(:__ptc_hof_stack, [
      %{tool_calls: [], prints: [], catalog_ops: [], tool_cache: %{}} | stack
    ])
  end

  defp drop_side_effect_stash do
    case Process.get(:__ptc_hof_stack, []) do
      [_top | rest] -> Process.put(:__ptc_hof_stack, rest)
      [] -> :ok
    end
  end

  defp stash_side_effects(%EvalContext{} = ctx) do
    case Process.get(:__ptc_hof_stack, []) do
      [top | rest] ->
        # EvalContext stores tool_calls/prints in prepend order (newest first).
        # Maintain prepend order in the stash: current invocation's newest first,
        # then previous invocations'.
        updated = %{
          tool_calls: ctx.tool_calls ++ top.tool_calls,
          prints: ctx.prints ++ top.prints,
          catalog_ops: ctx.catalog_ops ++ top.catalog_ops,
          tool_cache: Map.merge(Map.get(top, :tool_cache, %{}), ctx.tool_cache)
        }

        Process.put(:__ptc_hof_stack, [updated | rest])

      [] ->
        :ok
    end
  end

  defp pop_side_effects(%EvalContext{} = eval_ctx) do
    case Process.get(:__ptc_hof_stack, []) do
      [top | rest] ->
        Process.put(:__ptc_hof_stack, rest)

        # Stash is in prepend order (newest first), same as eval_ctx.
        # Prepend stash before eval_ctx's existing items so the final
        # Enum.reverse in Lisp.run produces chronological order.
        eval_ctx
        |> Map.update!(:tool_calls, fn existing -> top.tool_calls ++ existing end)
        |> Map.update!(:prints, fn existing -> top.prints ++ existing end)
        |> Map.update!(:catalog_ops, fn existing -> top.catalog_ops ++ existing end)
        |> Map.update!(:tool_cache, fn existing ->
          Map.merge(existing, Map.get(top, :tool_cache, %{}))
        end)

      [] ->
        eval_ctx
    end
  end

  defp execution_error_tuple(%ExecutionError{reason: reason, message: message, data: nil}),
    do: {reason, message}

  defp execution_error_tuple(%ExecutionError{reason: reason, message: message, data: data}),
    do: {reason, message, data}

  # An `ExecutionError` raised from a closure run inside a regular HOF.
  # If it carries a nested-parallel reason (`:memory_exceeded`,
  # `:timeout`, `:parallel_capacity_exceeded`) surface it as a structured
  # error tuple so the stable reason reaches the caller. Anything else
  # (e.g. `:tool_error`) is re-raised unchanged.
  defp reraise_unless_parallel(%ExecutionError{reason: reason} = e, _stacktrace)
       when reason in ExecutionError.stable_parallel_reasons() do
    {:error, execution_error_tuple(e)}
  end

  defp reraise_unless_parallel(%ExecutionError{} = e, stacktrace) do
    reraise e, stacktrace
  end

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

        closure_ctx = EvalContext.new(ctx, user_ns, new_env, tool_exec, caller_ctx.turn_history)

        # Carry accumulated state from caller so tool_calls/cache aren't lost across closure calls.
        # `locals` is rebuilt from the closure's lexical capture + this invocation's
        # arg bindings + (for named fns) the fn's own name. Builtins no longer live
        # in `env`, so the `:var` resolver falls through to Env.builtin? for them.
        closure_ctx = %{
          closure_ctx
          | locals: closure_locals(meta, bindings),
            loop_limit: caller_ctx.loop_limit,
            prints: caller_ctx.prints,
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
            tool_calls: caller_ctx.tool_calls,
            pmap_calls: caller_ctx.pmap_calls,
            tool_cache: caller_ctx.tool_cache,
            summaries: caller_ctx.summaries,
            journal: caller_ctx.journal,
            discovery_exec: caller_ctx.discovery_exec,
            catalog_ops: caller_ctx.catalog_ops
        }

        case do_eval_fn.(body, closure_ctx) do
          {:ok, result, final_ctx} ->
            # Capture return type and update user_ns if this closure is a named function
            final_ctx = update_closure_return_type(closure, result, final_ctx)
            # Restore caller's env AND locals — without restoring locals, a
            # param name that shadowed a top-level def would stay in the
            # caller's `locals` set after the call, making subsequent
            # lookups of that name resolve to (a missing) env entry instead
            # of falling through to user_ns.
            {:ok, result, %{final_ctx | env: caller_ctx.env, locals: caller_ctx.locals}}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  catch
    {:recur_signal, new_args, effects} ->
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
                EvalContext.restore_recur_effects(updated_caller_ctx, effects)

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

    leading_res = Patterns.match_zipped(leading, leading_args)

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
    Patterns.match_zipped(patterns, args)
  end

  # Format arities list for human-readable error messages
  defp format_arities([n]), do: "#{n}"
  defp format_arities([a, b]), do: "#{a} or #{b}"
  defp format_arities(arities), do: Enum.join(arities, ", ")
end
