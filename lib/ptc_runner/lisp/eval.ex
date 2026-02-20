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

  require Logger

  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.Env
  alias PtcRunner.Lisp.Eval.{Apply, Patterns, Where}
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.ExecutionError
  alias PtcRunner.Lisp.Format.Var
  alias PtcRunner.Lisp.Runtime.Callable
  alias PtcRunner.SubAgent.KeyNormalizer
  alias PtcRunner.TraceContext

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
          | {:closure, [CoreAST.pattern()], CoreAST.t(), env(), list(), map()}

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

  @spec eval(CoreAST.t(), map(), map(), env(), tool_executor(), list(), keyword()) ::
          {:ok, value(), map()} | {:error, runtime_error()}
  def eval(ast, ctx, memory, env, tool_executor, turn_history \\ [], opts \\ []) do
    case eval_with_context(ast, ctx, memory, env, tool_executor, turn_history, opts) do
      {:ok, result, %EvalContext{user_ns: user_ns}} -> {:ok, result, user_ns}
      {:error, _} = err -> err
    end
  end

  @spec eval_with_context(CoreAST.t(), map(), map(), env(), tool_executor(), list(), keyword()) ::
          {:ok, value(), EvalContext.t()} | {:error, runtime_error()}
  def eval_with_context(ast, ctx, memory, env, tool_executor, turn_history \\ [], opts \\ []) do
    eval_ctx = EvalContext.new(ctx, memory, env, tool_executor, turn_history, opts)

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
  # Budget introspection: (budget/remaining)
  # ============================================================

  # Returns the budget info map, or empty map if running standalone (not in SubAgent loop)
  defp do_eval({:budget_remaining}, %EvalContext{budget: budget} = eval_ctx) do
    {:ok, budget || %{}, eval_ctx}
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
  defp do_eval({:literal, v}, %EvalContext{} = eval_ctx), do: {:ok, v, eval_ctx}
  defp do_eval(a, %EvalContext{} = eval_ctx) when is_atom(a), do: {:ok, a, eval_ctx}

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
        case Map.get(Env.initial(), name) do
          {:constant, value} -> {:ok, value, eval_ctx}
          _ -> {:ok, Map.get(Env.initial(), name), eval_ctx}
        end

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

  # Data access: data/input → ctx[:input]
  defp do_eval({:data, key}, %EvalContext{ctx: ctx} = eval_ctx) do
    {:ok, flex_get(ctx, key), eval_ctx}
  end

  # Define binding in user namespace: (def name value opts)
  # Returns the var, not the value (Clojure semantics)
  # Opts may contain :docstring which is merged into closure metadata for functions
  defp do_eval({:def, name, value_ast, opts}, %EvalContext{} = eval_ctx) do
    if Env.builtin?(name) do
      {:error, {:cannot_shadow_builtin, name}}
    else
      with {:ok, value, eval_ctx2} <- do_eval(value_ast, eval_ctx) do
        # Merge docstring into closure metadata if value is a closure
        value = merge_docstring_into_closure(value, opts)
        new_user_ns = Map.put(eval_ctx2.user_ns, name, value)
        {:ok, %Var{name: name}, EvalContext.update_user_ns(eval_ctx2, new_user_ns)}
      end
    end
  end

  # Backward compatibility: 3-tuple format without opts
  defp do_eval({:def, name, value_ast}, %EvalContext{} = eval_ctx) do
    do_eval({:def, name, value_ast, %{}}, eval_ctx)
  end

  # Idempotent define: (defonce name value opts)
  # Binds name only if not already defined in user_ns.
  # Value expression is NOT evaluated when name is already bound.
  defp do_eval({:defonce, name, value_ast, opts}, %EvalContext{user_ns: user_ns} = eval_ctx) do
    cond do
      Env.builtin?(name) ->
        {:error, {:cannot_shadow_builtin, name}}

      Map.has_key?(user_ns, name) ->
        {:ok, %Var{name: name}, eval_ctx}

      true ->
        with {:ok, value, eval_ctx2} <- do_eval(value_ast, eval_ctx) do
          value = merge_docstring_into_closure(value, opts)
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
        # Include accumulated state in signal so it's preserved across iterations
        throw({:recur_signal, values, ctx.prints, ctx.tool_calls, ctx.tool_cache})

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
    # Metadata starts empty; return_type is populated when closure is called
    {:ok, {:closure, params, body, eval_ctx.env, eval_ctx.turn_history, %{}}, eval_ctx}
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
        # Record start time for pmap execution
        start_time = System.monotonic_time(:millisecond)
        timestamp = DateTime.utc_now()
        coll_list = Enum.to_list(coll_val)
        count = length(coll_list)

        # Convert the function value to a callable (may be a tuple for builtins)
        # The closure captures a read-only snapshot of the environment at creation time
        callable_fn = value_to_erlang_fn(fn_val, eval_ctx2)

        # Capture trace context for propagation into worker processes
        trace_ctx = TraceContext.capture()

        # Execute in parallel using Task.async_stream
        # Limit concurrency to available schedulers to prevent resource exhaustion
        # when LLM generates pmap over large collections (e.g., unbounded search results)
        # Timeout is configurable via pmap_timeout for LLM-backed tool calls
        results =
          coll_list
          |> Task.async_stream(
            fn elem ->
              # Re-attach trace context in worker process
              TraceContext.attach(trace_ctx)

              try do
                TraceContext.take_child_result()
                value = Callable.call(callable_fn, [elem])

                case TraceContext.take_child_result() do
                  {trace_id, child_step} -> {:ok, value, trace_id, child_step}
                  nil -> {:ok, value, nil, nil}
                end
              rescue
                e in PtcRunner.ToolExecutionError ->
                  {:error, {:pmap_error, "tool '#{e.tool_name}' failed: #{e.message}"}}

                e ->
                  {:error, {:pmap_error, Exception.message(e)}}
              catch
                {:return_signal, _, _} ->
                  {:error, {:pmap_error, "return called inside pmap"}}

                {:fail_signal, _, _} ->
                  {:error, {:pmap_error, "fail called inside pmap"}}
              end
            end,
            timeout: eval_ctx2.pmap_timeout,
            ordered: true,
            max_concurrency: System.schedulers_online() * 2
          )
          |> Enum.to_list()

        # Collect results and child trace IDs
        duration_ms = System.monotonic_time(:millisecond) - start_time

        case collect_parallel_results(results, :pmap) do
          {:ok, values, child_trace_ids, child_steps} ->
            # Count successes and errors
            success_count = length(values)
            error_count = count - success_count

            # Record pmap execution
            pmap_call = %{
              type: :pmap,
              count: count,
              child_trace_ids: Enum.reject(child_trace_ids, &is_nil/1),
              child_steps: Enum.reject(child_steps, &is_nil/1),
              timestamp: timestamp,
              duration_ms: duration_ms,
              success_count: success_count,
              error_count: error_count
            }

            eval_ctx3 = EvalContext.append_pmap_call(eval_ctx2, pmap_call)
            {:ok, values, eval_ctx3}

          {:error, reason} ->
            {:error, reason}
        end
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
        # Record start time for pcalls execution
        start_time = System.monotonic_time(:millisecond)
        timestamp = DateTime.utc_now()
        count = length(fn_vals)

        # Convert each function value to an Erlang function (zero-arity thunk)
        # Use a try/rescue to catch validation errors (wrong arity, non-callable)
        try do
          erlang_fns =
            fn_vals
            |> Enum.with_index()
            |> Enum.map(fn {fn_val, idx} ->
              {pcalls_fn_to_erlang(fn_val, eval_ctx2), idx}
            end)

          # Capture trace context for propagation into worker processes
          trace_ctx = TraceContext.capture()

          # Execute all thunks in parallel using Task.async_stream
          # Limit concurrency to prevent resource exhaustion
          # Timeout is configurable via pmap_timeout for LLM-backed tool calls
          results =
            erlang_fns
            |> Task.async_stream(
              fn {erlang_fn, idx} ->
                # Re-attach trace context in worker process
                TraceContext.attach(trace_ctx)

                try do
                  TraceContext.take_child_result()
                  value = erlang_fn.()

                  case TraceContext.take_child_result() do
                    {trace_id, child_step} -> {:ok, value, trace_id, idx, child_step}
                    nil -> {:ok, value, nil, idx, nil}
                  end
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
              timeout: eval_ctx2.pmap_timeout,
              ordered: true,
              max_concurrency: System.schedulers_online() * 2
            )
            |> Enum.to_list()

          # Collect results and child trace IDs
          duration_ms = System.monotonic_time(:millisecond) - start_time

          case collect_parallel_results(results, :pcalls) do
            {:ok, values, child_trace_ids, child_steps} ->
              # Count successes and errors
              success_count = length(values)
              error_count = count - success_count

              # Record pcalls execution
              pmap_call = %{
                type: :pcalls,
                count: count,
                child_trace_ids: Enum.reject(child_trace_ids, &is_nil/1),
                child_steps: Enum.reject(child_steps, &is_nil/1),
                timestamp: timestamp,
                duration_ms: duration_ms,
                success_count: success_count,
                error_count: error_count
              }

              eval_ctx3 = EvalContext.append_pmap_call(eval_ctx2, pmap_call)
              {:ok, values, eval_ctx3}

            {:error, reason} ->
              {:error, reason}
          end
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

  # Dynamic task ID: (task id-expr expr) — evaluate id-expr to get the string ID
  defp do_eval({:task_dynamic, id_ast, body_ast}, eval_ctx) do
    with {:ok, id, eval_ctx} <- do_eval(id_ast, eval_ctx) do
      id = to_string(id)
      do_eval({:task, id, body_ast}, eval_ctx)
    end
  end

  # Journaled task: (task "id" expr)
  # Cache hit: return stored value, skip expr
  # Cache miss: evaluate expr, commit to journal
  # No journal (nil): execute normally, emit trace warning
  # Fail/crash inside expr: do NOT commit to journal, propagate failure
  defp do_eval({:task, id, body_ast}, %EvalContext{journal: journal} = eval_ctx) do
    case journal do
      nil ->
        # No journal - execute without caching, emit trace warning
        Logger.debug(
          "PTC task '#{id}' executed without journal: caching and idempotency are inactive"
        )

        do_eval(body_ast, eval_ctx)

      %{} ->
        if Map.has_key?(journal, id) do
          # Cache hit - return stored value without evaluating expr
          {:ok, Map.get(journal, id), eval_ctx}
        else
          # Cache miss - evaluate and commit on success
          # If body throws (fail_signal or crash), it propagates without committing
          with {:ok, value, eval_ctx2} <- do_eval(body_ast, eval_ctx) do
            updated_journal = Map.put(eval_ctx2.journal, id, value)
            {:ok, value, %{eval_ctx2 | journal: updated_journal}}
          end
        end
    end
  end

  # Step done: (step-done id summary)
  # Stores summary in summaries map, returns the summary string
  defp do_eval({:step_done, id_ast, summary_ast}, eval_ctx) do
    with {:ok, id, eval_ctx} <- do_eval(id_ast, eval_ctx),
         {:ok, summary, eval_ctx} <- do_eval(summary_ast, eval_ctx) do
      id = require_string_arg!(id, "step-done", "id")
      summary = require_string_arg!(summary, "step-done", "summary")
      updated_summaries = Map.put(eval_ctx.summaries, id, summary)
      {:ok, summary, %{eval_ctx | summaries: updated_summaries}}
    end
  end

  # Task reset: (task-reset id)
  # Deletes key from journal map, returns nil
  defp do_eval({:task_reset, id_ast}, eval_ctx) do
    with {:ok, id, eval_ctx} <- do_eval(id_ast, eval_ctx) do
      id = require_string_arg!(id, "task-reset", "id")

      updated_journal =
        case eval_ctx.journal do
          %{} -> Map.delete(eval_ctx.journal, id)
          nil -> nil
        end

      {:ok, nil, %{eval_ctx | journal: updated_journal}}
    end
  end

  # Tool invocation via tool/ namespace: (tool/name args...)
  defp do_eval({:tool_call, tool_name, arg_asts}, %EvalContext{tool_exec: tool_exec} = eval_ctx) do
    # Evaluate all arguments
    case eval_all(arg_asts, eval_ctx) do
      {:ok, arg_vals, eval_ctx2} ->
        # Convert args list to map for tool executor
        case build_args_map(arg_vals, tool_name) do
          {:ok, args_map} ->
            # Convert atom to string for backward compatibility with tool_exec
            tool_name_str = Atom.to_string(tool_name)
            # Check if this tool has caching enabled
            cacheable? = get_in(eval_ctx2.tools_meta, [tool_name_str, :cache]) == true
            record_tool_call(tool_name_str, args_map, tool_exec, eval_ctx2, cacheable?)

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Evaluation helpers
  # ============================================================

  # Merge docstring from def opts into closure metadata
  defp merge_docstring_into_closure(
         {:closure, params, body, env, turn_history, metadata},
         %{docstring: docstring}
       ) do
    {:closure, params, body, env, turn_history, Map.put(metadata, :docstring, docstring)}
  end

  defp merge_docstring_into_closure(value, _opts), do: value

  # Build args map from a list of evaluated arguments for tool calls.
  # Tools require named arguments (maps). Returns {:ok, map} or {:error, reason}.
  # - No arguments: return empty map
  # - Single map argument: pass through as-is (keys converted to strings)
  # - Keyword-style list [:key1, val1, :key2, val2]: convert to map with string keys
  # - Other cases: error (positional arguments not allowed)
  #
  # All maps are converted to string keys at the tool boundary to:
  # - Prevent atom memory leaks from LLM-generated keywords
  # - Match JSON conventions (like Phoenix params)
  defp build_args_map([], _tool_name), do: {:ok, %{}}
  defp build_args_map([arg], _tool_name) when is_map(arg), do: {:ok, stringify_keys(arg)}

  defp build_args_map(args, tool_name) do
    if keyword_style_args?(args) do
      {:ok, args_to_string_map(args)}
    else
      hint =
        case args do
          [single] when is_binary(single) ->
            " Got string \"#{String.slice(single, 0, 40)}\" — try (tool/#{tool_name} {:url \"...\"})"

          [single] ->
            " Got #{inspect(single, limit: 3, printable_limit: 40)} — wrap in {:key value}"

          _ ->
            ""
        end

      {:error,
       {:invalid_tool_args,
        "Tool calls require named arguments. Use (tool/#{tool_name} {:key value}), not positional args.#{hint}"}}
    end
  end

  # Check if args list is keyword-style: [:key1, val1, :key2, val2, ...]
  # Must have even length and odd positions (0, 2, 4...) must be atoms
  defp keyword_style_args?(args) when rem(length(args), 2) == 0 do
    args
    |> Enum.chunk_every(2)
    |> Enum.all?(fn [k, _v] -> is_atom(k) end)
  end

  defp keyword_style_args?(_), do: false

  # Convert keyword-style args to string-keyed map: [:key1, val1, :key2, val2] -> %{"key1" => val1}
  # Values are recursively stringified to handle nested maps/lists.
  defp args_to_string_map(args) do
    args
    |> Enum.chunk_every(2)
    |> Map.new(fn [k, v] -> {stringify_key(k), stringify_value(v)} end)
  end

  # Recursively convert map keys to strings (for tool boundary).
  # Handles nested maps and lists to ensure full protection against atom leaks.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), stringify_value(v)} end)
  end

  # Recursively stringify values (for nested maps/lists in tool args)
  defp stringify_value(map) when is_map(map), do: stringify_keys(map)
  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(other), do: other

  defp stringify_key(k) when is_atom(k), do: KeyNormalizer.normalize_key(k)
  defp stringify_key(k) when is_binary(k), do: KeyNormalizer.normalize_key(k)
  defp stringify_key(k), do: inspect(k)

  # Record a tool call with timing, execution, error capture, and evaluation context update.
  # Captures the error field if the tool raises an exception, records it, and throws a special
  # exception that includes the updated eval_ctx so the error can be properly reported.
  #
  # When `cacheable?` is true, results are cached by `{tool_name, args_map}`.
  # Cache hits return immediately with `duration_ms: 0` and `cached: true`.
  # Only successful results are cached; errors are not stored.
  #
  # Also handles SubAgentTool results that may be wrapped with child_trace_id metadata.
  # The wrapper is unwrapped here so the Lisp interpreter only sees the actual value.
  defp record_tool_call(tool_name, args_map, tool_exec, eval_ctx, cacheable?) do
    case EvalContext.check_tool_call_limit(eval_ctx) do
      {:error, :tool_call_limit_exceeded} ->
        {:error, {:tool_call_limit_exceeded, eval_ctx.max_tool_calls}}

      :ok ->
        record_tool_call_inner(tool_name, args_map, tool_exec, eval_ctx, cacheable?)
    end
  end

  defp record_tool_call_inner(tool_name, args_map, tool_exec, eval_ctx, cacheable?) do
    cache_key = {tool_name, args_map}

    # Check cache for hit (cached calls don't count against limit - already counted)
    if cacheable? and Map.has_key?(eval_ctx.tool_cache, cache_key) do
      cached = Map.get(eval_ctx.tool_cache, cache_key)

      tool_call = %{
        name: tool_name,
        args: args_map,
        result: cached.result,
        error: nil,
        timestamp: DateTime.utc_now(),
        duration_ms: 0,
        cached: true
      }

      # Restore child_step and child_trace_id from cache for TraceTree
      tool_call =
        if cached.child_trace_id,
          do: Map.put(tool_call, :child_trace_id, cached.child_trace_id),
          else: tool_call

      tool_call =
        if cached.child_step,
          do: Map.put(tool_call, :child_step, cached.child_step),
          else: tool_call

      eval_ctx2 = EvalContext.append_tool_call(eval_ctx, tool_call)
      {:ok, cached.result, eval_ctx2}
    else
      record_tool_call_execute(tool_name, args_map, tool_exec, eval_ctx, cacheable?, cache_key)
    end
  end

  defp record_tool_call_execute(tool_name, args_map, tool_exec, eval_ctx, cacheable?, cache_key) do
    start_time = System.monotonic_time(:millisecond)
    timestamp = DateTime.utc_now()

    {raw_result, error, error_child_step, error_child_trace_id} =
      try do
        {tool_exec.(tool_name, args_map), nil, nil, nil}
      rescue
        e in ExecutionError ->
          if e.child_step do
            # Failed SubAgent call — capture child info and record as tool error
            {nil, format_execution_error(e), e.child_step, e.child_trace_id}
          else
            # Other ExecutionErrors (unknown tool, validation, etc.) — propagate as before
            reraise e, __STACKTRACE__
          end

        e ->
          # Catch unexpected exceptions and record the error
          {nil, Exception.message(e), nil, nil}
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    # Unwrap SubAgentTool results that include child_trace_id/child_step metadata
    # This prevents internal trace metadata from leaking to the Lisp interpreter
    {result, child_trace_id, child_step} = unwrap_tool_result(raw_result)

    # Merge in child info from error path (failed SubAgent tools)
    child_trace_id = child_trace_id || error_child_trace_id
    child_step = child_step || error_child_step

    tool_call = %{
      name: tool_name,
      args: args_map,
      result: result,
      error: error,
      timestamp: timestamp,
      duration_ms: duration_ms
    }

    # Add child_trace_id if present (from SubAgentTool execution)
    tool_call =
      if child_trace_id do
        Map.put(tool_call, :child_trace_id, child_trace_id)
      else
        tool_call
      end

    # Add child_step if present (for TraceTree hierarchy)
    tool_call =
      if child_step do
        Map.put(tool_call, :child_step, child_step)
      else
        tool_call
      end

    eval_ctx2 = EvalContext.append_tool_call(eval_ctx, tool_call)

    if error do
      # Throw a special exception that carries the eval_ctx so tool_calls aren't lost
      raise PtcRunner.ToolExecutionError,
        message: error,
        eval_ctx: eval_ctx2,
        tool_name: tool_name
    else
      # Store in cache on success if cacheable (include child metadata for TraceTree)
      eval_ctx3 =
        if cacheable? do
          cached_entry = %{result: result, child_step: child_step, child_trace_id: child_trace_id}
          %{eval_ctx2 | tool_cache: Map.put(eval_ctx2.tool_cache, cache_key, cached_entry)}
        else
          eval_ctx2
        end

      # Metadata like child_trace_id is smuggled via TraceContext to avoid polluting
      # the Lisp value space with framework-internal wrappers.
      # This ensures tools always return data, not metadata, to the LLM.
      TraceContext.put_child_result(child_trace_id, child_step)
      {:ok, result, eval_ctx3}
    end
  end

  # Format ExecutionError into a human-readable error string preserving the data field
  defp format_execution_error(%ExecutionError{reason: :tool_error, message: name, data: data}) do
    "Tool '#{name}' failed: #{inspect(data)}"
  end

  defp format_execution_error(%ExecutionError{} = e), do: Exception.message(e)

  # Unwrap SubAgentTool results that contain child_trace_id and child_step metadata.
  # Returns {actual_result, child_trace_id, child_step} or {result, nil, nil} if not wrapped.
  defp unwrap_tool_result(%{__child_trace_id__: trace_id, __child_step__: step, value: value}) do
    {value, trace_id, step}
  end

  defp unwrap_tool_result(%{__child_trace_id__: trace_id, value: value}) do
    {value, trace_id, nil}
  end

  defp unwrap_tool_result(%{__child_step__: step, value: value}) do
    {value, nil, step}
  end

  defp unwrap_tool_result(result), do: {result, nil, nil}

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

  # Require a string or stringifiable scalar argument, raise on nil/collection
  defp require_string_arg!(value, _form, _arg_name) when is_binary(value), do: value

  defp require_string_arg!(value, form, arg_name)
       when is_integer(value) or is_float(value) or is_atom(value) do
    case value do
      nil ->
        raise ExecutionError,
          reason: :type_error,
          message: "(#{form}) #{arg_name} must be a string, got nil"

      v ->
        to_string(v)
    end
  end

  defp require_string_arg!(value, form, arg_name) do
    raise ExecutionError,
      reason: :type_error,
      message: "(#{form}) #{arg_name} must be a string, got #{inspect(value, limit: 3)}"
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
    case do_eval(e, eval_ctx) do
      {:ok, value, eval_ctx2} ->
        if Where.truthy?(value) do
          # Short-circuit: return truthy value
          {:ok, value, eval_ctx2}
        else
          # Continue evaluating, tracking this value as last evaluated
          do_eval_or_rest(rest, value, eval_ctx2)
        end

      {:error, {:unbound_var, name}} ->
        # Unbound memory variable treated as nil/falsy — try next clause.
        # This makes `(or my-memory-var default)` safe even on the first call.
        Logger.debug("[ptc-lisp] or: #{name} unbound, treating as nil")
        do_eval_or_rest(rest, nil, eval_ctx)

      {:error, _} = err ->
        err
    end
  end

  defp do_eval_or_rest([], last_value, %EvalContext{} = eval_ctx) do
    {:ok, last_value, eval_ctx}
  end

  defp do_eval_or_rest([e | rest], _last_value, %EvalContext{} = eval_ctx) do
    case do_eval(e, eval_ctx) do
      {:ok, value, eval_ctx2} ->
        if Where.truthy?(value) do
          # Short-circuit: return truthy value
          {:ok, value, eval_ctx2}
        else
          # Continue evaluating, tracking this value as last evaluated
          do_eval_or_rest(rest, value, eval_ctx2)
        end

      {:error, {:unbound_var, name}} ->
        # Same treatment as the first clause: unbound memory var = nil/falsy.
        Logger.debug("[ptc-lisp] or: #{name} unbound, treating as nil")
        do_eval_or_rest(rest, nil, eval_ctx)

      {:error, _} = err ->
        err
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
  # Uses Callable.call/2 to properly dispatch to builtin tuples
  defp build_juxt_fn(fns) do
    alias PtcRunner.Lisp.Runtime.Callable
    fn arg -> Enum.map(fns, &Callable.call(&1, [arg])) end
  end

  # ============================================================
  # Parallel execution helpers (shared by pmap and pcalls)
  # ============================================================

  # Unified helper to collect parallel results with child trace IDs and child steps
  # Works for both pmap and pcalls result formats
  defp collect_parallel_results(results, type) do
    collect_parallel_results(results, [], [], [], type)
  end

  defp collect_parallel_results([], acc, trace_ids, child_steps, _type) do
    {:ok, Enum.reverse(acc), Enum.reverse(trace_ids), Enum.reverse(child_steps)}
  end

  defp collect_parallel_results([{:ok, result} | rest], acc, trace_ids, child_steps, type) do
    case extract_parallel_result(result) do
      {:ok, val, trace_id, child_step} ->
        collect_parallel_results(
          rest,
          [val | acc],
          [trace_id | trace_ids],
          [child_step | child_steps],
          type
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_parallel_results([{:exit, reason} | _rest], _acc, _trace_ids, _child_steps, type) do
    error_type = if type == :pmap, do: :pmap_error, else: :pcalls_error
    {:error, {error_type, "parallel task failed: #{inspect(reason)}"}}
  end

  # Extract value, trace_id, and child_step from different result formats
  defp extract_parallel_result({:ok, val, trace_id, child_step})
       when is_map(child_step) or is_nil(child_step) do
    {:ok, val, trace_id, child_step}
  end

  defp extract_parallel_result({:ok, val, trace_id, _idx, child_step}),
    do: {:ok, val, trace_id, child_step}

  defp extract_parallel_result({:ok, val, trace_id}), do: {:ok, val, trace_id, nil}
  defp extract_parallel_result({:error, _reason} = error), do: error

  # ============================================================
  # Pcalls helpers
  # ============================================================

  # Convert a closure to a zero-arity Erlang function for use in pcalls
  defp pcalls_fn_to_erlang(
         {:closure, [], body, closure_env, turn_history, _metadata},
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

      ctx = %{
        ctx
        | loop_limit: eval_ctx.loop_limit,
          prints: eval_ctx.prints,
          max_print_length: eval_ctx.max_print_length,
          pmap_timeout: eval_ctx.pmap_timeout
      }

      case do_eval(body, ctx) do
        {:ok, result, _ctx2} -> result
        {:error, reason} -> raise "pcalls function failed: #{inspect(reason)}"
      end
    end
  end

  defp pcalls_fn_to_erlang(
         {:closure, params, _body, _closure_env, _turn_history, _metadata},
         %EvalContext{}
       ) do
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

  # ============================================================
  # Loop Execution
  # ============================================================

  defp execute_loop(body, %EvalContext{} = ctx, bindings) do
    do_eval(body, ctx)
  catch
    {:recur_signal, new_values, prints, tool_calls, tool_cache} ->
      patterns = Enum.map(bindings, fn {:binding, p, _} -> p end)

      if length(patterns) != length(new_values) do
        {:error, {:arity_mismatch, length(patterns), length(new_values)}}
      else
        case bind_recur_values(patterns, new_values) do
          {:ok, new_bindings} ->
            case EvalContext.increment_iteration(ctx) do
              {:ok, ctx2} ->
                # Preserve prints, tool_calls, and tool_cache across iterations
                ctx3 = %{ctx2 | prints: prints, tool_calls: tool_calls, tool_cache: tool_cache}
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
