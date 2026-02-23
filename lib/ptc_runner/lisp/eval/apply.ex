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
  alias PtcRunner.Lisp.Runtime.Math
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

      # Clojure returns nil for keyword lookup on non-map types: (:key "string") → nil
      [_] ->
        {:ok, nil, eval_ctx}

      [_, default] ->
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
      push_side_effect_stash()
      result = apply(fun, converted_args)
      {:ok, result, pop_side_effects(eval_ctx)}
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
    if fun2 == (&Kernel.-/2) or fun2 == (&Math.subtract/2) do
      {:ok, Math.subtract([x]), eval_ctx}
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
  defp do_apply_fun({:collect, fun}, args, %EvalContext{} = eval_ctx, do_eval_fn)
       when is_function(fun, 1) do
    # Convert any closures/builtins in args to callable functions
    converted_args = Enum.map(args, fn arg -> closure_to_fun(arg, eval_ctx, do_eval_fn) end)
    push_side_effect_stash()
    result = fun.(converted_args)
    {:ok, result, pop_side_effects(eval_ctx)}
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
        push_side_effect_stash()
        result = apply(fun, converted_args)
        {:ok, result, pop_side_effects(eval_ctx)}
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
    push_side_effect_stash()
    result = apply(fun, args)
    {:ok, result, pop_side_effects(eval_ctx)}
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
        {:closure, patterns, body, closure_env, closure_turn_history, _metadata},
        %EvalContext{} = eval_context,
        do_eval_fn
      ) do
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
              closure_turn_history,
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
              closure_turn_history,
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
         closure_turn_history,
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
        closure_turn_history,
        pmap_timeout: eval_context.pmap_timeout
      )

    case do_eval_fn.(body, eval_ctx) do
      {:ok, result, final_ctx} ->
        # Stash side effects (tool_calls, prints) in process dictionary
        # so they survive the Erlang HOF boundary (closure_to_fun returns only a value)
        stash_side_effects(final_ctx)
        result

      {:error, reason} ->
        raise RuntimeError, Helpers.format_closure_error(reason)
    end
  end

  # Side-effect accumulation via Process dictionary.
  # When closures run inside Erlang HOFs (Enum.reduce, Enum.map, etc.),
  # the eval context is lost because the wrapper function can only return a value.
  # We stash tool_calls and prints in the process dictionary so the HOF caller
  # can collect them after the HOF completes.
  #
  # Uses a stack to handle nested HOFs: each HOF pushes a fresh accumulator,
  # inner HOFs push/pop their own level, and the outer HOF collects everything.

  defp push_side_effect_stash do
    stack = Process.get(:__ptc_hof_stack, [])
    Process.put(:__ptc_hof_stack, [%{tool_calls: [], prints: []} | stack])
  end

  defp stash_side_effects(%EvalContext{} = ctx) do
    case Process.get(:__ptc_hof_stack, []) do
      [top | rest] ->
        # EvalContext stores tool_calls/prints in prepend order (newest first).
        # Maintain prepend order in the stash: current invocation's newest first,
        # then previous invocations'.
        updated = %{
          tool_calls: ctx.tool_calls ++ top.tool_calls,
          prints: ctx.prints ++ top.prints
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

      [] ->
        eval_ctx
    end
  end

  # ============================================================
  # Closure Execution Helpers
  # ============================================================

  defp execute_closure(closure, args, eval_ctx, do_eval_fn) do
    {:closure, patterns, _body, _env, _th, _meta} = closure
    do_execute_closure(closure, patterns, args, eval_ctx, do_eval_fn)
  end

  defp do_execute_closure(
         {:closure, _closure_patterns, body, closure_env, closure_turn_history, _meta} = closure,
         binding_patterns,
         args,
         %EvalContext{ctx: ctx, user_ns: user_ns, tool_exec: tool_exec} = caller_ctx,
         do_eval_fn
       ) do
    case bind_args(binding_patterns, args) do
      {:ok, bindings} ->
        new_env = Map.merge(closure_env, bindings)
        closure_ctx = EvalContext.new(ctx, user_ns, new_env, tool_exec, closure_turn_history)

        # Carry accumulated state from caller so tool_calls/cache aren't lost across closure calls
        closure_ctx = %{
          closure_ctx
          | loop_limit: caller_ctx.loop_limit,
            prints: caller_ctx.prints,
            max_print_length: caller_ctx.max_print_length,
            pmap_timeout: caller_ctx.pmap_timeout,
            tool_calls: caller_ctx.tool_calls,
            pmap_calls: caller_ctx.pmap_calls,
            tool_cache: caller_ctx.tool_cache,
            summaries: caller_ctx.summaries,
            journal: caller_ctx.journal
        }

        case do_eval_fn.(body, closure_ctx) do
          {:ok, result, final_ctx} ->
            # Capture return type and update user_ns if this closure is a named function
            final_ctx = update_closure_return_type(closure, result, final_ctx)
            # Restore caller's environment, keep updated prints/user_ns
            {:ok, result, %{final_ctx | env: caller_ctx.env}}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  catch
    {:recur_signal, new_args, prints, tool_calls, tool_cache} ->
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
              # Preserve prints, tool_calls, and tool_cache across iterations
              updated_caller_ctx = %{
                updated_caller_ctx
                | prints: prints,
                  tool_calls: tool_calls,
                  tool_cache: tool_cache
              }

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
          Map.put(acc, name, {:closure, params, body, env, th, new_meta})

        _, acc ->
          acc
      end)

    %{ctx | user_ns: updated_user_ns}
  end

  defp derive_type(value), do: TypeVocabulary.type_of(value)

  defp bind_args({:variadic, leading, rest_pattern}, args) do
    {leading_args, rest_args} = Enum.split(args, length(leading))

    leading_res =
      Enum.zip(leading, leading_args)
      |> Enum.reduce_while({:ok, %{}}, fn {pattern, arg}, {:ok, acc} ->
        case Patterns.match_pattern(pattern, arg) do
          {:ok, bindings} -> {:cont, {:ok, Map.merge(acc, bindings)}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case leading_res do
      {:ok, leading_bindings} ->
        case Patterns.match_pattern(rest_pattern, rest_args) do
          {:ok, rest_bindings} -> {:ok, Map.merge(leading_bindings, rest_bindings)}
          {:error, _} = err -> err
        end

      err ->
        err
    end
  end

  defp bind_args(patterns, args) when is_list(patterns) do
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
