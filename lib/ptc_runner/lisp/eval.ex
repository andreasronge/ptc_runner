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
  - `Eval.Apply` - Function application dispatch
  - `Eval.Helpers` - Type errors and utilities
  """

  require Logger

  alias PtcRunner.Lisp.ClosureCapture
  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.Discovery
  alias PtcRunner.Lisp.Env
  alias PtcRunner.Lisp.Eval.{Apply, ParallelRunner, Patterns}
  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.ExecutionError
  require PtcRunner.Lisp.ExecutionError
  alias PtcRunner.Lisp.Format.Var
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Callable
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Lisp.SourceAtoms
  alias PtcRunner.SubAgent.KeyNormalizer
  alias PtcRunner.SubAgent.UntrustedRenderer
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

  defp do_eval({:repl_discovery, operation, arg_asts}, %EvalContext{} = eval_ctx) do
    case eval_all(arg_asts, eval_ctx) do
      {:ok, args, eval_ctx2} ->
        invoke_discovery(eval_ctx2, operation, args)

      {:error, _} = err ->
        err
    end
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

  defp do_eval({:keyword, k}, %EvalContext{} = eval_ctx),
    do: {:ok, keyword_value(k), eval_ctx}

  defp do_eval({:symbol_ref, name}, %EvalContext{} = eval_ctx),
    do: {:ok, {:symbol_ref, name}, eval_ctx}

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
  # Resolution order: let bindings → user namespace (def bindings) → builtins
  # env contains both builtins and let bindings; locals tracks let-bound names.
  # user_ns (def) shadows builtins but not let bindings.
  defp do_eval({:var, name}, %EvalContext{user_ns: user_ns, env: env, locals: locals} = eval_ctx) do
    with :error <- resolve_local(name, locals, env, eval_ctx),
         :error <- resolve_user_ns(name, user_ns, eval_ctx),
         :error <- resolve_env(name, env, eval_ctx),
         :error <- resolve_builtin(name, eval_ctx),
         :error <- resolve_legacy_user_ns(name, user_ns, eval_ctx),
         :error <- resolve_legacy_env(name, env, eval_ctx) do
      unresolved_var(name)
    end
  end

  # Data access: data/input → ctx[:input]
  #
  # When `strict_data: true` (set by the MCP request handler per § 9.3),
  # accessing a key that was not supplied raises a runtime error naming
  # the binding. In permissive mode (the default for in-process callers)
  # the lookup returns `nil` for unknown keys.
  defp do_eval({:data, key}, %EvalContext{ctx: ctx, strict_data: true} = eval_ctx) do
    if data_key_present?(ctx, key) do
      {:ok, flex_get(ctx, key), eval_ctx}
    else
      raise PtcRunner.Lisp.ExecutionError,
        reason: :runtime_error,
        message: "data/#{key} is not bound: the `context` object did not provide a `#{key}` key"
    end
  end

  defp do_eval({:data, key}, %EvalContext{ctx: ctx} = eval_ctx) do
    {:ok, flex_get(ctx, key), eval_ctx}
  end

  defp do_eval({:runtime_callable, namespace, name}, %EvalContext{} = eval_ctx) do
    {:ok, RuntimeCallable.new(namespace, name), eval_ctx}
  end

  # Define binding in user namespace: (def name value opts)
  # Returns the var, not the value (Clojure semantics)
  # Opts may contain :docstring which is merged into closure metadata for functions
  defp do_eval({:def, name, value_ast, opts}, %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- do_eval(value_ast, eval_ctx) do
      # Merge docstring into closure metadata if value is a closure
      value = merge_docstring_into_closure(value, opts)

      new_user_ns =
        eval_ctx2.user_ns
        |> delete_legacy_user_ns_key(name)
        |> Map.put(name, value)

      {:ok, %Var{name: name}, EvalContext.update_user_ns(eval_ctx2, new_user_ns)}
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
    if Map.has_key?(user_ns, name) or (is_binary(name) and legacy_var_present?(user_ns, name)) do
      {:ok, %Var{name: name}, eval_ctx}
    else
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
    do_eval_and(exprs, true, eval_ctx)
  end

  # Short-circuit logic: or
  defp do_eval({:or, exprs}, %EvalContext{} = eval_ctx) do
    do_eval_or(exprs, eval_ctx)
  end

  # Conditional: if
  defp do_eval({:if, cond_ast, then_ast, else_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, cond_val, eval_ctx2} <- do_eval(cond_ast, eval_ctx) do
      if truthy?(cond_val) do
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
            # Restore the original environment and locals from before the let block
            {:ok, value, %{final_ctx | env: eval_ctx.env, locals: eval_ctx.locals}}

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
            # Restore the original environment AND locals from before the loop
            {:ok, value, %{final_ctx | env: eval_ctx.env, locals: eval_ctx.locals}}

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
        throw({:recur_signal, values, EvalContext.recur_effects(ctx)})

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Function definition: fn
  # ============================================================

  defp do_eval({:fn, params, body}, %EvalContext{} = eval_ctx) do
    # Capture only the *user-visible* slice of the env — let/fn-param locals
    # plus any caller-injected env entries (anything that isn't in the
    # canonical builtin set), further narrowed to names the body actually
    # references. Builtins are resolved at call time via the Env.builtin?
    # fallback in (:var ...), so carrying them in the closure would inflate
    # session memory by ~18 KB per closure.
    {captured_env, captured_locals} = capture_lexical_scope(eval_ctx, params, body)
    meta = locals_meta(captured_locals, %{})
    {:ok, {:closure, params, body, captured_env, [], meta}, eval_ctx}
  end

  # Named fn: (fn name [params] body) — name is bound inside body for self-recursion
  defp do_eval({:fn, name, params, body}, %EvalContext{} = eval_ctx) do
    {captured_env, captured_locals} = capture_lexical_scope(eval_ctx, params, body, [name])
    meta = locals_meta(captured_locals, %{fn_name: name})
    {:ok, {:closure, params, body, captured_env, [], meta}, eval_ctx}
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
      if keyword_runtime?(fn_val) and is_map(coll_val) and
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

        # Security H1: every pmap/pcalls worker — top-level and nested —
        # is spawned with a FIXED `max_heap_size` (`worker_max_heap`),
        # NOT divided by concurrency. A shared `ParallelBudget` semaphore
        # (`parallel_budget`) caps how many workers may be alive at once
        # across the whole run, so aggregate live parallel heap is
        # bounded by `max_parallel_workers * worker_max_heap` at any
        # nesting depth. The worker's `EvalContext` keeps the SAME
        # `worker_max_heap` and `parallel_budget`, so a nested
        # pmap/pcalls inherits both. `pmap_deadline` is inherited so all
        # nested calls share one deadline.
        worker_max_heap = eval_ctx2.worker_max_heap
        concurrency = bounded_concurrency(eval_ctx2.pmap_max_concurrency)
        deadline_mono = parallel_deadline(eval_ctx2)
        worker_eval_ctx = %{eval_ctx2 | pmap_deadline: deadline_mono}

        # Convert the function value to a callable (may be a tuple for builtins)
        # The closure captures a read-only snapshot of the environment at creation time
        callable_fn = value_to_erlang_fn(fn_val, worker_eval_ctx)

        # Capture trace context for propagation into worker processes
        trace_ctx = TraceContext.capture()

        worker_fun = fn elem ->
          try do
            TraceContext.take_child_result()

            value =
              RuntimeCallable.with_context(worker_eval_ctx, &do_eval/2, fn ->
                Callable.call(callable_fn, [elem])
              end)

            case TraceContext.take_child_result() do
              {trace_id, child_step} -> {:ok, {:ok, value, trace_id, child_step}}
              nil -> {:ok, {:ok, value, nil, nil}}
            end
          rescue
            e in PtcRunner.ToolExecutionError ->
              {:error, {:pmap_error, "tool '#{e.tool_name}' failed: #{e.message}"}}

            e in ExecutionError ->
              # Re-surface stable error atoms from a nested pmap/pcalls
              # (heap kill / shared-deadline timeout) instead of
              # flattening them into a generic :pmap_error string.
              {:error, nested_parallel_error(e)}

            e ->
              {:error, {:pmap_error, Exception.message(e)}}
          catch
            {:return_signal, _, _} ->
              {:error, {:pmap_error, "return called inside pmap"}}

            {:fail_signal, _, _} ->
              {:error, {:pmap_error, "fail called inside pmap"}}
          end
        end

        runner_result =
          ParallelRunner.run(coll_list, worker_fun,
            worker_max_heap: worker_max_heap,
            max_concurrency: concurrency,
            budget: eval_ctx2.parallel_budget,
            deadline_mono: deadline_mono,
            trace_ctx: trace_ctx
          )

        # Collect results and child trace IDs
        duration_ms = System.monotonic_time(:millisecond) - start_time

        case collect_runner_results(runner_result, :pmap) do
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

        # Security H1: fixed per-worker heap cap + shared slot budget —
        # see the pmap clause above for the full rationale.
        worker_max_heap = eval_ctx2.worker_max_heap
        concurrency = bounded_concurrency(eval_ctx2.pmap_max_concurrency)
        deadline_mono = parallel_deadline(eval_ctx2)
        worker_eval_ctx = %{eval_ctx2 | pmap_deadline: deadline_mono}

        # Convert each function value to an Erlang function (zero-arity thunk)
        # Use a try/rescue to catch validation errors (wrong arity, non-callable)
        try do
          erlang_fns =
            fn_vals
            |> Enum.with_index()
            |> Enum.map(fn {fn_val, idx} ->
              {pcalls_fn_to_erlang(fn_val, worker_eval_ctx), idx}
            end)

          # Capture trace context for propagation into worker processes
          trace_ctx = TraceContext.capture()

          worker_fun = fn {erlang_fn, idx} ->
            try do
              TraceContext.take_child_result()
              value = erlang_fn.()

              case TraceContext.take_child_result() do
                {trace_id, child_step} -> {:ok, {:ok, value, trace_id, idx, child_step}}
                nil -> {:ok, {:ok, value, nil, idx, nil}}
              end
            rescue
              e in ExecutionError ->
                # Re-surface stable error atoms from a nested
                # pmap/pcalls (heap kill / shared-deadline timeout).
                {:error, nested_parallel_error(e, idx)}

              e ->
                {:error, {:pcalls_error, idx, Exception.message(e)}}
            catch
              {:return_signal, _, _} ->
                {:error, {:pcalls_error, idx, "return called inside pcalls"}}

              {:fail_signal, _, _} ->
                {:error, {:pcalls_error, idx, "fail called inside pcalls"}}
            end
          end

          runner_result =
            ParallelRunner.run(erlang_fns, worker_fun,
              worker_max_heap: worker_max_heap,
              max_concurrency: concurrency,
              budget: eval_ctx2.parallel_budget,
              deadline_mono: deadline_mono,
              trace_ctx: trace_ctx
            )

          # Collect results and child trace IDs
          duration_ms = System.monotonic_time(:millisecond) - start_time

          case collect_runner_results(runner_result, :pcalls) do
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
            # Convert to string for backward compatibility with tool_exec
            tool_name_str = to_string(tool_name)
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

  defp resolve_local(name, locals, env, eval_ctx) do
    if MapSet.member?(locals, name), do: {:ok, Map.get(env, name), eval_ctx}, else: :error
  end

  defp resolve_user_ns(name, user_ns, eval_ctx) do
    if Map.has_key?(user_ns, name), do: {:ok, Map.get(user_ns, name), eval_ctx}, else: :error
  end

  defp resolve_env(name, env, eval_ctx) do
    case Map.fetch(env, name) do
      {:ok, value} -> {:ok, unwrap_constant(value), eval_ctx}
      :error -> :error
    end
  end

  defp resolve_builtin(name, eval_ctx) do
    if Env.builtin?(name) do
      {:ok, unwrap_constant(Map.get(Env.initial(), name)), eval_ctx}
    else
      :error
    end
  end

  defp resolve_legacy_user_ns(name, user_ns, eval_ctx) do
    with true <- is_binary(name),
         {:ok, atom} <- safe_to_existing_atom(name),
         {:ok, value} <- Map.fetch(user_ns, atom) do
      {:ok, value, eval_ctx}
    else
      _ -> :error
    end
  end

  defp resolve_legacy_env(name, env, eval_ctx) do
    with true <- is_binary(name),
         {:ok, atom} <- safe_to_existing_atom(name),
         {:ok, value} <- Map.fetch(env, atom) do
      {:ok, unwrap_constant(value), eval_ctx}
    else
      _ -> :error
    end
  end

  defp unwrap_constant({:constant, value}), do: value
  defp unwrap_constant(other), do: other

  defp unresolved_var(name) do
    name_str = to_string(name)

    if String.starts_with?(name_str, ".") do
      available =
        Env.builtins_by_category(:interop)
        |> Enum.map_join(", ", &to_string/1)

      {:error, {:unsupported_method, name_str, available}}
    else
      {:error, {:unbound_var, name}}
    end
  end

  # Truthiness check for conditional / short-circuit forms.
  # Only `nil` and `false` are falsy; every other value is truthy.
  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

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

  defp build_args_map([arg], _tool_name) when is_map(arg) and not is_struct(arg),
    do: {:ok, stringify_keys(arg)}

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
  # Must have even length and odd positions (0, 2, 4...) must be keywords
  defp keyword_style_args?(args) when rem(length(args), 2) == 0 do
    args
    |> Enum.chunk_every(2)
    |> Enum.all?(fn [k, _v] -> keyword_runtime?(k) end)
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
  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {stringify_key(k), stringify_value(v)} end)
  end

  # Recursively stringify values (for nested maps/lists in tool args).
  # A keyword value becomes its plain name string — deterministic and
  # JSON-friendly, matching how `stringify_key/1` handles keyword keys (#964).
  defp stringify_value(%LispKeyword{name: name}), do: name

  defp stringify_value(map) when is_map(map) and not is_struct(map), do: stringify_keys(map)

  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(other), do: other

  defp stringify_key(k) when is_atom(k), do: KeyNormalizer.normalize_key(k)
  defp stringify_key(%LispKeyword{name: name}), do: KeyNormalizer.normalize_key(name)
  defp stringify_key(k) when is_binary(k), do: KeyNormalizer.normalize_key(k)
  defp stringify_key(k), do: inspect(k)

  # Record a tool call with timing, execution, error capture, and evaluation context update.
  # Captures the error field if the tool raises an exception, records it, and throws a special
  # exception that includes the updated eval_ctx so the error can be properly reported.
  #
  # When `cacheable?` is true, results are cached by the canonical cache key
  # produced by `KeyNormalizer.canonical_cache_key/2` so native app-tool
  # calls and PTC-Lisp `(tool/...)` calls share the same cache entry whenever
  # the call is semantically identical (atom/string keys, map ordering, and
  # integer-equal floats all collapse to one canonical form).
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
    # Tier 3.5 Fix 3d: only compute the canonical cache key when the call
    # is actually cacheable. Avoids the cost of canonicalization for
    # every non-cacheable tool call.
    cache_key = if cacheable?, do: KeyNormalizer.canonical_cache_key(tool_name, args_map)

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
    wrapped_data = UntrustedRenderer.wrap(inspect(data), "tool_error")
    "Tool '#{name}' failed:\n#{wrapped_data}"
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
  # Strict-data lookup helpers (used by `do_eval({:data, key}, ...)`)
  # ============================================================

  # `data/<key>` is bound when either the binary or atom form of the
  # key is present in `ctx`. Mirrors `flex_get`'s atom/binary-tolerant
  # access so strict mode does not reject keys that flex_get would
  # successfully resolve.
  defp data_key_present?(ctx, key) when is_map(ctx) and is_atom(key) do
    Map.has_key?(ctx, key) or Map.has_key?(ctx, Atom.to_string(key))
  end

  defp data_key_present?(ctx, key) when is_map(ctx) and is_binary(key) do
    Map.has_key?(ctx, key) or
      case key_to_existing_atom(key) do
        {:ok, atom} -> Map.has_key?(ctx, atom)
        :error -> false
      end
  end

  defp data_key_present?(_ctx, _key), do: false

  defp key_to_existing_atom(bin) do
    {:ok, String.to_existing_atom(bin)}
  rescue
    ArgumentError -> :error
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

  defp do_eval_and([], last_value, %EvalContext{} = eval_ctx),
    do: {:ok, last_value, eval_ctx}

  defp do_eval_and([e | rest], _last_value, %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- do_eval(e, eval_ctx) do
      if truthy?(value) do
        do_eval_and(rest, value, eval_ctx2)
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
        if truthy?(value) do
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
        if truthy?(value) do
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

  defp value_to_erlang_fn(%LispKeyword{} = k, %EvalContext{}) do
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

  # Defensive bound on the local pmap/pcalls scheduling window. The HARD
  # aggregate cap is the global `ParallelBudget` semaphore;
  # `pmap_max_concurrency` is only a per-call window size. Clamp to a
  # positive integer.
  defp bounded_concurrency(conc) when is_integer(conc) and conc > 0, do: conc
  defp bounded_concurrency(_), do: 1

  # Resolve the shared absolute deadline for a parallel operation. The
  # OUTERMOST pmap/pcalls computes `now + pmap_timeout`; a nested call
  # inherits the parent's `pmap_deadline` unchanged so N branches cannot
  # multiply total wall time.
  defp parallel_deadline(%EvalContext{pmap_deadline: deadline}) when is_integer(deadline),
    do: deadline

  defp parallel_deadline(%EvalContext{pmap_timeout: timeout}),
    do: System.monotonic_time(:millisecond) + timeout

  # Adapt a `ParallelRunner.run/3` result to the
  # `{:ok, values, trace_ids, child_steps}` / `{:error, reason}` shape
  # the pmap/pcalls clauses expect.
  defp collect_runner_results({:ok, internal_results}, _type) do
    {values, trace_ids, child_steps} =
      Enum.reduce(internal_results, {[], [], []}, fn result, {vals, tids, steps} ->
        {:ok, val, trace_id, child_step} = extract_parallel_result(result)
        {[val | vals], [trace_id | tids], [child_step | steps]}
      end)

    {:ok, Enum.reverse(values), Enum.reverse(trace_ids), Enum.reverse(child_steps)}
  end

  defp collect_runner_results({:error, reason}, type) do
    {:error, classify_runner_error(reason, type)}
  end

  # Map `ParallelRunner`'s stable error reasons onto the pmap/pcalls
  # error shape.
  #
  # P3 fix: heap/timeout/capacity failures are surfaced as the 3-tuple
  # `{reason_atom, message, nil}`. `Lisp.execute_program/2` routes
  # 3-tuples through `format_error/1` (which renders `"reason: msg"`)
  # and tags the step with `reason_atom` directly — so `step.fail.reason`
  # stays `:memory_exceeded` / `:timeout` / `:parallel_capacity_exceeded`
  # AND the message reads cleanly. The 2-tuple `{:memory_exceeded, bytes}`
  # shape is reserved for the sandbox-process heap kill, where element 2
  # really is a numeric byte limit.
  defp classify_runner_error({:memory_exceeded, _index}, _type),
    do: {:memory_exceeded, "a parallel worker exceeded its per-worker heap cap", nil}

  defp classify_runner_error({:timeout, _index}, _type),
    do: {:timeout, "the parallel operation exceeded its deadline", nil}

  defp classify_runner_error(:parallel_capacity_exceeded, _type),
    do:
      {:parallel_capacity_exceeded,
       "the parallel worker budget is exhausted; reduce nesting or collection size", nil}

  # A nested capacity/heap/timeout failure re-surfaced by
  # `nested_parallel_error/1,2` arrives as a `{reason, message}` tuple —
  # normalise it through the same clauses above.
  defp classify_runner_error({:parallel_capacity_exceeded, _msg}, type),
    do: classify_runner_error(:parallel_capacity_exceeded, type)

  defp classify_runner_error({:runtime_error, index, detail}, type),
    do: {parallel_error_type(type), "parallel worker #{index} crashed: #{inspect(detail)}"}

  defp classify_runner_error({:pmap_error, _} = err, _type), do: err
  defp classify_runner_error({:pcalls_error, _, _} = err, _type), do: err
  defp classify_runner_error(other, type), do: {parallel_error_type(type), inspect(other)}

  defp parallel_error_type(:pmap), do: :pmap_error
  defp parallel_error_type(:pcalls), do: :pcalls_error

  # Re-surface a nested pmap/pcalls failure caught as an ExecutionError
  # inside a pmap worker. A stable reason keeps its atom; anything else
  # stays a generic :pmap_error.
  defp nested_parallel_error(%ExecutionError{reason: reason, message: msg})
       when reason in ExecutionError.stable_parallel_reasons() do
    {reason, msg}
  end

  defp nested_parallel_error(%ExecutionError{message: msg}), do: {:pmap_error, msg}

  # pcalls variant — same, but produces the 3-tuple pcalls error shape.
  defp nested_parallel_error(%ExecutionError{reason: reason, message: msg}, _idx)
       when reason in ExecutionError.stable_parallel_reasons() do
    {reason, msg}
  end

  defp nested_parallel_error(%ExecutionError{message: msg}, idx),
    do: {:pcalls_error, idx, msg}

  # Extract value, trace_id, and child_step from different result formats
  defp extract_parallel_result({:ok, val, trace_id, child_step})
       when is_map(child_step) or is_nil(child_step) do
    {:ok, val, trace_id, child_step}
  end

  defp extract_parallel_result({:ok, val, trace_id, _idx, child_step}),
    do: {:ok, val, trace_id, child_step}

  defp extract_parallel_result({:ok, val, trace_id}), do: {:ok, val, trace_id, nil}

  # ============================================================
  # Pcalls helpers
  # ============================================================

  # Convert a closure to a zero-arity Erlang function for use in pcalls
  defp pcalls_fn_to_erlang(
         {:closure, [], body, closure_env, _turn_history, metadata} = closure,
         %EvalContext{} = eval_ctx
       ) do
    closure_env = Apply.bind_self_recursion(closure_env, metadata, closure)

    fn ->
      ctx =
        EvalContext.new(
          eval_ctx.ctx,
          eval_ctx.user_ns,
          closure_env,
          eval_ctx.tool_exec,
          eval_ctx.turn_history
        )

      ctx = %{
        ctx
        | locals: Apply.closure_locals(metadata, %{}),
          loop_limit: eval_ctx.loop_limit,
          prints: eval_ctx.prints,
          max_print_length: eval_ctx.max_print_length,
          pmap_timeout: eval_ctx.pmap_timeout,
          pmap_max_concurrency: eval_ctx.pmap_max_concurrency,
          # Security H1: propagate the heap caps + shared worker-slot
          # budget so a nested pmap/pcalls inside this thunk caps and
          # counts its workers, and the shared deadline so nested calls
          # don't multiply total wall time.
          max_heap: eval_ctx.max_heap,
          worker_max_heap: eval_ctx.worker_max_heap,
          parallel_budget: eval_ctx.parallel_budget,
          pmap_deadline: eval_ctx.pmap_deadline,
          discovery_exec: eval_ctx.discovery_exec
      }

      case do_eval(body, ctx) do
        {:ok, result, _ctx2} ->
          result

        {:error, reason} ->
          raise_pcalls_body_error(reason)
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

  # A nested pmap/pcalls failure (heap kill, deadline, exhausted worker
  # budget) raises structured so a surrounding worker re-surfaces the
  # stable atom; every other body error keeps the legacy RuntimeError
  # shape. Parallel errors arrive as 2- or 3-tuples.
  @spec raise_pcalls_body_error(term()) :: no_return()
  defp raise_pcalls_body_error({atom, _} = reason)
       when atom in ExecutionError.stable_parallel_reasons() do
    raise_pcalls_parallel_error(atom, reason)
  end

  defp raise_pcalls_body_error({atom, _, _} = reason)
       when atom in ExecutionError.stable_parallel_reasons() do
    raise_pcalls_parallel_error(atom, reason)
  end

  defp raise_pcalls_body_error(reason) do
    raise "pcalls function failed: #{inspect(reason)}"
  end

  @spec raise_pcalls_parallel_error(atom(), term()) :: no_return()
  defp raise_pcalls_parallel_error(atom, reason) do
    raise ExecutionError, reason: atom, message: "pcalls function failed: #{inspect(reason)}"
  end

  # ============================================================
  # Loop Execution
  # ============================================================

  defp execute_loop(body, %EvalContext{} = ctx, bindings) do
    do_eval(body, ctx)
  catch
    {:recur_signal, new_values, effects} ->
      patterns = Enum.map(bindings, fn {:binding, p, _} -> p end)

      if length(patterns) != length(new_values) do
        {:error, {:arity_mismatch, length(patterns), length(new_values)}}
      else
        case bind_recur_values(patterns, new_values) do
          {:ok, new_bindings} ->
            case EvalContext.increment_iteration(ctx) do
              {:ok, ctx2} ->
                ctx3 = EvalContext.restore_recur_effects(ctx2, effects)
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

  # ============================================================
  # REPL discovery dispatch
  # ============================================================

  defp invoke_discovery(%EvalContext{} = eval_ctx, operation, args) do
    args = normalize_catalog_args(operation, args)

    case operation do
      :servers -> invoke_mcp_only_discovery(eval_ctx, operation, args)
      :apropos -> invoke_apropos_discovery(eval_ctx, args)
      :dir -> invoke_ref_discovery(eval_ctx, operation, args, &Discovery.dir/2)
      :doc -> invoke_ref_discovery(eval_ctx, operation, args, &local_doc/2)
      :meta -> invoke_ref_discovery(eval_ctx, operation, args, &local_meta/2)
      :ns_publics -> invoke_local_only_discovery(eval_ctx, operation, args, &local_ns_publics/2)
      _ -> invoke_mcp_only_discovery(eval_ctx, operation, args)
    end
  end

  defp invoke_mcp_only_discovery(%EvalContext{discovery_exec: nil}, _operation, _args) do
    raise ExecutionError,
      reason: :runtime_error,
      message: "REPL discovery forms are only available when a discovery backend is configured"
  end

  defp invoke_mcp_only_discovery(
         %EvalContext{discovery_exec: discovery_exec} = eval_ctx,
         operation,
         args
       ) do
    invoke_discovery_exec(eval_ctx, discovery_exec, operation, args)
  end

  defp invoke_apropos_discovery(%EvalContext{} = eval_ctx, [query | rest]) do
    opts = List.first(rest, %{})

    with :ok <- validate_apropos_query(query),
         {:ok, opts} <- Discovery.parse_apropos_opts(opts) do
      local_matches = Discovery.apropos_matches(query, opts)

      case eval_ctx.discovery_exec do
        nil ->
          render_unified_apropos(eval_ctx, local_matches, opts)

        discovery_exec ->
          invoke_mcp_apropos_discovery(eval_ctx, discovery_exec, query, opts, local_matches)
      end
    else
      {:programmer_fault, message} ->
        raise ExecutionError, reason: :runtime_error, message: message
    end
  end

  defp invoke_apropos_discovery(_eval_ctx, args) do
    raise ExecutionError,
      reason: :runtime_error,
      message: "apropos requires query and optional opts, got #{inspect(args)}"
  end

  defp invoke_mcp_apropos_discovery(eval_ctx, discovery_exec, query, opts, local_matches) do
    result =
      invoke_discovery_exec(eval_ctx, discovery_exec, :apropos_matches, [query, opts], :apropos)

    handle_mcp_apropos_matches(result, discovery_exec, query, opts, local_matches)
  end

  defp handle_mcp_apropos_matches(
         {:ok, mcp_matches, eval_ctx},
         _exec,
         _query,
         opts,
         local_matches
       )
       when is_list(mcp_matches) do
    render_unified_apropos(eval_ctx, normalize_mcp_matches(mcp_matches), opts, local_matches)
  end

  defp handle_mcp_apropos_matches({:ok, nil, eval_ctx}, _exec, _query, opts, local_matches) do
    render_unified_apropos(eval_ctx, local_matches, opts)
  end

  defp handle_mcp_apropos_matches(
         {:fallback, eval_ctx},
         discovery_exec,
         query,
         opts,
         local_matches
       ) do
    eval_ctx
    |> invoke_discovery_exec(discovery_exec, :apropos, [query, opts])
    |> handle_legacy_mcp_apropos(opts, local_matches)
  end

  defp handle_legacy_mcp_apropos({:ok, mcp_lines, eval_ctx}, opts, local_matches)
       when is_list(mcp_lines) do
    render_unified_apropos(eval_ctx, fallback_mcp_line_matches(mcp_lines), opts, local_matches)
  end

  defp handle_legacy_mcp_apropos({:ok, nil, eval_ctx}, opts, local_matches) do
    render_unified_apropos(eval_ctx, local_matches, opts)
  end

  defp validate_apropos_query(query) do
    if is_binary(query) and String.trim(query) != "" do
      :ok
    else
      {:programmer_fault, "apropos requires query (non-empty string), got #{inspect(query)}"}
    end
  end

  defp invoke_ref_discovery(%EvalContext{} = eval_ctx, operation, [ref | rest] = args, local_fun) do
    opts = List.first(rest, %{})

    case local_fun.(ref, opts) do
      {:ok, result} ->
        {:ok, result, eval_ctx}

      :unknown ->
        invoke_mcp_only_discovery(eval_ctx, operation, args)

      {:programmer_fault, message} ->
        raise ExecutionError, reason: :runtime_error, message: message
    end
  end

  defp invoke_ref_discovery(_eval_ctx, operation, args, _local_fun) do
    raise ExecutionError,
      reason: :runtime_error,
      message: "#{operation} requires a ref, got #{inspect(args)}"
  end

  defp invoke_local_only_discovery(%EvalContext{} = eval_ctx, operation, [ref], local_fun) do
    case local_fun.(ref, %{}) do
      {:ok, result} ->
        {:ok, result, eval_ctx}

      :unknown ->
        raise ExecutionError,
          reason: :runtime_error,
          message: "no local discovery ref #{inspect(ref)} for #{operation}"

      {:programmer_fault, message} ->
        raise ExecutionError, reason: :runtime_error, message: message
    end
  end

  defp invoke_discovery_exec(%EvalContext{} = eval_ctx, discovery_exec, operation, args) do
    invoke_discovery_exec(eval_ctx, discovery_exec, operation, args, operation)
  end

  defp invoke_discovery_exec(
         %EvalContext{} = eval_ctx,
         discovery_exec,
         operation,
         args,
         record_op
       ) do
    start_time = System.monotonic_time(:millisecond)

    case discovery_exec.(operation, args) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        op_record = %{
          operation: record_op,
          args: catalog_op_args(record_op, args),
          outcome: :ok,
          reason: nil,
          duration_ms: duration_ms
        }

        {:ok, result, EvalContext.append_catalog_op(eval_ctx, op_record)}

      {:world_fault, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        op_record = %{
          operation: record_op,
          args: catalog_op_args(record_op, args),
          outcome: :nil_world_fault,
          reason: reason,
          duration_ms: duration_ms
        }

        {:ok, nil, EvalContext.append_catalog_op(eval_ctx, op_record)}

      {:programmer_fault, message} ->
        if operation == :apropos_matches do
          {:fallback, eval_ctx}
        else
          raise ExecutionError, reason: :runtime_error, message: message
        end
    end
  end

  defp render_unified_apropos(eval_ctx, matches, opts, extra_matches \\ []) do
    limit = Map.get(opts, :limit, 8)

    lines =
      (matches ++ extra_matches)
      |> Discovery.sort_matches()
      |> Enum.take(limit)
      |> Discovery.render_matches()

    {:ok, lines, eval_ctx}
  end

  defp normalize_mcp_matches(matches) do
    Enum.map(matches, fn
      %{} = match ->
        %{
          source_rank: Map.get(match, :source_rank, Map.get(match, "source_rank", 0)),
          score: Map.get(match, :score, Map.get(match, "score", 0)),
          source_kind: Map.get(match, :source_kind, Map.get(match, "source_kind", "mcp")),
          server: Map.get(match, :server, Map.get(match, "server", "")),
          name: Map.get(match, :name, Map.get(match, "name", Map.get(match, "tool", ""))),
          ref: Map.get(match, :ref, Map.get(match, "ref", "")),
          line: Map.get(match, :line, Map.get(match, "line", ""))
        }

      line when is_binary(line) ->
        fallback_mcp_line_match(line)
    end)
  end

  defp fallback_mcp_line_matches(lines), do: Enum.map(lines, &fallback_mcp_line_match/1)

  defp fallback_mcp_line_match(line) do
    %{source_rank: 0, score: 0, source_kind: "mcp", server: "", name: line, ref: line, line: line}
  end

  defp local_doc(ref, _opts), do: Discovery.doc(ref)
  defp local_meta(ref, _opts), do: Discovery.meta(ref)
  defp local_ns_publics(ref, _opts), do: Discovery.ns_publics(ref)

  defp catalog_op_args(:servers, []), do: %{}
  defp catalog_op_args(:dir, [server]), do: %{server: server}
  defp catalog_op_args(:dir, [server, opts]), do: %{server: server, opts: opts}
  defp catalog_op_args(:doc, [ref]), do: %{ref: ref}
  defp catalog_op_args(:meta, [ref]), do: %{ref: ref}
  defp catalog_op_args(:ns_publics, [ref]), do: %{ref: ref}
  defp catalog_op_args(:apropos, [query]), do: %{query: query}
  defp catalog_op_args(:apropos, [query, opts]), do: %{query: query, opts: opts}
  defp catalog_op_args(_, args), do: %{args: args}

  defp normalize_catalog_args(:dir, [server]), do: [server_ref_name(server)]

  defp normalize_catalog_args(:dir, [server, opts]),
    do: [server_ref_name(server), normalize_catalog_value(opts)]

  defp normalize_catalog_args(_operation, args), do: Enum.map(args, &normalize_catalog_value/1)

  defp server_ref_name({:symbol_ref, name}) when is_binary(name), do: name
  defp server_ref_name(name), do: name

  defp normalize_catalog_value(%LispKeyword{name: name}), do: safe_keyword_name(name)
  defp normalize_catalog_value({:symbol_ref, name}) when is_binary(name), do: name

  defp normalize_catalog_value(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {key, value} ->
      {normalize_catalog_value(key), normalize_catalog_value(value)}
    end)
  end

  defp normalize_catalog_value(list) when is_list(list),
    do: Enum.map(list, &normalize_catalog_value/1)

  defp normalize_catalog_value(other), do: other

  defp safe_keyword_name(name) when is_atom(name), do: name
  defp safe_keyword_name("limit"), do: :limit
  defp safe_keyword_name("offset"), do: :offset
  defp safe_keyword_name("load"), do: :load

  defp safe_keyword_name(name) when is_binary(name) do
    case Map.get(SourceAtoms.table(), name) do
      atom when is_atom(atom) -> atom
      nil -> name
      other -> other
    end
  end

  # ============================================================
  # Closure capture helpers
  # ============================================================

  defp capture_lexical_scope(
         %EvalContext{env: env, locals: locals},
         params,
         body,
         extra_bound_names \\ []
       ) do
    initial = Env.initial()

    # Names the closure body can actually reference (issue #961). A closure
    # captures its whole enclosing lexical scope, so a `(fn [] 42)` defined
    # next to a large `let` binding would otherwise pin that binding for the
    # closure's entire lifetime — and in a long-lived session, for the
    # session's TTL. The collector is scope-aware so params, named-fn self
    # bindings, and inner let/fn/loop bindings don't cause an unrelated outer
    # value with the same name to be captured.
    referenced = ClosureCapture.referenced_vars(body, params, extra_bound_names)

    # Keep an entry only if the body references it AND it is EITHER:
    #   * a key in `locals` (let/fn-param, possibly shadowing a builtin like
    #     `count` — must preserve so the shadow survives in the closure)
    #   * not a builtin at all (caller-injected env entries, e.g. a test
    #     harness pre-populating env)
    # Builtins that the user didn't shadow are stripped; they resolve at
    # call time via the Env.builtin? fallback in (:var ...). This is the
    # whole point of the optimization — each closure would otherwise drag
    # the full ~18 KB builtin map (and every unused sibling binding) around.
    captured_env =
      referenced
      |> Enum.reduce(%{}, fn name, acc ->
        capture_referenced_binding(name, env, locals, initial, acc)
      end)

    # Narrow `locals` (stored in meta as `:captured_locals`) to the same
    # referenced set so it stays consistent with `captured_env` — every
    # captured local still has an env entry. `locals` is NOT widened to
    # include caller-injected env keys: promoting them would invert the
    # documented precedence (locals > user_ns > env).
    captured_locals =
      captured_env
      |> Map.keys()
      |> Enum.filter(&MapSet.member?(locals, &1))
      |> MapSet.new()

    {captured_env, captured_locals}
  end

  defp capture_referenced_binding(name, env, locals, initial, acc) do
    name
    |> referenced_env_keys()
    |> Enum.reduce(acc, fn key, inner_acc ->
      with {:ok, value} <- Map.fetch(env, key),
           true <- MapSet.member?(locals, key) or not Map.has_key?(initial, key) do
        Map.put(inner_acc, key, value)
      else
        _ -> inner_acc
      end
    end)
  end

  defp referenced_env_keys(name) when is_binary(name) do
    case safe_to_existing_atom(name) do
      {:ok, atom} -> [name, atom]
      :error -> [name]
    end
  end

  # Only embed captured_locals in meta when non-empty — keeps closure size
  # tiny for top-level (defn ...) without enclosing scope.
  defp locals_meta(%MapSet{} = locals, base) do
    case MapSet.size(locals) do
      0 -> base
      _ -> Map.put(base, :captured_locals, locals)
    end
  end

  defp keyword_value(name) when is_atom(name), do: name
  defp keyword_value(name) when is_binary(name), do: LispKeyword.new(name)

  defp keyword_runtime?(%LispKeyword{}), do: true
  defp keyword_runtime?(atom) when is_atom(atom), do: not is_nil(atom) and not is_boolean(atom)
  defp keyword_runtime?(_), do: false

  defp legacy_var_present?(map, name) when is_map(map) and is_binary(name) do
    case safe_to_existing_atom(name) do
      {:ok, atom} -> Map.has_key?(map, atom)
      :error -> false
    end
  end

  defp delete_legacy_user_ns_key(map, name) when is_map(map) and is_binary(name) do
    case safe_to_existing_atom(name) do
      {:ok, atom} -> Map.delete(map, atom)
      :error -> map
    end
  end

  defp delete_legacy_user_ns_key(map, _name), do: map

  defp safe_to_existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end
