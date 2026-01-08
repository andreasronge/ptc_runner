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
  alias PtcRunner.Lisp.Env
  alias PtcRunner.Lisp.Eval.{Apply, Patterns, Where}
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Format.Var

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
          | {:cannot_shadow_builtin, atom()}

  @spec eval(CoreAST.t(), map(), map(), env(), tool_executor(), list()) ::
          {:ok, value(), map()} | {:error, runtime_error()}
  def eval(ast, ctx, memory, env, tool_executor, turn_history \\ []) do
    case eval_with_context(ast, ctx, memory, env, tool_executor, turn_history) do
      {:ok, result, %EvalContext{user_ns: user_ns}} -> {:ok, result, user_ns}
      {:error, _} = err -> err
    end
  end

  @spec eval_with_context(CoreAST.t(), map(), map(), env(), tool_executor(), list()) ::
          {:ok, value(), EvalContext.t()} | {:error, runtime_error()}
  def eval_with_context(ast, ctx, memory, env, tool_executor, turn_history \\ []) do
    eval_ctx = EvalContext.new(ctx, memory, env, tool_executor, turn_history)

    try do
      do_eval(ast, eval_ctx)
    catch
      {:return_signal, value, ctx} -> {:ok, {:return_signal, value}, ctx}
      {:fail_signal, value, ctx} -> {:ok, {:fail_signal, value}, ctx}
    end
  end

  # ============================================================
  # Turn history access: *1, *2, *3
  # ============================================================

  # *1 returns the most recent result (index -1), *2 the second-most-recent (index -2), etc.
  # Returns nil if the turn doesn't exist (e.g., *1 on turn 1)
  defp do_eval({:turn_history, n}, %EvalContext{turn_history: turn_history} = eval_ctx)
       when n in [1, 2, 3] do
    value = Enum.at(turn_history, -n, nil)
    {:ok, value, eval_ctx}
  end

  # ============================================================
  # Literals
  # ============================================================

  defp do_eval(nil, %EvalContext{} = eval_ctx), do: {:ok, nil, eval_ctx}
  defp do_eval(true, %EvalContext{} = eval_ctx), do: {:ok, true, eval_ctx}
  defp do_eval(false, %EvalContext{} = eval_ctx), do: {:ok, false, eval_ctx}

  defp do_eval(n, %EvalContext{} = eval_ctx) when is_number(n),
    do: {:ok, n, eval_ctx}

  defp do_eval({:string, s}, %EvalContext{} = eval_ctx), do: {:ok, s, eval_ctx}
  defp do_eval({:keyword, k}, %EvalContext{} = eval_ctx), do: {:ok, k, eval_ctx}

  # ============================================================
  # Collections
  # ============================================================

  # Vectors: evaluate all elements
  defp do_eval({:vector, elems}, %EvalContext{} = eval_ctx) do
    eval_all(elems, eval_ctx)
  end

  # Maps: evaluate all keys and values
  defp do_eval({:map, pairs}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(pairs, {:ok, [], eval_ctx}, fn {k_ast, v_ast}, {:ok, acc, ctx} ->
        eval_map_pair(k_ast, v_ast, ctx, acc)
      end)

    case result do
      {:ok, evaluated_pairs, eval_ctx2} -> {:ok, Map.new(evaluated_pairs), eval_ctx2}
      {:error, _} = err -> err
    end
  end

  # Sets: evaluate all elements, then create MapSet
  defp do_eval({:set, elems}, %EvalContext{} = eval_ctx) do
    case eval_all(elems, eval_ctx) do
      {:ok, values, eval_ctx2} -> {:ok, MapSet.new(values), eval_ctx2}
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Variables and namespace access
  # ============================================================

  # Local/global variable from environment
  # Resolution order: let bindings (env) → user namespace (def bindings) → builtins
  defp do_eval({:var, name}, %EvalContext{user_ns: user_ns, env: env} = eval_ctx) do
    cond do
      Map.has_key?(env, name) ->
        {:ok, Map.get(env, name), eval_ctx}

      Map.has_key?(user_ns, name) ->
        {:ok, Map.get(user_ns, name), eval_ctx}

      Env.builtin?(name) ->
        {:ok, Map.get(Env.initial(), name), eval_ctx}

      true ->
        name_str = to_string(name)

        if String.starts_with?(name_str, ".") do
          available =
            Env.builtins_by_category(:interop)
            |> Enum.map_join(", ", &to_string/1)

          {:error,
           {:unbound_var,
            "Unknown method '#{name_str}'. Supported interop methods: #{available}. Use (.method obj) syntax."}}
        else
          {:error, {:unbound_var, name}}
        end
    end
  end

  # Context access: ctx/input → ctx[:input]
  defp do_eval({:ctx, key}, %EvalContext{ctx: ctx} = eval_ctx) do
    {:ok, flex_get(ctx, key), eval_ctx}
  end

  # Define binding in user namespace: (def name value)
  # Returns the var, not the value (Clojure semantics)
  defp do_eval({:def, name, value_ast}, %EvalContext{} = eval_ctx) do
    if Env.builtin?(name) do
      {:error, {:cannot_shadow_builtin, name}}
    else
      with {:ok, value, eval_ctx2} <- do_eval(value_ast, eval_ctx) do
        new_user_ns = Map.put(eval_ctx2.user_ns, name, value)
        {:ok, %Var{name: name}, EvalContext.update_user_ns(eval_ctx2, new_user_ns)}
      end
    end
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
    with {:ok, cond_val, eval_ctx2} <- do_eval(cond_ast, eval_ctx) do
      if Where.truthy?(cond_val) do
        do_eval(then_ast, eval_ctx2)
      else
        do_eval(else_ast, eval_ctx2)
      end
    end
  end

  # Let bindings
  defp do_eval({:let, bindings, body}, %EvalContext{} = eval_ctx) do
    result =
      Enum.reduce_while(bindings, {:ok, eval_ctx}, fn {:binding, pattern, value_ast},
                                                      {:ok, acc_ctx} ->
        case do_eval(value_ast, acc_ctx) do
          {:ok, value, eval_ctx2} ->
            case Patterns.match_pattern(pattern, value) do
              {:ok, new_bindings} ->
                {:cont,
                 {:ok,
                  eval_ctx2
                  |> EvalContext.merge_env(new_bindings)}}

              {:error, _} = err ->
                {:halt, err}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    case result do
      {:ok, new_ctx} ->
        case do_eval(body, new_ctx) do
          {:ok, value, final_ctx} ->
            # Restore the original environment from before the let block
            {:ok, value, %{final_ctx | env: eval_ctx.env}}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # Tail recursion: loop
  defp do_eval({:loop, bindings, body}, %EvalContext{} = eval_ctx) do
    # 1. Initial bindings evaluation (like let)
    result =
      Enum.reduce_while(bindings, {:ok, eval_ctx}, fn {:binding, pattern, value_ast},
                                                      {:ok, acc_ctx} ->
        case do_eval(value_ast, acc_ctx) do
          {:ok, value, eval_ctx2} ->
            case Patterns.match_pattern(pattern, value) do
              {:ok, new_bindings} ->
                {:cont, {:ok, EvalContext.merge_env(eval_ctx2, new_bindings)}}

              {:error, _} = err ->
                {:halt, err}
            end

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    case result do
      {:ok, loop_ctx} ->
        case execute_loop(body, loop_ctx, bindings) do
          {:ok, value, final_ctx} ->
            # Restore the original environment from before the loop
            {:ok, value, %{final_ctx | env: eval_ctx.env}}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # Tail recursion: recur signal
  defp do_eval({:recur, arg_asts}, %EvalContext{} = eval_ctx) do
    # Evaluate arguments in current context
    case eval_all(arg_asts, eval_ctx) do
      {:ok, values, ctx} ->
        # Include prints in signal so they're preserved across iterations
        throw({:recur_signal, values, ctx.prints})

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Function definition: fn
  # ============================================================

  defp do_eval({:fn, params, body}, %EvalContext{} = eval_ctx) do
    # Capture the current environment and turn history (lexical scoping)
    # We also capture the user_ns snapshot as before.
    {:ok, {:closure, params, body, eval_ctx.env, eval_ctx.turn_history}, eval_ctx}
  end

  # ============================================================
  # Function calls
  # ============================================================

  defp do_eval({:call, fun_ast, arg_asts}, %EvalContext{} = eval_ctx) do
    with {:ok, fun_val, eval_ctx1} <- do_eval(fun_ast, eval_ctx),
         {:ok, arg_vals, eval_ctx2} <- eval_all(arg_asts, eval_ctx1) do
      Apply.apply_fun(
        fun_val,
        arg_vals,
        eval_ctx2,
        &do_eval/2
      )
    end
  end

  # ============================================================
  # Where predicates
  # ============================================================

  defp do_eval({:where, field_path, op, value_ast}, %EvalContext{} = eval_ctx) do
    # Evaluate the comparison value (if not truthy check)
    case value_ast do
      nil ->
        accessor = Where.build_field_accessor(field_path)
        fun = Where.build_where_predicate(op, accessor, nil)
        {:ok, fun, eval_ctx}

      _ ->
        with {:ok, value, eval_ctx2} <- do_eval(value_ast, eval_ctx) do
          accessor = Where.build_field_accessor(field_path)
          fun = Where.build_where_predicate(op, accessor, value)
          {:ok, fun, eval_ctx2}
        end
    end
  end

  # ============================================================
  # Predicate combinators
  # ============================================================

  defp do_eval({:pred_combinator, kind, pred_asts}, %EvalContext{} = eval_ctx) do
    case eval_all(pred_asts, eval_ctx) do
      {:ok, pred_fns, eval_ctx2} ->
        fun = Where.build_pred_combinator(kind, pred_fns)
        {:ok, fun, eval_ctx2}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Function combinator: juxt
  # ============================================================

  defp do_eval({:juxt, func_asts}, %EvalContext{} = eval_ctx) do
    case eval_all(func_asts, eval_ctx) do
      {:ok, fns, eval_ctx2} ->
        # Convert each fn to Erlang function (handles closures, keywords, builtins)
        erlang_fns = Enum.map(fns, &value_to_erlang_fn(&1, eval_ctx2))
        fun = build_juxt_fn(erlang_fns)
        {:ok, fun, eval_ctx2}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Parallel map: pmap
  # ============================================================

  defp do_eval({:pmap, fn_ast, coll_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, fn_val, eval_ctx1} <- do_eval(fn_ast, eval_ctx),
         {:ok, coll_val, eval_ctx2} <- do_eval(coll_ast, eval_ctx1) do
      # Consistency check: keywords don't work with single hash-map in map/pmap
      if is_atom(fn_val) and not is_boolean(fn_val) and is_map(coll_val) and
           not is_struct(coll_val) do
        {:error,
         {:type_error, "pmap: keyword accessor requires a list of maps, got a single map",
          [fn_val, coll_val]}}
      else
        # Convert the function value to an Erlang function
        # The closure captures a read-only snapshot of the environment at creation time
        erlang_fn = value_to_erlang_fn(fn_val, eval_ctx2)

        # Execute in parallel using Task.async_stream
        # Limit concurrency to available schedulers to prevent resource exhaustion
        # when LLM generates pmap over large collections (e.g., unbounded search results)
        results =
          coll_val
          |> Task.async_stream(
            fn elem ->
              try do
                {:ok, erlang_fn.(elem)}
              rescue
                e ->
                  {:error, {:pmap_error, Exception.message(e)}}
              catch
                {:return_signal, _, _} ->
                  {:error, {:pmap_error, "return called inside pmap"}}

                {:fail_signal, _, _} ->
                  {:error, {:pmap_error, "fail called inside pmap"}}
              end
            end,
            timeout: 5_000,
            ordered: true,
            max_concurrency: System.schedulers_online() * 2
          )
          |> Enum.to_list()

        # Collect results, stopping at first error
        collect_pmap_results(results, [], eval_ctx2)
      end
    end
  end

  # ============================================================
  # Parallel calls: pcalls
  # ============================================================

  defp do_eval({:pcalls, fn_asts}, %EvalContext{} = eval_ctx) do
    # First evaluate all function expressions to get function values
    case eval_all(fn_asts, eval_ctx) do
      {:ok, fn_vals, eval_ctx2} ->
        # Convert each function value to an Erlang function (zero-arity thunk)
        # Use a try/rescue to catch validation errors (wrong arity, non-callable)
        try do
          erlang_fns =
            fn_vals
            |> Enum.with_index()
            |> Enum.map(fn {fn_val, idx} ->
              {pcalls_fn_to_erlang(fn_val, eval_ctx2), idx}
            end)

          # Execute all thunks in parallel using Task.async_stream
          # Limit concurrency to prevent resource exhaustion
          results =
            erlang_fns
            |> Task.async_stream(
              fn {erlang_fn, idx} ->
                try do
                  {:ok, erlang_fn.(), idx}
                rescue
                  e ->
                    {:error, {:pcalls_error, idx, Exception.message(e)}}
                catch
                  {:return_signal, _, _} ->
                    {:error, {:pcalls_error, idx, "return called inside pcalls"}}

                  {:fail_signal, _, _} ->
                    {:error, {:pcalls_error, idx, "fail called inside pcalls"}}
                end
              end,
              timeout: 5_000,
              ordered: true,
              max_concurrency: System.schedulers_online() * 2
            )
            |> Enum.to_list()

          # Collect results, stopping at first error
          collect_pcalls_results(results, [], eval_ctx2)
        rescue
          e in RuntimeError ->
            {:error, {:pcalls_error, Exception.message(e)}}
        end

      {:error, _} = err ->
        err
    end
  end

  # Control flow signals: return and fail
  defp do_eval({:return, value_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- do_eval(value_ast, eval_ctx) do
      throw({:return_signal, value, eval_ctx2})
    end
  end

  defp do_eval({:fail, error_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, error, eval_ctx2} <- do_eval(error_ast, eval_ctx) do
      throw({:fail_signal, error, eval_ctx2})
    end
  end

  # Builtin calls (other tools)
  defp do_eval(
         {:builtin_call, tool_name, args_ast},
         %EvalContext{tool_exec: tool_exec} = eval_ctx
       ) do
    with {:ok, args_map, eval_ctx2} <- do_eval(args_ast, eval_ctx) do
      # Call the tool executor provided by the host
      result = tool_exec.(tool_name, args_map)
      {:ok, result, eval_ctx2}
    end
  end

  # Tool invocation via ctx namespace: (ctx/tool-name args...)
  defp do_eval({:ctx_call, tool_name, arg_asts}, %EvalContext{tool_exec: tool_exec} = eval_ctx) do
    # Evaluate all arguments
    case eval_all(arg_asts, eval_ctx) do
      {:ok, arg_vals, eval_ctx2} ->
        # Convert args list to map for tool executor
        args_map = build_args_map(arg_vals)
        # Convert atom to string for backward compatibility with tool_exec
        tool_result = tool_exec.(Atom.to_string(tool_name), args_map)
        {:ok, tool_result, eval_ctx2}

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
    with {:ok, k, eval_ctx2} <- do_eval(k_ast, eval_ctx),
         {:ok, v, eval_ctx3} <- do_eval(v_ast, eval_ctx2) do
      {:cont, {:ok, [{k, v} | acc], eval_ctx3}}
    else
      {:error, _} = err -> {:halt, err}
    end
  end

  # Evaluate all expressions in order, returning results in original order
  defp eval_all(asts, eval_ctx) do
    result =
      Enum.reduce_while(asts, {:ok, [], eval_ctx}, fn ast, {:ok, acc, ctx} ->
        case do_eval(ast, ctx) do
          {:ok, v, ctx2} -> {:cont, {:ok, [v | acc], ctx2}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, vals, ctx} -> {:ok, Enum.reverse(vals), ctx}
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Sequential evaluation helpers
  # ============================================================

  defp do_eval_do([], %EvalContext{} = eval_ctx), do: {:ok, nil, eval_ctx}

  defp do_eval_do([e], %EvalContext{} = eval_ctx) do
    do_eval(e, eval_ctx)
  end

  defp do_eval_do([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, _value, eval_ctx2} <- do_eval(e, eval_ctx) do
      do_eval_do(rest, eval_ctx2)
    end
  end

  # ============================================================
  # Short-circuit logic helpers
  # ============================================================

  defp do_eval_and([], %EvalContext{} = eval_ctx), do: {:ok, true, eval_ctx}

  defp do_eval_and([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        do_eval_and(rest, eval_ctx2)
      else
        # Short-circuit: return falsy value
        {:ok, value, eval_ctx2}
      end
    end
  end

  defp do_eval_or([], %EvalContext{} = eval_ctx), do: {:ok, nil, eval_ctx}

  defp do_eval_or([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        # Short-circuit: return truthy value
        {:ok, value, eval_ctx2}
      else
        # Continue evaluating, tracking this value as last evaluated
        do_eval_or_rest(rest, value, eval_ctx2)
      end
    end
  end

  defp do_eval_or_rest([], last_value, %EvalContext{} = eval_ctx) do
    {:ok, last_value, eval_ctx}
  end

  defp do_eval_or_rest([e | rest], _last_value, %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- do_eval(e, eval_ctx) do
      if Where.truthy?(value) do
        # Short-circuit: return truthy value
        {:ok, value, eval_ctx2}
      else
        # Continue evaluating, tracking this value as last evaluated
        do_eval_or_rest(rest, value, eval_ctx2)
      end
    end
  end

  # ============================================================
  # Shared helpers
  # ============================================================

  # Convert a value to an Erlang function for use in juxt, pmap, etc.
  # Keywords need special handling as map accessors
  defp value_to_erlang_fn(k, %EvalContext{}) when is_atom(k) and not is_boolean(k) do
    fn m -> flex_get(m, k) end
  end

  defp value_to_erlang_fn(value, %EvalContext{} = eval_ctx) do
    Apply.closure_to_fun(value, eval_ctx, &do_eval/2)
  end

  # ============================================================
  # Juxt helpers
  # ============================================================

  # Build juxt function that applies all functions and returns vector of results
  defp build_juxt_fn(fns), do: fn arg -> Enum.map(fns, & &1.(arg)) end

  # ============================================================
  # Pmap helpers
  # ============================================================

  # Helper to collect pmap results, preserving order and detecting errors
  defp collect_pmap_results([], acc, eval_ctx), do: {:ok, Enum.reverse(acc), eval_ctx}

  defp collect_pmap_results([{:ok, {:ok, val}} | rest], acc, eval_ctx) do
    collect_pmap_results(rest, [val | acc], eval_ctx)
  end

  defp collect_pmap_results([{:ok, {:error, reason}} | _rest], _acc, _eval_ctx) do
    {:error, reason}
  end

  defp collect_pmap_results([{:exit, reason} | _rest], _acc, _eval_ctx) do
    {:error, {:pmap_error, "parallel task failed: #{inspect(reason)}"}}
  end

  # ============================================================
  # Pcalls helpers
  # ============================================================

  # Convert a closure to a zero-arity Erlang function for use in pcalls
  defp pcalls_fn_to_erlang(
         {:closure, [], body, closure_env, turn_history},
         %EvalContext{} = eval_ctx
       ) do
    fn ->
      ctx =
        EvalContext.new(
          eval_ctx.ctx,
          eval_ctx.user_ns,
          closure_env,
          eval_ctx.tool_exec,
          turn_history
        )

      ctx = %{ctx | loop_limit: eval_ctx.loop_limit, prints: eval_ctx.prints}

      case do_eval(body, ctx) do
        {:ok, result, _ctx2} -> result
        {:error, reason} -> raise "pcalls function failed: #{inspect(reason)}"
      end
    end
  end

  defp pcalls_fn_to_erlang({:closure, params, _body, _closure_env, _turn_history}, %EvalContext{}) do
    arity = length(params)
    raise "pcalls requires zero-arity thunks, got function with arity #{arity}"
  end

  defp pcalls_fn_to_erlang(f, %EvalContext{}) when is_function(f, 0) do
    f
  end

  defp pcalls_fn_to_erlang(f, %EvalContext{}) when is_function(f) do
    {:arity, arity} = Function.info(f, :arity)
    raise "pcalls requires zero-arity thunks, got function with arity #{arity}"
  end

  defp pcalls_fn_to_erlang(value, %EvalContext{}) do
    raise "pcalls requires callable thunks, got: #{inspect(value)}"
  end

  # Helper to collect pcalls results, preserving order and detecting errors
  defp collect_pcalls_results([], acc, eval_ctx), do: {:ok, Enum.reverse(acc), eval_ctx}

  defp collect_pcalls_results([{:ok, {:ok, val, _idx}} | rest], acc, eval_ctx) do
    collect_pcalls_results(rest, [val | acc], eval_ctx)
  end

  defp collect_pcalls_results([{:ok, {:error, reason}} | _rest], _acc, _eval_ctx) do
    {:error, reason}
  end

  defp collect_pcalls_results([{:exit, reason} | _rest], _acc, _eval_ctx) do
    {:error, {:pcalls_error, "parallel task failed: #{inspect(reason)}"}}
  end

  # ============================================================
  # Loop Execution
  # ============================================================

  defp execute_loop(body, %EvalContext{} = ctx, bindings) do
    do_eval(body, ctx)
  catch
    {:recur_signal, new_values, prints} ->
      patterns = Enum.map(bindings, fn {:binding, p, _} -> p end)

      if length(patterns) != length(new_values) do
        {:error, {:arity_mismatch, length(patterns), length(new_values)}}
      else
        case bind_recur_values(patterns, new_values) do
          {:ok, new_bindings} ->
            case EvalContext.increment_iteration(ctx) do
              {:ok, ctx2} ->
                # Preserve prints from this iteration
                ctx3 = %{ctx2 | prints: prints}
                execute_loop(body, EvalContext.merge_env(ctx3, new_bindings), bindings)

              {:error, :loop_limit_exceeded} ->
                {:error, {:loop_limit_exceeded, ctx.loop_limit}}
            end

          {:error, _} = err ->
            err
        end
      end
  end

  defp bind_recur_values(patterns, values) do
    Enum.zip(patterns, values)
    |> Enum.reduce_while({:ok, %{}}, fn {p, v}, {:ok, acc} ->
      case Patterns.match_pattern(p, v) do
        {:ok, b} -> {:cont, {:ok, Map.merge(acc, b)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
