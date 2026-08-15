defmodule PtcRunner.Lisp.Eval do
  @moduledoc """
  Evaluates CoreAST into values.

  The eval layer recursively interprets CoreAST nodes, resolving variables
  from lexical environments, applying builtins and user functions, and
  handling control flow.

  Expected evaluation exits use one context-bearing protocol owned by
  `Eval.Outcome`: success, recoverable error, or `return`/`fail`/`recur`
  control. Host callbacks that cannot return an outcome use the private
  `Eval.Abort` carrier. `Eval.HostContext` installs the active evaluator
  context around those callbacks so validation and runtime helpers can abort
  without introducing parallel exception transports.

  `Eval.Context` owns the normalized cumulative `Eval.Effects`. `Eval.Capture`
  is the single callback capture stack; it records the authoritative effect
  delta and replaces only an outcome context's effects during normalization.
  `Eval.HostContext` is the one adapter for plain host callbacks. Callable
  dispatch remains responsible for restoring lexical, namespace, and
  prelude-authority state before an outcome crosses a boundary.

  ## Module Structure

  This module delegates to specialized submodules:
  - `Eval.Context` - Evaluation context struct
  - `Eval.Patterns` - Pattern matching for let bindings
  - `Eval.Apply` - Function application dispatch
  - `Eval.Outcome` / `Eval.Abort` - Expected outcomes and the private callback carrier
  - `Eval.HostContext` - Active evaluator context for host callbacks
  - `Eval.Effects` / `Eval.Capture` - Effect algebra and callback capture
  - `Eval.Parallel` - pmap/pcalls evaluation and worker-result semantics
  - `Eval.ParallelRunner` - Parallel scheduling and process lifecycle
  - `Eval.Helpers` - Type errors and utilities
  """

  require Logger

  alias PtcRunner.Lisp.AmbiguousArguments
  alias PtcRunner.Lisp.ChildResult
  alias PtcRunner.Lisp.ClosureCapture
  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.Env
  alias PtcRunner.Lisp.Env.Builtin

  alias PtcRunner.Lisp.Eval.{
    Abort,
    Apply,
    CapabilityResult,
    Capture,
    Helpers,
    HostContext,
    Outcome,
    Parallel,
    Patterns
  }

  alias PtcRunner.Lisp.Eval.Context, as: EvalContext
  alias PtcRunner.Lisp.Format
  alias PtcRunner.Lisp.Format.Var
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Condition, as: JavaCondition
  alias PtcRunner.Lisp.Java.Dispatch, as: JavaDispatch
  alias PtcRunner.Lisp.Java.Primitive, as: JavaPrimitive
  alias PtcRunner.Lisp.Java.Project, as: JavaProject
  alias PtcRunner.Lisp.Java.Surface, as: JavaSurface
  alias PtcRunner.Lisp.Java.Time.Duration, as: JavaDuration
  alias PtcRunner.Lisp.Java.Time.Instant, as: JavaInstant
  alias PtcRunner.Lisp.Java.Time.LocalDate, as: JavaLocalDate
  alias PtcRunner.Lisp.Java.Util.Date, as: JavaDate
  alias PtcRunner.Lisp.KeyNormalizer
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Metadata
  alias PtcRunner.Lisp.PreludeClosure
  alias PtcRunner.Lisp.RuntimeCallable
  alias PtcRunner.Lisp.UntrustedRenderer

  import PtcRunner.Lisp.Runtime, only: [flex_fetch: 2]

  @max_trace_id_bytes 256

  @type env :: %{atom() => term()}
  @type tool_executor ::
          (String.t(), map() -> term()) | (String.t(), map(), map() | nil -> term())

  @type outcome ::
          {:ok, term(), EvalContext.t()}
          | {:error, term(), EvalContext.t()}
          | {:control, :return | :fail | :recur, term(), EvalContext.t()}

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
          | {:transitive_call_unauthorized, String.t(), String.t(), [String.t()]}

  @spec eval(CoreAST.t(), map(), map(), env(), tool_executor(), list(), keyword()) ::
          {:ok, value(), map()} | {:error, runtime_error()}
  def eval(ast, ctx, memory, env, tool_executor, turn_history \\ [], opts \\ []) do
    case eval_with_context(ast, ctx, memory, env, tool_executor, turn_history, opts) do
      {:ok, result, %EvalContext{user_ns: user_ns}} ->
        {:ok, result, user_ns}

      {:error, reason, %EvalContext{}} ->
        {:error, reason}

      {:control, :return, value, %EvalContext{user_ns: user_ns}} ->
        {:ok, {:return_signal, value}, user_ns}

      {:control, :fail, value, %EvalContext{user_ns: user_ns}} ->
        {:ok, {:fail_signal, value}, user_ns}

      {:control, :recur, values, %EvalContext{}} ->
        {:error, {:invalid_recur, values}}
    end
  end

  @spec eval_with_context(CoreAST.t(), map(), map(), env(), tool_executor(), list(), keyword()) ::
          outcome()
  def eval_with_context(ast, ctx, memory, env, tool_executor, turn_history \\ [], opts \\ []) do
    case eval_with_context_captured(ast, ctx, memory, env, tool_executor, turn_history, opts) do
      {:raise, kind, reason, stacktrace, _final_ctx} ->
        :erlang.raise(kind, reason, stacktrace)

      outcome ->
        outcome
    end
  end

  @doc false
  @spec eval_with_context_captured(
          CoreAST.t(),
          map(),
          map(),
          env(),
          tool_executor(),
          list(),
          keyword()
        ) :: outcome() | Capture.value_result()
  def eval_with_context_captured(
        ast,
        ctx,
        memory,
        env,
        tool_executor,
        turn_history \\ [],
        opts \\ []
      ) do
    tool_executor = normalize_tool_executor(tool_executor)
    eval_ctx = EvalContext.new(ctx, memory, env, tool_executor, turn_history, opts)

    case HostContext.run_outcome(eval_ctx, &do_eval/2, fn ->
           normalize_outcome(do_eval(ast, eval_ctx), eval_ctx)
         end) do
      {:ok, value, final_ctx} ->
        {:ok, value, final_ctx}

      {:error, reason, final_ctx} ->
        {:error, reason, final_ctx}

      {:control, :return, value, final_ctx} ->
        Outcome.control(:return, value, final_ctx)

      {:control, :fail, value, final_ctx} ->
        Outcome.control(:fail, value, final_ctx)

      {:control, :recur, values, final_ctx} ->
        Outcome.control(:recur, values, final_ctx)

      {:raise, _kind, _reason, _stacktrace, _final_ctx} = raised ->
        raised
    end
  end

  defp normalize_outcome({:ok, value, %EvalContext{} = context}, _fallback),
    do: Outcome.ok(value, context)

  defp normalize_outcome({:error, reason}, %EvalContext{} = fallback),
    do: Outcome.error(reason, Capture.materialize_context(fallback))

  defp eval_child(ast, %EvalContext{} = context) do
    case do_eval(ast, context) do
      {:ok, _value, %EvalContext{}} = outcome -> outcome
      {:error, reason} -> Abort.error!(reason, context)
    end
  end

  defp normalize_tool_executor(tool_executor) when is_function(tool_executor, 3),
    do: tool_executor

  defp normalize_tool_executor(tool_executor) when is_function(tool_executor, 2) do
    fn name, args, _origin -> tool_executor.(name, args) end
  end

  defp capability_failure_source?({:tool_call, _name, _args}, _eval_ctx), do: true

  defp capability_failure_source?({:var, name}, eval_ctx),
    do: capability_result_binding?(eval_ctx, name)

  defp capability_failure_source?(_error_ast, _eval_ctx), do: false

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
      # `evaluated_pairs` is in reverse source order (eval_map_pair prepends).
      # Reverse before Map.new so a runtime key collision keeps the LAST value
      # in source order — consistent with `hash-map`/`array-map` and Clojure.
      # (Structurally-equal literal key forms are already rejected at analyze.)
      {:ok, evaluated_pairs, eval_ctx2} ->
        {:ok, Map.new(Enum.reverse(evaluated_pairs)), eval_ctx2}

      {:error, _} = err ->
        err
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
         :error <- resolve_builtin(name, eval_ctx) do
      unresolved_var(name)
    end
  end

  # Data access: data/input → ctx[:input]
  #
  # When `strict_data: true`, accessing a key that was not supplied raises a
  # runtime error naming the binding. In permissive mode the lookup returns
  # `nil` for unknown keys.
  defp do_eval({:data, key}, %EvalContext{ctx: ctx, strict_data: true} = eval_ctx) do
    case data_fetch(ctx, key) do
      {:ok, value} ->
        {:ok, value, eval_ctx}

      :error ->
        {:error,
         {:runtime_error,
          "data/#{key} is not bound: the `context` object did not provide a `#{key}` key", nil}}
    end
  end

  defp do_eval({:data, key}, %EvalContext{ctx: ctx} = eval_ctx) do
    value =
      case data_fetch(ctx, key) do
        {:ok, found} -> found
        :error -> nil
      end

    {:ok, value, eval_ctx}
  end

  defp do_eval({:runtime_callable, namespace, name}, %EvalContext{} = eval_ctx) do
    {:ok, RuntimeCallable.new(namespace, name), eval_ctx}
  end

  defp do_eval({:java_ref, reference_id}, %EvalContext{} = eval_ctx) do
    case JavaCallable.new(reference_id) do
      {:ok, callable} ->
        {:ok, callable, eval_ctx}

      :error ->
        condition =
          JavaCondition.new(
            :unsupported_java_member,
            reference_id,
            nil,
            "unsupported Java callable reference"
          )

        {:error, JavaCondition.evaluator_error(condition)}
    end
  end

  defp do_eval({:java_static, reference_id, argument_asts}, %EvalContext{} = eval_ctx) do
    with {:ok, arguments, eval_ctx2} <- eval_all(argument_asts, eval_ctx) do
      eval_java_dispatch(reference_id, :static, nil, arguments, eval_ctx2)
    end
  end

  defp do_eval({:java_new, reference_id, argument_asts}, %EvalContext{} = eval_ctx) do
    with {:ok, arguments, eval_ctx2} <- eval_all(argument_asts, eval_ctx) do
      eval_java_dispatch(reference_id, :constructor, nil, arguments, eval_ctx2)
    end
  end

  defp do_eval({:java_field, reference_id}, %EvalContext{} = eval_ctx) do
    eval_java_dispatch(reference_id, :field, nil, [], eval_ctx)
  end

  defp do_eval(
         {:java_instance, reference_id, receiver_ast, argument_asts},
         %EvalContext{} = eval_ctx
       ) do
    with {:ok, receiver, eval_ctx2} <- eval_child(receiver_ast, eval_ctx),
         {:ok, arguments, eval_ctx3} <- eval_all(argument_asts, eval_ctx2) do
      eval_java_dispatch(reference_id, :instance, receiver, arguments, eval_ctx3)
    end
  end

  defp do_eval(
         {:java_dot, member_family_id, receiver_ast, argument_asts},
         %EvalContext{} = eval_ctx
       ) do
    with {:ok, receiver, eval_ctx2} <- eval_child(receiver_ast, eval_ctx),
         {:ok, arguments, eval_ctx3} <- eval_all(argument_asts, eval_ctx2) do
      case JavaDispatch.invoke_family(member_family_id, receiver, arguments) do
        {:ok, value, _overload_id} -> {:ok, value, eval_ctx3}
        {:error, condition} -> {:error, JavaCondition.evaluator_error(condition)}
      end
    end
  end

  # Define binding in user namespace: (def name value opts)
  # Returns the var, not the value (Clojure semantics)
  # Opts may contain :docstring which is merged into closure metadata for functions
  defp do_eval({:def, name, value_ast, opts}, %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- eval_child(value_ast, eval_ctx) do
      # Merge docstring into closure metadata if value is a closure, but never
      # persist ephemeral private-tool authority from a value-position prelude ref.
      value = value |> merge_docstring_into_closure(opts) |> strip_prelude_tool_authority()

      new_user_ns = Map.put(eval_ctx2.user_ns, user_ns_key(name), value)

      {:ok, %Var{name: name}, EvalContext.update_user_ns(eval_ctx2, new_user_ns)}
    end
  end

  # Idempotent define: (defonce name value opts)
  # Binds name only if not already defined in user_ns.
  # Value expression is NOT evaluated when name is already bound.
  defp do_eval({:defonce, name, value_ast, opts}, %EvalContext{user_ns: user_ns} = eval_ctx) do
    key = user_ns_key(name)

    if Map.has_key?(user_ns, key) do
      {:ok, %Var{name: name}, eval_ctx}
    else
      with {:ok, value, eval_ctx2} <- eval_child(value_ast, eval_ctx) do
        value = value |> merge_docstring_into_closure(opts) |> strip_prelude_tool_authority()
        new_user_ns = Map.put(eval_ctx2.user_ns, key, value)
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
    with {:ok, cond_val, eval_ctx2} <- eval_child(cond_ast, eval_ctx) do
      if truthy?(cond_val) do
        eval_child(then_ast, eval_ctx2)
      else
        eval_child(else_ast, eval_ctx2)
      end
    end
  end

  # Let bindings
  defp do_eval({:let, bindings, body}, %EvalContext{} = eval_ctx) do
    new_ctx =
      Enum.reduce(bindings, eval_ctx, fn {:binding, pattern, value_ast}, acc_ctx ->
        {:ok, value, value_ctx} = eval_child(value_ast, acc_ctx)

        case Patterns.match_pattern(pattern, value) do
          {:ok, new_bindings} ->
            new_bindings
            |> maybe_mark_capability_result_binding(pattern, value_ast)
            |> then(&EvalContext.merge_env(value_ctx, &1))

          {:error, reason} ->
            Abort.error!(reason, value_ctx)
        end
      end)

    {:ok, value, final_ctx} = eval_child(body, new_ctx)
    {:ok, value, %{final_ctx | env: eval_ctx.env, locals: eval_ctx.locals}}
  end

  # Tail recursion: loop
  defp do_eval({:loop, bindings, body}, %EvalContext{} = eval_ctx) do
    loop_ctx =
      Enum.reduce(bindings, eval_ctx, fn {:binding, pattern, value_ast}, acc_ctx ->
        {:ok, value, value_ctx} = eval_child(value_ast, acc_ctx)

        case Patterns.match_pattern(pattern, value) do
          {:ok, new_bindings} ->
            new_bindings
            |> maybe_mark_capability_result_binding(pattern, value_ast)
            |> then(&EvalContext.merge_env(value_ctx, &1))

          {:error, reason} ->
            Abort.error!(reason, value_ctx)
        end
      end)

    {:ok, value, final_ctx} = execute_loop(body, loop_ctx, bindings)
    {:ok, value, %{final_ctx | env: eval_ctx.env, locals: eval_ctx.locals}}
  end

  # Tail recursion: recur signal
  defp do_eval({:recur, arg_asts}, %EvalContext{} = eval_ctx) do
    # Evaluate arguments in current context
    case eval_all(arg_asts, eval_ctx) do
      {:ok, values, ctx} ->
        # Include accumulated state in signal so it's preserved across iterations
        Abort.control!(:recur, values, ctx)

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
    meta = captured_locals |> locals_meta(%{}) |> maybe_mark_prelude_internal(eval_ctx)
    {:ok, {:closure, params, body, captured_env, [], meta}, eval_ctx}
  end

  # Named fn: (fn name [params] body) — name is bound inside body for self-recursion
  defp do_eval({:fn, name, params, body}, %EvalContext{} = eval_ctx) do
    {captured_env, captured_locals} = capture_lexical_scope(eval_ctx, params, body, [name])

    meta =
      captured_locals |> locals_meta(%{fn_name: name}) |> maybe_mark_prelude_internal(eval_ctx)

    {:ok, {:closure, params, body, captured_env, [], meta}, eval_ctx}
  end

  # ============================================================
  # Function calls
  # ============================================================

  defp do_eval(
         {:call, {:var, :take} = take_ast,
          [n_ast, {:call, {:var, :range} = range_ast, [start_ast, end_ast, step_ast]}]},
         %EvalContext{} = eval_ctx
       ) do
    with {:ok, take_fun, eval_ctx1} <- eval_child(take_ast, eval_ctx),
         {:ok, n, eval_ctx2} <- eval_child(n_ast, eval_ctx1),
         {:ok, range_fun, eval_ctx3} <- eval_child(range_ast, eval_ctx2),
         {:ok, [start, end_val, step], eval_ctx4} <-
           eval_all([start_ast, end_ast, step_ast], eval_ctx3) do
      if builtin_named?(take_fun, :take) and builtin_named?(range_fun, :range) and
           zero_number?(step) and is_integer(n) and is_number(start) and is_number(end_val) do
        {:ok, List.duplicate(start, max(n, 0)), eval_ctx4}
      else
        with {:ok, range_val, eval_ctx5} <-
               Apply.apply_fun(range_fun, [start, end_val, step], eval_ctx4, &do_eval/2) do
          Apply.apply_fun(take_fun, [n, range_val], eval_ctx5, &do_eval/2)
        end
      end
    end
  end

  defp do_eval({:call, fun_ast, arg_asts}, %EvalContext{} = eval_ctx) do
    with {:ok, fun_val, eval_ctx1} <- eval_child(fun_ast, eval_ctx),
         {:ok, arg_vals, eval_ctx2} <- eval_all(arg_asts, eval_ctx1) do
      arg_vals =
        maybe_mark_capability_closure_args(fun_val, arg_asts, arg_vals, eval_ctx2)

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

  # Defense in depth for direct CoreAST eval: juxt requires at least one
  # function (also rejected at analysis time — see GAP-S110).
  defp do_eval({:juxt, []}, %EvalContext{}) do
    {:error, {:invalid_arity, :juxt, "expected (juxt f ...) with at least one function"}}
  end

  defp do_eval({:juxt, func_asts}, %EvalContext{} = eval_ctx) do
    case eval_all(func_asts, eval_ctx) do
      {:ok, fns, eval_ctx2} ->
        {:ok, {:juxt_fn, fns}, eval_ctx2}

      {:error, _} = err ->
        err
    end
  end

  # ============================================================
  # Parallel map: pmap
  # ============================================================

  defp do_eval({:pmap, fn_ast, coll_asts}, %EvalContext{} = eval_ctx) do
    case resolve_user_ns(:pmap, eval_ctx.user_ns, eval_ctx) do
      {:ok, callable, callable_ctx} ->
        with {:ok, args, args_ctx} <- eval_all([fn_ast | coll_asts], callable_ctx) do
          Apply.apply_fun(callable, args, args_ctx, &do_eval/2)
        end

      :error ->
        with {:ok, fn_val, eval_ctx1} <- eval_child(fn_ast, eval_ctx),
             {:ok, coll_vals, eval_ctx2} <- eval_all(coll_asts, eval_ctx1) do
          Parallel.eval_pmap(fn_val, coll_vals, eval_ctx2, &do_eval/2)
        end
    end
  end

  # ============================================================
  # Parallel calls: pcalls
  # ============================================================

  defp do_eval({:pcalls, fn_asts}, %EvalContext{} = eval_ctx) do
    case resolve_user_ns(:pcalls, eval_ctx.user_ns, eval_ctx) do
      {:ok, callable, callable_ctx} ->
        with {:ok, args, args_ctx} <- eval_all(fn_asts, callable_ctx) do
          Apply.apply_fun(callable, args, args_ctx, &do_eval/2)
        end

      :error ->
        case eval_all(fn_asts, eval_ctx) do
          {:ok, fn_vals, eval_ctx2} ->
            Parallel.eval_pcalls(fn_vals, eval_ctx2, &do_eval/2)

          {:error, _} = err ->
            err
        end
    end
  end

  # Control flow signals: return and fail
  defp do_eval({:return, value_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- eval_child(value_ast, eval_ctx) do
      eval_ctx2 =
        if match?({:tool_call, _name, _arguments}, value_ast),
          do: EvalContext.mark_direct_tool_return(eval_ctx2),
          else: eval_ctx2

      Abort.control!(:return, value, eval_ctx2)
    end
  end

  defp do_eval({:fail, error_ast}, %EvalContext{} = eval_ctx) do
    with {:ok, error, eval_ctx2} <- eval_child(error_ast, eval_ctx) do
      eval_ctx2 =
        if capability_failure_source?(error_ast, eval_ctx2),
          do: EvalContext.mark_capability_failure(eval_ctx2),
          else: eval_ctx2

      Abort.control!(:fail, error, eval_ctx2)
    end
  end

  # Tool invocation via tool/ namespace: (tool/name args...)
  # Public prelude export reference in value position: resolve the captured
  # callable from the export table. A value-position ref is used as a HOF
  # argument (e.g. `(map crm/double-it xs)`), where the closure runs against the
  # CALLER's env, not the prelude env — so we fold the private prelude env into
  # the returned closure's captured scope. Its private sibling helpers then
  # resolve lexically wherever it is applied, while user code still cannot name
  # them (they are not in the export table). Non-closure callables (e.g. a `def`
  # constant) pass through unchanged.
  defp do_eval(
         {:prelude_ref, ref},
         %EvalContext{prelude_exports: exports} = eval_ctx
       ) do
    with :ok <- authorize_prelude_resolution(ref, eval_ctx) do
      case Map.fetch(exports, ref) do
        {:ok, {callable, _ns_env, export}} ->
          {:ok, bind_prelude_ref(callable, export), eval_ctx}

        :error ->
          {:error, {:unbound_var, ref}}
      end
    end
  end

  # Public prelude export call: `(crm/get-user id)`. Resolve the captured
  # closure from the export table and invoke it with the captured PRIVATE
  # prelude env as its `user_ns` layer so the export body's private sibling
  # helpers resolve. Side-effecting accumulators (tool_calls/ledger,
  # prints, cache, ...) are carried IN from and OUT to the caller's context so
  # the wrapped `(tool/call ...)` records exactly once in the existing ledger.
  defp do_eval({:prelude_call, ref, arg_asts}, %EvalContext{prelude_exports: exports} = eval_ctx) do
    with :ok <- authorize_prelude_resolution(ref, eval_ctx) do
      case Map.fetch(exports, ref) do
        {:ok, {callable, ns_env, export}} ->
          with {:ok, arg_vals, eval_ctx2} <- eval_all(arg_asts, eval_ctx) do
            arg_vals =
              maybe_mark_capability_prelude_args(ref, arg_asts, arg_vals, eval_ctx2)

            eval_prelude_callable(callable, arg_vals, ns_env, export, eval_ctx2)
          end

        :error ->
          {:error, {:unbound_var, ref}}
      end
    end
  end

  defp do_eval({:tool_call, tool_name, arg_asts}, %EvalContext{tool_exec: tool_exec} = eval_ctx) do
    # Evaluate all arguments
    case eval_all(arg_asts, eval_ctx) do
      {:ok, arg_vals, eval_ctx2} ->
        tool_name_str = to_string(tool_name)
        tool_meta = Map.get(eval_ctx2.tools_meta, tool_name_str, %{})

        # Convert args list to map for tool executor.
        case build_args_map(arg_vals, tool_name, tool_meta) do
          {:ok, args_map} ->
            # Check if this tool has caching enabled
            cacheable? =
              Map.get(tool_meta, :cache) == true and Map.get(tool_meta, :visibility) != :private

            origin = EvalContext.current_origin(eval_ctx2)
            private_tool? = Map.get(tool_meta, :visibility) == :private
            ledger_arguments = Map.get(tool_meta, :ledger_arguments, :full)

            case prepare_tool_args(args_map, tool_meta, tool_name_str) do
              {:ok, prepared_args} ->
                record_tool_call(
                  tool_name_str,
                  prepared_args,
                  tool_exec,
                  eval_ctx2,
                  cacheable?,
                  origin,
                  private_tool?,
                  ledger_arguments
                )

              {:error, _reason} = error ->
                error
            end

          {:error, {:java_projection_error, reason}} ->
            {:error, {:tool_error, to_string(tool_name), {:java_projection_error, reason}}}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp prepare_tool_args(args_map, tool_meta, tool_name) do
    if Map.get(tool_meta, :argument_projection) == :raw do
      {:ok, args_map}
    else
      case Format.externalize_symbol_refs(args_map) do
        {:ok, public_args} ->
          project_tool_args(public_args, tool_meta, tool_name)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp project_tool_args(public_args, tool_meta, tool_name) do
    case JavaProject.project(public_args, :tool_argument, Map.get(tool_meta, :signature)) do
      {:ok, prepared_args} ->
        {:ok, prepared_args}

      {:error, reason} ->
        {:error, {:tool_error, tool_name, {:java_projection_error, reason}}}
    end
  end

  defp eval_java_dispatch(reference_id, kind, receiver, arguments, eval_ctx) do
    case JavaDispatch.invoke(reference_id, kind, receiver, arguments) do
      {:ok, value, _overload_id} -> {:ok, value, eval_ctx}
      {:error, condition} -> {:error, JavaCondition.evaluator_error(condition)}
    end
  end

  defp eval_prelude_callable(
         {:closure, _params, _body, _env, _th, _meta} = callable,
         arg_vals,
         ns_env,
         export,
         eval_ctx
       ) do
    invoke_prelude_export(callable, arg_vals, ns_env, export, eval_ctx)
  end

  # A constant export (`def name value`) captures a plain value, not a closure.
  # The analyzer only admits a zero-arg call here, which yields the captured
  # value (Clojure-style: `cfg/answer` is the value, not a function to apply).
  defp eval_prelude_callable(value, [], _ns_env, _export, eval_ctx), do: {:ok, value, eval_ctx}

  defp eval_prelude_callable(callable, arg_vals, ns_env, export, eval_ctx) do
    invoke_prelude_export(callable, arg_vals, ns_env, export, eval_ctx)
  end

  # ============================================================
  # Prelude export invocation
  # ============================================================

  # Tag a closure with its prelude NAMESPACE NAME (an opaque, already-public
  # string) — NOT its private env. When the closure is later applied (as a HOF
  # value, or after being returned / `def`'d), the applier resolves the
  # namespace's private env from the ATTACHED prelude and runs the body against
  # it, restoring the caller's namespace afterward. Tagging the name rather than
  # the env keeps private helper names/bodies out of user-visible Step data while
  # giving value-position exports the same isolation as a direct `(crm/export …)`
  # call. Non-closure callables (e.g. a `def` constant) are returned unchanged.
  defp bind_prelude_ref({:closure, params, body, captured_env, turn_history, meta}, export) do
    meta =
      meta
      |> Map.put(:prelude_ns, Map.fetch!(export, :namespace))
      |> Map.put(:prelude_ref, Map.fetch!(export, :ref))
      |> Map.put(:prelude_tool_refs, Map.get(export, :tool_refs, []))
      |> put_prelude_contract(export)

    {:closure, params, body, captured_env, turn_history, meta}
  end

  defp bind_prelude_ref(callable, _export), do: callable

  defp put_prelude_contract(meta, %{parsed_signature: signature, signature: display, ref: ref})
       when is_tuple(signature) and is_binary(display) and is_binary(ref) do
    Map.put(meta, :prelude_contract, %{ref: ref, signature: signature, display: display})
  end

  defp put_prelude_contract(meta, _export), do: meta

  # Invoke a captured prelude export closure against its OWN namespace's private
  # env.
  #
  # The closure runs in a derived context whose `user_ns` is `ns_env` — the
  # export's namespace slice of the captured `private_env` (so the export body's
  # sibling helpers resolve by bare name through `do_execute_closure`'s user_ns
  # threading, and only within its own namespace), while every other field —
  # tool executor, side-effect accumulators, limits, caches — is inherited from
  # the caller so the wrapped `(tool/call ...)` records once in the EXISTING
  # ledger. On return, the accumulators flow back onto the caller's context and
  # the caller's own `user_ns` is restored unchanged: a prelude export cannot
  # mutate user memory, and user code cannot reach the private env.
  defp invoke_prelude_export(callable, args, ns_env, export, %EvalContext{} = caller_ctx) do
    ns_name = Map.fetch!(export, :namespace)
    callable = bind_prelude_ref(callable, export)

    export_ctx =
      caller_ctx
      |> Map.put(:user_ns, PreludeClosure.tag_internal_environment(ns_env, ns_name))
      |> EvalContext.push_prelude_caller_user_ns(caller_ctx.user_ns)
      |> EvalContext.push_prelude_origin(export)

    try do
      case Apply.apply_fun(callable, args, export_ctx, &do_eval/2) do
        {:ok, result, final_ctx} ->
          # If the export RETURNS a closure (e.g. `(defn make [] (fn [x] (helper
          # x)))`), tag it with the prelude namespace name so its private-helper
          # references still resolve when the caller applies it later. Non-closure
          # results pass through unchanged.
          {:ok, PreludeClosure.tag_namespace(result, ns_name),
           merge_export_effects(caller_ctx, final_ctx)}

        {:error, reason} ->
          {:error, Helpers.sanitize_private_error(reason, %{ref: export.ref})}
      end
    rescue
      error in Abort ->
        case error.outcome do
          {:control, :return, value, %EvalContext{} = abort_ctx} ->
            Abort.control!(
              :return,
              PreludeClosure.tag_namespace(value, ns_name),
              merge_export_effects(caller_ctx, abort_ctx)
            )

          {:control, :fail, value, %EvalContext{} = abort_ctx} ->
            Abort.control!(:fail, value, merge_export_effects(caller_ctx, abort_ctx))

          {:error, reason, %EvalContext{} = abort_ctx} ->
            Abort.error!(
              Helpers.sanitize_private_error(reason, %{ref: export.ref}),
              merge_export_effects(caller_ctx, abort_ctx)
            )

          _other ->
            reraise error, __STACKTRACE__
        end
    end
  end

  # Carry the export body's side-effecting accumulators (ledger, prints, cache,
  # iteration count) back onto the caller's context while keeping the caller's
  # own `user_ns`/`env`/`prelude` tables — a prelude export cannot mutate user
  # memory, and user code cannot reach the private prelude env.
  defp merge_export_effects(%EvalContext{} = caller_ctx, %EvalContext{} = export_ctx) do
    %{
      caller_ctx
      | effects: export_ctx.effects,
        iteration_count: export_ctx.iteration_count,
        failure_origin: export_ctx.failure_origin,
        return_origin: export_ctx.return_origin
    }
  end

  defp authorize_prelude_resolution(
         ref,
         %EvalContext{strict_transitive_calls: true} = eval_ctx
       )
       when is_binary(ref) do
    if EvalContext.prelude_ref_visible?(eval_ctx, ref) do
      :ok
    else
      namespace = EvalContext.ref_namespace(ref)
      requirers = EvalContext.transitive_namespace_requirers(eval_ctx, namespace)
      {:error, {:transitive_call_unauthorized, ref, namespace, requirers}}
    end
  end

  defp authorize_prelude_resolution(_ref, %EvalContext{}), do: :ok

  # ============================================================
  # Evaluation helpers
  # ============================================================

  defp resolve_local(name, locals, env, eval_ctx) do
    if MapSet.member?(locals, name),
      do: {:ok, env |> Map.get(name) |> unwrap_binding(), eval_ctx},
      else: :error
  end

  defp resolve_user_ns(name, user_ns, eval_ctx) do
    case Map.fetch(user_ns, user_ns_key(name)) do
      {:ok, value} -> {:ok, value, eval_ctx}
      :error -> :error
    end
  end

  defp resolve_env(name, env, eval_ctx) do
    case Map.fetch(env, name) do
      {:ok, value} -> {:ok, unwrap_binding(value), eval_ctx}
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

  defp builtin_named?(%Builtin{name: name}, name), do: true
  defp builtin_named?(_, _), do: false

  defp zero_number?(n) when is_number(n), do: n == 0
  defp zero_number?(_), do: false

  defp unwrap_binding(%CapabilityResult{value: value}), do: value
  defp unwrap_binding(value), do: unwrap_constant(value)

  defp unwrap_constant({:constant, value}), do: value
  defp unwrap_constant(other), do: other

  defp maybe_mark_capability_result_binding(
         bindings,
         {:var, name},
         {:tool_call, _tool_name, _arguments}
       ) do
    Map.update!(bindings, name, &%CapabilityResult{value: &1})
  end

  defp maybe_mark_capability_result_binding(bindings, _pattern, _value_ast), do: bindings

  defp maybe_mark_capability_prelude_args(
         "cap/unwrap!",
         [argument_ast],
         [argument],
         eval_ctx
       ) do
    if capability_failure_source?(argument_ast, eval_ctx),
      do: [%CapabilityResult{value: argument}],
      else: [argument]
  end

  defp maybe_mark_capability_prelude_args(_ref, _argument_asts, arguments, _eval_ctx),
    do: arguments

  defp maybe_mark_capability_closure_args(
         {:closure, _patterns, _body, _env, _turn_history, _meta},
         argument_asts,
         arguments,
         eval_ctx
       ) do
    Enum.zip_with(argument_asts, arguments, fn argument_ast, argument ->
      if capability_failure_source?(argument_ast, eval_ctx),
        do: %CapabilityResult{value: argument},
        else: argument
    end)
  end

  defp maybe_mark_capability_closure_args(
         _callable,
         _argument_asts,
         arguments,
         _eval_ctx
       ),
       do: arguments

  defp capability_result_binding?(%EvalContext{locals: locals, env: env}, name) do
    MapSet.member?(locals, name) and match?(%CapabilityResult{}, Map.get(env, name))
  end

  defp unresolved_var(name) do
    name_str = to_string(name)

    if String.starts_with?(name_str, ".") do
      available =
        JavaSurface.references()
        |> Enum.filter(&(&1.kind == :instance))
        |> Enum.flat_map(& &1.spellings)
        |> Enum.uniq()
        |> Enum.sort()
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

  defp strip_prelude_tool_authority({:closure, params, body, env, turn_history, metadata}) do
    env = strip_prelude_tool_authority(env)
    turn_history = strip_prelude_tool_authority(turn_history)
    metadata = Map.drop(metadata, [:prelude_ref, :prelude_tool_refs])
    {:closure, params, body, env, turn_history, metadata}
  end

  defp strip_prelude_tool_authority(values) when is_list(values) do
    Enum.map(values, &strip_prelude_tool_authority/1)
  end

  defp strip_prelude_tool_authority(%MapSet{} = values) do
    values
    |> Enum.map(&strip_prelude_tool_authority/1)
    |> MapSet.new()
  end

  defp strip_prelude_tool_authority(values) when is_map(values) and not is_struct(values) do
    Map.new(values, fn {key, value} ->
      {strip_prelude_tool_authority(key), strip_prelude_tool_authority(value)}
    end)
  end

  defp strip_prelude_tool_authority(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&strip_prelude_tool_authority/1)
    |> List.to_tuple()
  end

  defp strip_prelude_tool_authority(value), do: value

  # Build args map from a list of evaluated arguments for tool calls.
  # Tools require named arguments (maps). Returns {:ok, map} or {:error, reason}.
  # - No arguments: return empty map
  # - Single map argument: pass through as-is (keys converted to strings)
  # - Keyword-style list [:key1, val1, :key2, val2]: convert to map with string keys
  # - Other cases: error (positional arguments not allowed)
  #
  # Ordinary tool maps are converted to string keys at the tool boundary to:
  # - Prevent atom memory leaks from LLM-generated keywords
  # - Match JSON conventions (like Phoenix params)
  # One trusted internal tool may request `:raw` projection when it must apply
  # another bounded host projection itself. That route still requires exactly
  # one map argument and is never exposed by the ordinary tool constructors.
  defp build_args_map([arg], _tool_name, %{argument_projection: :raw})
       when is_map(arg) and not is_struct(arg),
       do: {:ok, arg}

  defp build_args_map(args, tool_name, _tool_meta), do: build_args_map(args, tool_name)

  defp build_args_map([], _tool_name), do: {:ok, %{}}

  defp build_args_map([{:symbol_ref, ref}, args], tool_name)
       when is_binary(ref) and is_map(args) and not is_struct(args) do
    cond do
      not tool_call_name?(tool_name) ->
        invalid_positional_args([{:symbol_ref, ref}, args], tool_name)

      not Format.SymbolRef.valid_name?(ref) ->
        {:error, {:invalid_symbol_ref, []}}

      true ->
        case String.split(ref, "/", parts: 2) do
          [server, tool] when server != "" and tool != "" ->
            case stringify_keys(args) do
              {:ok, normalized} ->
                {:ok, %{"server" => server, "tool" => tool, "args" => normalized}}

              :ambiguous ->
                {:ok, %AmbiguousArguments{}}

              {:error, _reason} = error ->
                error
            end

          _ ->
            {:error,
             {:invalid_tool_args,
              "tool/call symbol form requires a qualified symbol like 'server/tool"}}
        end
    end
  end

  defp build_args_map([{:symbol_ref, ref}], tool_name) when is_binary(ref) do
    if tool_call_name?(tool_name) do
      build_args_map([{:symbol_ref, ref}, %{}], tool_name)
    else
      invalid_positional_args([{:symbol_ref, ref}], tool_name)
    end
  end

  defp build_args_map([arg], _tool_name) when is_map(arg) and not is_struct(arg),
    do: normalized_args(arg)

  defp build_args_map(args, tool_name) do
    if keyword_style_args?(args) do
      case args_to_string_map(args) do
        {:ok, normalized} -> {:ok, normalized}
        :ambiguous -> {:ok, %AmbiguousArguments{}}
        {:error, _reason} = error -> error
      end
    else
      invalid_positional_args(args, tool_name)
    end
  end

  defp tool_call_name?(:call), do: true
  defp tool_call_name?("call"), do: true
  defp tool_call_name?(_), do: false

  defp invalid_positional_args(args, tool_name) do
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
    |> Enum.reduce_while({:ok, %{}}, fn [key, value], {:ok, normalized} ->
      with {:ok, normalized_key} <- stringify_key(key),
           false <- Map.has_key?(normalized, normalized_key),
           {:ok, normalized_value} <- stringify_value(value) do
        {:cont, {:ok, Map.put(normalized, normalized_key, normalized_value)}}
      else
        true -> {:halt, :ambiguous}
        :ambiguous -> {:halt, :ambiguous}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Recursively convert map keys to strings (for tool boundary).
  # Handles nested maps and lists to ensure full protection against atom leaks.
  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, normalized_key} <- stringify_key(key),
           false <- Map.has_key?(normalized, normalized_key),
           {:ok, normalized_value} <- stringify_value(value) do
        {:cont, {:ok, Map.put(normalized, normalized_key, normalized_value)}}
      else
        true -> {:halt, :ambiguous}
        :ambiguous -> {:halt, :ambiguous}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Recursively stringify values (for nested maps/lists in tool args).
  # A keyword value becomes its plain name string — deterministic and
  # JSON-friendly, matching how `stringify_key/1` handles keyword keys (#964).
  defp stringify_value(%LispKeyword{name: name} = keyword) do
    if LispKeyword.valid?(keyword),
      do: {:ok, name},
      else: {:error, {:invalid_keyword, []}}
  end

  defp stringify_value(map) when is_map(map) and not is_struct(map), do: stringify_keys(map)

  defp stringify_value(%MapSet{map: map} = set) when is_map(map) do
    values = Map.keys(map)

    if map_size(set) == 2 and MapSet.new(values) == set do
      values
      |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
        case stringify_value(value) do
          {:ok, item} -> {:cont, {:ok, [item | normalized]}}
          :ambiguous -> {:halt, :ambiguous}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, normalized} ->
          projected = MapSet.new(normalized)

          if MapSet.size(projected) == length(normalized),
            do: {:ok, projected},
            else: :ambiguous

        :ambiguous ->
          :ambiguous

        {:error, _reason} = error ->
          error
      end
    else
      {:error, {:invalid_projection_struct, [], MapSet}}
    end
  end

  defp stringify_value(%MapSet{}), do: {:error, {:invalid_projection_struct, [], MapSet}}

  defp stringify_value(struct) when is_struct(struct) do
    module = Map.fetch!(struct, :__struct__)

    struct
    |> Map.from_struct()
    |> Enum.reduce_while({:ok, %{}}, fn {field, value}, {:ok, normalized} ->
      case stringify_value(value) do
        {:ok, normalized_value} ->
          {:cont, {:ok, Map.put(normalized, field, normalized_value)}}

        :ambiguous ->
          {:halt, :ambiguous}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Map.put(normalized, :__struct__, module)}
      :ambiguous -> :ambiguous
      {:error, _reason} = error -> error
    end
  end

  defp stringify_value(list) when is_list(list) do
    if proper_list?(list) do
      Enum.reduce_while(list, {:ok, []}, fn value, {:ok, normalized} ->
        case stringify_value(value) do
          {:ok, item} -> {:cont, {:ok, [item | normalized]}}
          :ambiguous -> {:halt, :ambiguous}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        :ambiguous -> :ambiguous
        {:error, _reason} = error -> error
      end
    else
      {:error, {:invalid_lisp_list, []}}
    end
  end

  defp stringify_value(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, normalized} ->
      case stringify_value(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        :ambiguous -> {:halt, :ambiguous}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> List.to_tuple()}
      :ambiguous -> :ambiguous
      {:error, _reason} = error -> error
    end
  end

  defp stringify_value(other), do: {:ok, other}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp normalized_args(map) do
    case stringify_keys(map) do
      {:ok, normalized} -> {:ok, normalized}
      :ambiguous -> {:ok, %AmbiguousArguments{}}
      {:error, _reason} = error -> error
    end
  end

  defp stringify_key({:symbol_ref, name}) do
    if Format.SymbolRef.valid_name?(name),
      do: {:ok, %Format.SymbolRef{name: name}},
      else: {:error, {:invalid_symbol_ref, []}}
  end

  defp stringify_key(%{__struct__: Format.SymbolRef} = ref) do
    if Format.SymbolRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_symbol_ref, []}}
  end

  defp stringify_key(k) when is_atom(k), do: {:ok, KeyNormalizer.normalize_key(k)}

  defp stringify_key(%LispKeyword{name: name} = keyword) do
    if LispKeyword.valid?(keyword),
      do: {:ok, KeyNormalizer.normalize_key(name)},
      else: {:error, {:invalid_keyword, []}}
  end

  defp stringify_key(k) when is_binary(k), do: {:ok, KeyNormalizer.normalize_key(k)}

  defp stringify_key(%{__struct__: module} = key)
       when module in [
              JavaCallable,
              JavaPrimitive,
              JavaLocalDate,
              JavaInstant,
              JavaDuration,
              JavaDate
            ],
       do: {:ok, key}

  defp stringify_key(k) do
    with {:ok, public_key} <- Format.externalize_symbol_refs(k) do
      case JavaProject.project(public_key, :tool_argument) do
        {:ok, projected_key} -> {:ok, inspect(projected_key)}
        {:error, reason} -> {:error, {:java_projection_error, reason}}
      end
    end
  end

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
  # Nested host tools may wrap results with private trace-hierarchy metadata.
  # The wrapper is removed here so Lisp sees only the actual value.
  defp record_tool_call(
         tool_name,
         args_map,
         tool_exec,
         eval_ctx,
         cacheable?,
         origin,
         private_tool?,
         ledger_arguments
       ) do
    record_tool_call_inner(
      tool_name,
      args_map,
      tool_exec,
      eval_ctx,
      cacheable?,
      origin,
      private_tool?,
      ledger_arguments
    )
  end

  defp record_tool_call_inner(
         tool_name,
         args_map,
         tool_exec,
         eval_ctx,
         cacheable?,
         origin,
         private_tool?,
         ledger_arguments
       ) do
    # Only compute the canonical cache key when the call
    # is actually cacheable. Avoids the cost of canonicalization for
    # every non-cacheable tool call.
    cache_key = if cacheable?, do: KeyNormalizer.canonical_cache_key(tool_name, args_map)

    # Check cache for hit (cached calls don't count against limit - already counted)
    if cacheable? and Map.has_key?(eval_ctx.effects.tool_cache, cache_key) do
      cached = Map.get(eval_ctx.effects.tool_cache, cache_key)

      tool_call =
        %{
          name: tool_name,
          args: ledger_tool_args(args_map, private_tool?, ledger_arguments),
          result: ledger_tool_result(cached.result, private_tool?),
          error: nil,
          timestamp: DateTime.utc_now(),
          duration_ms: 0,
          cached: true
        }
        |> maybe_put_tool_origin(origin, private_tool?)

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
      maybe_put_child_result(cached.child_trace_id, cached.child_step)
      {:ok, cached.result, eval_ctx2}
    else
      case EvalContext.reserve_tool_call(eval_ctx) do
        {:error, :tool_call_limit_exceeded} ->
          {:error, {:tool_call_limit_exceeded, eval_ctx.max_tool_calls}}

        :ok ->
          record_tool_call_execute(
            tool_name,
            args_map,
            tool_exec,
            eval_ctx,
            cacheable?,
            cache_key,
            origin,
            {private_tool?, ledger_arguments}
          )
      end
    end
  end

  defp record_tool_call_execute(
         tool_name,
         args_map,
         tool_exec,
         eval_ctx,
         cacheable?,
         cache_key,
         origin,
         {private_tool?, ledger_arguments}
       ) do
    :ok = EvalContext.record_tool_activity(eval_ctx)
    start_time = System.monotonic_time(:millisecond)
    timestamp = DateTime.utc_now()
    failure_token = eval_ctx.tool_failure_token

    provider_result = execute_tool_provider(tool_exec, tool_name, args_map, origin)

    {raw_result, error, error_child_step, error_child_trace_id, tool_error_reason} =
      normalize_tool_provider_result(provider_result, failure_token, eval_ctx)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    # Remove nested trace-hierarchy metadata before the result reaches Lisp.
    {result, child_trace_id, child_step} = unwrap_tool_result(raw_result)

    {result, error, tool_error_reason} =
      case JavaProject.project(result, :tool_result) do
        {:ok, projected} ->
          case Format.internalize_symbol_refs(projected) do
            {:ok, internalized} ->
              {internalized, error, tool_error_reason}

            {:error, reason} ->
              projection_error = lisp_projection_error(reason)

              {nil, format_tool_failure(tool_name, projection_error),
               {:tool_error, tool_name, projection_error}}
          end

        {:error, reason} ->
          projection_error = {:java_projection_error, reason}

          {nil, format_tool_failure(tool_name, projection_error),
           {:tool_error, tool_name, projection_error}}
      end

    # Preserve nested metadata carried by a failed tool result.
    child_trace_id = normalize_child_trace_id(child_trace_id || error_child_trace_id)
    child_step = child_step || error_child_step

    {child_trace_id, child_step} =
      private_failure_child_metadata(child_trace_id, child_step, error, origin)

    tool_call =
      %{
        name: tool_name,
        args: ledger_tool_args(args_map, private_tool?, ledger_arguments),
        result: ledger_tool_result(result, private_tool?),
        error: ledger_tool_error(error, tool_name, origin),
        timestamp: timestamp,
        duration_ms: duration_ms
      }
      |> maybe_put_tool_origin(origin, private_tool?)

    # Retain an optional nested trace identity in the private effect ledger.
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

    # Child metadata is process-local so it never pollutes the Lisp value
    # space. Publish it before either outcome so parallel workers retain the
    # child hierarchy when the child tool itself fails. A metadata-less tool
    # must not erase a child result produced earlier in the same worker.
    maybe_put_child_result(child_trace_id, child_step)

    if error do
      Abort.error!(tool_error_reason || {:tool_error, tool_name, error}, eval_ctx2)
    else
      # Store in cache on success if cacheable (include child metadata for TraceTree)
      eval_ctx3 =
        if cacheable? do
          cached_entry = %{result: result, child_step: child_step, child_trace_id: child_trace_id}
          EvalContext.put_tool_cache(eval_ctx2, cache_key, cached_entry)
        else
          eval_ctx2
        end

      {:ok, result, eval_ctx3}
    end
  end

  defp execute_tool_provider(tool_exec, tool_name, args_map, origin) do
    {:ok,
     HostContext.without_context(fn ->
       tool_exec.(tool_name, args_map, origin)
     end)}
  rescue
    error -> {:error, error}
  end

  defp normalize_tool_provider_result({:ok, result}, failure_token, eval_ctx) do
    case result do
      {:__ptc_tool_failure__, ^failure_token, reason, message, data, false}
      when is_reference(failure_token) ->
        Abort.error!({reason, message, data}, eval_ctx)

      {:__ptc_tool_failure__, ^failure_token, :tool_error, name, data, true, child_trace_id,
       child_step}
      when is_reference(failure_token) ->
        {nil, format_tool_failure(name, data), child_step, child_trace_id,
         {:tool_error, name, data}}

      {:__ptc_tool_failure__, ^failure_token, :tool_error, name, data, true}
      when is_reference(failure_token) ->
        {nil, format_tool_failure(name, data), nil, nil, {:tool_error, name, data}}

      result ->
        {result, nil, nil, nil, nil}
    end
  end

  defp normalize_tool_provider_result({:error, error}, _failure_token, _eval_ctx) do
    {nil, Exception.message(error), nil, nil, nil}
  end

  defp format_tool_failure(name, data) do
    UntrustedRenderer.tool_failure(name, data)
  end

  defp lisp_projection_error({:invalid_keyword, _path} = reason),
    do: {:lisp_value_projection_error, reason}

  defp lisp_projection_error(reason), do: {:symbol_ref_projection_error, reason}

  defp maybe_put_child_result(nil, nil), do: :ok

  defp maybe_put_child_result(child_trace_id, child_step),
    do: ChildResult.put(child_trace_id, child_step)

  defp private_failure_child_metadata(
         _child_trace_id,
         _child_step,
         error,
         %{type: :prelude_export}
       )
       when not is_nil(error),
       do: {nil, nil}

  defp private_failure_child_metadata(child_trace_id, child_step, _error, _origin),
    do: {child_trace_id, child_step}

  defp maybe_put_tool_origin(tool_call, %{type: :prelude_export, ref: ref}, private_tool?) do
    tool_call
    |> Map.put(:origin, %{type: :prelude_export, ref: ref})
    |> maybe_put_private_tool(private_tool?)
  end

  defp maybe_put_tool_origin(tool_call, _origin, _private_tool?), do: tool_call

  defp maybe_put_private_tool(tool_call, true), do: Map.put(tool_call, :private, true)
  defp maybe_put_private_tool(tool_call, false), do: tool_call

  defp ledger_tool_args(args, true, projection) when is_function(projection, 1) do
    projection.(args)
  rescue
    _exception -> %{"redacted" => true}
  catch
    _kind, _reason -> %{"redacted" => true}
  end

  defp ledger_tool_args(args, true, _projection), do: redact_source_args(args)
  defp ledger_tool_args(args, false, :full), do: args

  defp ledger_tool_args(args, false, projection) when is_function(projection, 1) do
    projection.(args)
  rescue
    _exception -> %{"redacted" => true}
  catch
    _kind, _reason -> %{"redacted" => true}
  end

  defp ledger_tool_result(result, false), do: result
  defp ledger_tool_result(result, true), do: redact_source_args(result)

  defp ledger_tool_error(nil, _tool_name, _origin), do: nil

  defp ledger_tool_error(_error, tool_name, %{type: :prelude_export}) do
    format_tool_failure(tool_name, "private prelude tool execution failed")
  end

  defp ledger_tool_error(error, _tool_name, _origin), do: error

  defp redact_source_args(%{} = map) when not is_struct(map) do
    Map.new(map, fn
      {key, source} when key in ["source", :source] and is_binary(source) ->
        {key, source_arg_summary(source)}

      {key, metadata} when key in ["metadata", :metadata] ->
        {key, Metadata.public(metadata, complex: :drop)}

      {key, value} ->
        {key, redact_source_args(value)}
    end)
  end

  defp redact_source_args(values) when is_list(values),
    do: Enum.map(values, &redact_source_args/1)

  defp redact_source_args(value), do: value

  defp source_arg_summary(source) do
    %{
      "redacted" => true,
      "bytes" => byte_size(source),
      "sha256" => :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    }
  end

  # Unwrap tool results containing private trace-hierarchy metadata.
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

  defp normalize_child_trace_id(trace_id)
       when is_binary(trace_id) and byte_size(trace_id) in 1..@max_trace_id_bytes do
    if String.valid?(trace_id), do: trace_id, else: nil
  end

  defp normalize_child_trace_id(_trace_id), do: nil

  # Helper for map pair evaluation to reduce nesting
  defp eval_map_pair(k_ast, v_ast, %EvalContext{} = eval_ctx, acc) do
    with {:ok, k, eval_ctx2} <- eval_child(k_ast, eval_ctx),
         {:ok, v, eval_ctx3} <- eval_child(v_ast, eval_ctx2) do
      {:cont, {:ok, [{k, v} | acc], eval_ctx3}}
    end
  end

  # Evaluate all expressions in order, returning results in original order.
  defp eval_all(asts, eval_ctx) do
    result =
      Enum.reduce_while(asts, {:ok, [], eval_ctx}, fn ast, {:ok, acc, ctx} ->
        {:ok, value, next_ctx} = eval_child(ast, ctx)
        {:cont, {:ok, [value | acc], next_ctx}}
      end)

    case result do
      {:ok, vals, ctx} -> {:ok, Enum.reverse(vals), ctx}
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Strict-data lookup helpers (used by `do_eval({:data, key}, ...)`)
  # ============================================================

  # Public SymbolRef context keys internalize to `{:symbol_ref, name}` while
  # `data/'name` carries the display spelling. Preserve normal flexible lookup
  # precedence, then bridge that display spelling to the internal key.
  defp data_fetch(ctx, key) when is_map(ctx) do
    case flex_fetch(ctx, key) do
      {:ok, _value} = found -> found
      :error -> fetch_symbol_ref_data_key(ctx, key)
    end
  end

  defp data_fetch(_ctx, _key), do: :error

  defp fetch_symbol_ref_data_key(ctx, <<?', name::binary>>) do
    if Format.SymbolRef.valid_name?(name),
      do: Map.fetch(ctx, {:symbol_ref, name}),
      else: :error
  end

  defp fetch_symbol_ref_data_key(_ctx, _key), do: :error

  # ============================================================
  # Sequential evaluation helpers
  # ============================================================

  defp do_eval_do([], %EvalContext{} = eval_ctx), do: {:ok, nil, eval_ctx}

  defp do_eval_do([e], %EvalContext{} = eval_ctx) do
    eval_child(e, eval_ctx)
  end

  defp do_eval_do([e | rest], %EvalContext{} = eval_ctx) do
    with {:ok, _value, eval_ctx2} <- eval_child(e, eval_ctx) do
      do_eval_do(rest, eval_ctx2)
    end
  end

  # ============================================================
  # Short-circuit logic helpers
  # ============================================================

  defp do_eval_and([], last_value, %EvalContext{} = eval_ctx),
    do: {:ok, last_value, eval_ctx}

  defp do_eval_and([e | rest], _last_value, %EvalContext{} = eval_ctx) do
    with {:ok, value, eval_ctx2} <- eval_child(e, eval_ctx) do
      if truthy?(value) do
        do_eval_and(rest, value, eval_ctx2)
      else
        # Short-circuit: return falsy value
        {:ok, value, eval_ctx2}
      end
    end
  end

  # `(or ...)` evaluates clauses left-to-right, short-circuiting on the first
  # truthy value and otherwise returning the last evaluated value (nil when
  # empty). An unbound memory variable is treated as nil/falsy so that
  # `(or my-memory-var default)` is safe even on the first call.
  defp do_eval_or(exprs, %EvalContext{} = eval_ctx), do: do_eval_or(exprs, nil, eval_ctx)

  defp do_eval_or([], last_value, %EvalContext{} = eval_ctx), do: {:ok, last_value, eval_ctx}

  defp do_eval_or([e | rest], _last_value, %EvalContext{} = eval_ctx) do
    case eval_or_clause(e, eval_ctx) do
      {:ok, value, eval_ctx2} ->
        if truthy?(value) do
          {:ok, value, eval_ctx2}
        else
          do_eval_or(rest, value, eval_ctx2)
        end

      {:error, {:unbound_var, _name}} ->
        Logger.debug("[ptc-lisp] or: unbound value treated as nil")
        do_eval_or(rest, nil, eval_ctx)

      {:unbound, %EvalContext{} = normalized_ctx} ->
        Logger.debug("[ptc-lisp] or: nested unbound value treated as nil")
        do_eval_or(rest, nil, normalized_ctx)

      {:error, _} = err ->
        {:error, reason} = err
        Abort.error!(reason, eval_ctx)
    end
  end

  defp eval_or_clause(ast, %EvalContext{} = eval_ctx) do
    do_eval(ast, eval_ctx)
  rescue
    error in Abort ->
      case error.outcome do
        {:error, {:unbound_var, _name}, %EvalContext{} = abort_ctx} ->
          {:unbound, Capture.materialize_context(abort_ctx)}

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp maybe_mark_prelude_internal(meta, %EvalContext{} = eval_ctx) do
    case EvalContext.current_origin(eval_ctx) do
      %{type: :prelude_export, namespace: ns} when is_binary(ns) ->
        meta
        |> Map.put(:prelude_ns, ns)
        |> Map.put(:prelude_internal, true)

      %{type: :prelude_export} ->
        Map.put(meta, :prelude_internal, true)

      _origin ->
        meta
    end
  end

  # ============================================================
  # Loop Execution
  # ============================================================

  defp execute_loop(body, %EvalContext{} = ctx, bindings) do
    eval_child(body, ctx)
  rescue
    error in Abort ->
      case error.outcome do
        {:control, :recur, new_values, %EvalContext{} = abort_ctx} ->
          continue_loop(body, ctx, bindings, new_values, abort_ctx.effects)

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  defp continue_loop(body, ctx, bindings, new_values, effects) do
    patterns = Enum.map(bindings, fn {:binding, pattern, _} -> pattern end)
    recur_ctx = EvalContext.restore_recur_effects(ctx, effects)

    if length(patterns) != length(new_values) do
      Abort.error!({:arity_mismatch, length(patterns), length(new_values)}, recur_ctx)
    else
      with {:ok, new_bindings} <- bind_recur_values(patterns, new_values),
           {:ok, next_ctx} <- EvalContext.increment_iteration(recur_ctx) do
        execute_loop(body, EvalContext.merge_env(next_ctx, new_bindings), bindings)
      else
        {:error, :loop_limit_exceeded} ->
          Abort.error!({:loop_limit_exceeded, ctx.loop_limit}, recur_ctx)

        {:error, reason} ->
          Abort.error!(reason, recur_ctx)
      end
    end
  end

  defp bind_recur_values(patterns, values), do: Patterns.match_zipped(patterns, values)

  # ============================================================
  # REPL discovery dispatch
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
    with {:ok, value} <- Map.fetch(env, name),
         true <- MapSet.member?(locals, name) or not Map.has_key?(initial, name) do
      Map.put(acc, name, value)
    else
      _ -> acc
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

  defp keyword_runtime?(%LispKeyword{} = keyword), do: LispKeyword.valid?(keyword)
  defp keyword_runtime?(atom) when is_atom(atom), do: not is_nil(atom) and not is_boolean(atom)
  defp keyword_runtime?(_), do: false

  defp user_ns_key(name) when is_atom(name), do: Atom.to_string(name)
  defp user_ns_key(name), do: name
end
