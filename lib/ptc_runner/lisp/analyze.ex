defmodule PtcRunner.Lisp.Analyze do
  @moduledoc """
  Validates and desugars RawAST into CoreAST.

  The analyzer transforms the parser's output (RawAST) into a validated,
  desugared intermediate form (CoreAST) that the interpreter can safely evaluate.

  ## Error Handling

  Returns `{:ok, CoreAST.t()}` on success or `{:error, error_reason()}` on failure.
  """

  alias PtcRunner.Lisp.Analyze.Patterns
  alias PtcRunner.Lisp.Analyze.Predicates
  alias PtcRunner.Lisp.Analyze.ShortFn
  alias PtcRunner.Lisp.CoreAST

  @type error_reason ::
          {:invalid_form, String.t()}
          | {:invalid_arity, atom(), String.t()}
          | {:invalid_where_form, String.t()}
          | {:invalid_where_operator, atom()}
          | {:invalid_call_tool_name, any()}
          | {:invalid_cond_form, String.t()}
          | {:invalid_thread_form, atom(), String.t()}
          | {:unsupported_pattern, term()}
          | {:invalid_placeholder, atom()}

  @type scope :: :top_level | :lexical

  @spec analyze(term()) :: {:ok, CoreAST.t()} | {:error, error_reason()}
  def analyze(raw_ast) do
    do_analyze(raw_ast, :top_level)
  end

  # ============================================================
  # Literals and basic values
  # ============================================================

  defp do_analyze(nil, _scope), do: {:ok, nil}
  defp do_analyze(true, _scope), do: {:ok, true}
  defp do_analyze(false, _scope), do: {:ok, false}
  defp do_analyze(n, _scope) when is_integer(n) or is_float(n), do: {:ok, n}

  defp do_analyze({:string, s}, _scope), do: {:ok, {:string, s}}
  defp do_analyze({:keyword, k}, _scope), do: {:ok, {:keyword, k}}

  # ============================================================
  # Collections
  # ============================================================

  defp do_analyze({:vector, elems}, scope) do
    with {:ok, elems2} <- analyze_list(elems, scope) do
      {:ok, {:vector, elems2}}
    end
  end

  defp do_analyze({:map, pairs}, scope) do
    with {:ok, pairs2} <- analyze_pairs(pairs, scope) do
      {:ok, {:map, pairs2}}
    end
  end

  defp do_analyze({:set, elems}, scope) do
    with {:ok, elems2} <- analyze_list(elems, scope) do
      {:ok, {:set, elems2}}
    end
  end

  # ============================================================
  # Short function syntax: #()
  # ============================================================

  defp do_analyze({:short_fn, body_asts}, scope) do
    with {:ok, desugared_ast} <- ShortFn.desugar(body_asts) do
      do_analyze(desugared_ast, scope)
    end
  end

  # ============================================================
  # Symbols and variables
  # ============================================================

  defp do_analyze({:symbol, name}, _scope) do
    if placeholder?(name) do
      {:error, {:invalid_placeholder, name}}
    else
      {:ok, {:var, name}}
    end
  end

  defp do_analyze({:ns_symbol, :ctx, key}, _scope), do: {:ok, {:ctx, key}}

  # Unknown namespace - provide helpful error
  defp do_analyze({:ns_symbol, ns, key}, _scope) do
    {:error,
     {:invalid_form, "unknown namespace #{ns}/ in #{ns}/#{key}. Use ctx/ to access context"}}
  end

  # Turn history variables: *1, *2, *3
  defp do_analyze({:turn_history, n}, _scope) when n in [1, 2, 3], do: {:ok, {:turn_history, n}}

  # ============================================================
  # List forms (special forms and function calls)
  # ============================================================

  defp do_analyze({:list, [head | rest]} = list, scope) do
    dispatch_list_form(head, rest, list, scope)
  end

  defp do_analyze({:list, []}, _scope) do
    {:error, {:invalid_form, "Empty list is not a valid expression"}}
  end

  # Dispatch special forms based on the head symbol
  defp dispatch_list_form({:symbol, :let}, rest, _list, scope), do: analyze_let(rest, scope)
  defp dispatch_list_form({:symbol, :if}, rest, _list, scope), do: analyze_if(rest, scope)
  defp dispatch_list_form({:symbol, :fn}, rest, _list, scope), do: analyze_fn(rest, scope)
  defp dispatch_list_form({:symbol, :when}, rest, _list, scope), do: analyze_when(rest, scope)

  defp dispatch_list_form({:symbol, :"if-let"}, rest, _list, scope),
    do: analyze_if_let(rest, scope)

  defp dispatch_list_form({:symbol, :"when-let"}, rest, _list, scope),
    do: analyze_when_let(rest, scope)

  defp dispatch_list_form({:symbol, :cond}, rest, _list, scope), do: analyze_cond(rest, scope)

  defp dispatch_list_form({:symbol, :->}, rest, _list, scope),
    do: analyze_thread(:->, rest, scope)

  defp dispatch_list_form({:symbol, :"->>"}, rest, _list, scope),
    do: analyze_thread(:"->>", rest, scope)

  defp dispatch_list_form({:symbol, :do}, rest, _list, scope), do: analyze_do(rest, scope)
  defp dispatch_list_form({:symbol, :and}, rest, _list, scope), do: analyze_and(rest, scope)
  defp dispatch_list_form({:symbol, :or}, rest, _list, scope), do: analyze_or(rest, scope)
  defp dispatch_list_form({:symbol, :where}, rest, _list, scope), do: analyze_where(rest, scope)

  defp dispatch_list_form({:symbol, :"all-of"}, rest, _list, scope),
    do: analyze_pred_comb(:all_of, rest, scope)

  defp dispatch_list_form({:symbol, :"any-of"}, rest, _list, scope),
    do: analyze_pred_comb(:any_of, rest, scope)

  defp dispatch_list_form({:symbol, :"none-of"}, rest, _list, scope),
    do: analyze_pred_comb(:none_of, rest, scope)

  defp dispatch_list_form({:symbol, :juxt}, rest, _list, scope), do: analyze_juxt(rest, scope)

  defp dispatch_list_form({:symbol, :call}, rest, _list, scope),
    do: analyze_call_tool(rest, scope)

  defp dispatch_list_form({:symbol, :return}, rest, _list, scope),
    do: analyze_return(rest, scope)

  defp dispatch_list_form({:symbol, :fail}, rest, _list, scope), do: analyze_fail(rest, scope)

  # def/defn: check scope - only allowed at top level or inside do
  defp dispatch_list_form({:symbol, :def}, _rest, _list, :lexical) do
    {:error,
     {:invalid_form, "def creates global bindings; use let for local, or move def outside"}}
  end

  defp dispatch_list_form({:symbol, :def}, rest, _list, :top_level), do: analyze_def(rest)

  defp dispatch_list_form({:symbol, :defn}, _rest, _list, :lexical) do
    {:error,
     {:invalid_form, "defn creates global bindings; use let for local, or move defn outside"}}
  end

  defp dispatch_list_form({:symbol, :defn}, rest, _list, :top_level), do: analyze_defn(rest)

  # Tool invocation via ctx namespace: (ctx/tool-name args...)
  defp dispatch_list_form({:ns_symbol, :ctx, tool_name}, rest, _list, scope),
    do: analyze_ctx_call(tool_name, rest, scope)

  # Comparison operators (strict 2-arity per spec section 8.4)
  defp dispatch_list_form({:symbol, op}, rest, _list, scope)
       when op in [:=, :"not=", :>, :<, :>=, :<=],
       do: analyze_comparison(op, rest, scope)

  # Generic function call
  defp dispatch_list_form(_head, _rest, list, scope), do: analyze_call(list, scope)

  # ============================================================
  # Special form: let
  # ============================================================

  defp analyze_let([bindings_ast, body_ast], scope) do
    # Bindings are analyzed in the current scope
    # Body is analyzed in :lexical scope (def/defn not allowed)
    with {:ok, bindings} <- analyze_bindings(bindings_ast, scope),
         {:ok, body} <- do_analyze(body_ast, :lexical) do
      {:ok, {:let, bindings, body}}
    end
  end

  defp analyze_let(_, _scope) do
    {:error, {:invalid_arity, :let, "expected (let [bindings] body)"}}
  end

  defp analyze_bindings({:vector, elems}, scope) do
    if rem(length(elems), 2) != 0 do
      {:error, {:invalid_form, "let bindings require even number of forms"}}
    else
      elems
      |> Enum.chunk_every(2)
      |> Enum.reduce_while({:ok, []}, fn [pattern_ast, value_ast], {:ok, acc} ->
        with {:ok, pattern} <- analyze_pattern(pattern_ast),
             {:ok, value} <- do_analyze(value_ast, scope) do
          {:cont, {:ok, [{:binding, pattern, value} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, rev} -> {:ok, Enum.reverse(rev)}
        other -> other
      end
    end
  end

  defp analyze_bindings(_, _scope) do
    {:error, {:invalid_form, "let bindings must be a vector"}}
  end

  # ============================================================
  # Pattern analysis (destructuring)
  # Delegated to PtcRunner.Lisp.Analyze.Patterns
  # ============================================================

  defp analyze_pattern(ast), do: Patterns.analyze_pattern(ast)

  # ============================================================
  # Special form: if and when
  # ============================================================

  defp analyze_if([cond_ast, then_ast, else_ast], scope) do
    with {:ok, c} <- do_analyze(cond_ast, scope),
         {:ok, t} <- do_analyze(then_ast, scope),
         {:ok, e} <- do_analyze(else_ast, scope) do
      {:ok, {:if, c, t, e}}
    end
  end

  defp analyze_if(_, _scope) do
    {:error, {:invalid_arity, :if, "expected (if cond then else)"}}
  end

  defp analyze_when([cond_ast, body_ast], scope) do
    with {:ok, c} <- do_analyze(cond_ast, scope),
         {:ok, b} <- do_analyze(body_ast, scope) do
      {:ok, {:if, c, b, nil}}
    end
  end

  defp analyze_when(_, _scope) do
    {:error, {:invalid_arity, :when, "expected (when cond body)"}}
  end

  # ============================================================
  # Special form: if-let and when-let (conditional binding)
  # ============================================================

  # Desugar (if-let [x cond] then else) to (let [x cond] (if x then else))
  # The then/else branches are in lexical scope
  defp analyze_if_let([{:vector, [name_ast, cond_ast]}, then_ast, else_ast], scope) do
    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- do_analyze(cond_ast, scope),
         {:ok, t} <- do_analyze(then_ast, :lexical),
         {:ok, e} <- do_analyze(else_ast, :lexical) do
      binding = {:binding, name, c}
      {:ok, {:let, [binding], {:if, name, t, e}}}
    end
  end

  defp analyze_if_let([{:vector, bindings}, _then_ast, _else_ast], _scope)
       when length(bindings) != 2 do
    {:error, {:invalid_form, "if-let requires exactly one binding pair [name expr]"}}
  end

  defp analyze_if_let(_, _scope) do
    {:error, {:invalid_arity, :"if-let", "expected (if-let [name expr] then else)"}}
  end

  # Desugar (when-let [x cond] body) to (let [x cond] (if x body nil))
  # The body is in lexical scope
  defp analyze_when_let([{:vector, [name_ast, cond_ast]}, body_ast], scope) do
    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- do_analyze(cond_ast, scope),
         {:ok, b} <- do_analyze(body_ast, :lexical) do
      binding = {:binding, name, c}
      {:ok, {:let, [binding], {:if, name, b, nil}}}
    end
  end

  defp analyze_when_let([{:vector, bindings}, _body_ast], _scope) when length(bindings) != 2 do
    {:error, {:invalid_form, "when-let requires exactly one binding pair [name expr]"}}
  end

  defp analyze_when_let(_, _scope) do
    {:error, {:invalid_arity, :"when-let", "expected (when-let [name expr] body)"}}
  end

  # Helper: only allow simple symbol bindings (no destructuring)
  defp analyze_simple_binding({:symbol, name}), do: {:ok, {:var, name}}

  defp analyze_simple_binding(_) do
    {:error, {:invalid_form, "binding must be a simple symbol, not a destructuring pattern"}}
  end

  # ============================================================
  # Special form: cond → nested if
  # ============================================================

  defp analyze_cond([], _scope) do
    {:error, {:invalid_cond_form, "cond requires at least one test/result pair"}}
  end

  defp analyze_cond(args, scope) do
    with {:ok, pairs, default} <- split_cond_args(args) do
      build_nested_if(pairs, default, scope)
    end
  end

  defp split_cond_args(args) do
    case Enum.split(args, length(args) - 2) do
      {prefix, [{:keyword, :else}, default_ast]} ->
        validate_pairs(prefix, default_ast)

      _ ->
        validate_pairs(args, nil)
    end
  end

  defp validate_pairs(args, default_ast) do
    if rem(length(args), 2) != 0 do
      {:error, {:invalid_cond_form, "cond requires even number of test/result forms"}}
    else
      pairs = args |> Enum.chunk_every(2) |> Enum.map(fn [c, r] -> {c, r} end)
      {:ok, pairs, default_ast}
    end
  end

  defp build_nested_if(pairs, default_ast, scope) do
    with {:ok, default_core} <- maybe_analyze(default_ast, scope) do
      pairs
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, default_core}, fn {c_ast, r_ast}, {:ok, acc} ->
        with {:ok, c} <- do_analyze(c_ast, scope),
             {:ok, r} <- do_analyze(r_ast, scope) do
          {:cont, {:ok, {:if, c, r, acc}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp maybe_analyze(nil, _scope), do: {:ok, nil}
  defp maybe_analyze(ast, scope), do: do_analyze(ast, scope)

  # ============================================================
  # Special form: fn (anonymous functions)
  # ============================================================

  defp analyze_fn([params_ast, body_ast], _scope) do
    # fn body is always in lexical scope (def/defn not allowed)
    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, body} <- do_analyze(body_ast, :lexical) do
      {:ok, {:fn, params, body}}
    end
  end

  defp analyze_fn(_, _scope) do
    {:error, {:invalid_arity, :fn, "expected (fn [params] body)"}}
  end

  defp analyze_fn_params({:vector, param_asts}) do
    params =
      Enum.reduce_while(param_asts, {:ok, []}, fn ast, {:ok, acc} ->
        case analyze_pattern(ast) do
          {:ok, pattern} -> {:cont, {:ok, [pattern | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case params do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp analyze_fn_params(_) do
    {:error, {:invalid_form, "fn parameters must be a vector"}}
  end

  # ============================================================
  # Sequential evaluation: do
  # ============================================================

  defp analyze_do(args, scope) do
    # do preserves the current scope - def/defn inside (do ...) at top level is allowed
    with {:ok, exprs} <- analyze_list(args, scope) do
      {:ok, {:do, exprs}}
    end
  end

  # ============================================================
  # Short-circuit logic: and/or
  # ============================================================

  defp analyze_and(args, scope) do
    with {:ok, exprs} <- analyze_list(args, scope) do
      {:ok, {:and, exprs}}
    end
  end

  defp analyze_or(args, scope) do
    with {:ok, exprs} <- analyze_list(args, scope) do
      {:ok, {:or, exprs}}
    end
  end

  # ============================================================
  # Threading macros: -> and ->>
  # ============================================================

  defp analyze_thread(kind, [], _scope) do
    {:error, {:invalid_thread_form, kind, "requires at least one expression"}}
  end

  defp analyze_thread(kind, [first | steps], scope) do
    with {:ok, acc} <- do_analyze(first, scope) do
      thread_steps(kind, acc, steps, scope)
    end
  end

  defp thread_steps(_kind, acc, [], _scope), do: {:ok, acc}

  defp thread_steps(kind, acc, [step | rest], scope) do
    with {:ok, acc2} <- apply_thread_step(kind, acc, step, scope) do
      thread_steps(kind, acc2, rest, scope)
    end
  end

  defp apply_thread_step(kind, acc, {:list, [f_ast | arg_asts]}, scope) do
    with {:ok, f} <- do_analyze(f_ast, scope),
         {:ok, args} <- analyze_list(arg_asts, scope) do
      new_args =
        case kind do
          :-> -> [acc | args]
          :"->>" -> args ++ [acc]
        end

      {:ok, {:call, f, new_args}}
    end
  end

  defp apply_thread_step(_kind, acc, step_ast, scope) do
    with {:ok, f} <- do_analyze(step_ast, scope) do
      {:ok, {:call, f, [acc]}}
    end
  end

  # ============================================================
  # Predicates: where and combinators
  # Delegated to PtcRunner.Lisp.Analyze.Predicates
  # ============================================================

  defp analyze_where(args, scope),
    do: Predicates.analyze_where(args, &do_analyze(&1, scope))

  defp analyze_pred_comb(kind, args, scope),
    do: Predicates.analyze_pred_comb(kind, args, &analyze_list(&1, scope))

  # ============================================================
  # Function combinator: juxt
  # ============================================================

  defp analyze_juxt(args, scope) do
    with {:ok, fns} <- analyze_list(args, scope) do
      {:ok, {:juxt, fns}}
    end
  end

  # ============================================================
  # Tool invocation: call
  # ============================================================

  defp analyze_call_tool([{:string, name}], _scope) do
    {:ok, {:call_tool, name, {:map, []}}}
  end

  defp analyze_call_tool([{:string, name}, args_ast], scope) do
    with {:ok, args_core} <- do_analyze(args_ast, scope) do
      case args_core do
        {:map, _} = args_map ->
          {:ok, {:call_tool, name, args_map}}

        other ->
          {:error, {:invalid_form, "call args must be a map, got: #{inspect(other)}"}}
      end
    end
  end

  defp analyze_call_tool([other | _], _scope) do
    {:error,
     {:invalid_call_tool_name, "tool name must be string literal, got: #{inspect(other)}"}}
  end

  defp analyze_call_tool(_, _scope) do
    {:error,
     {:invalid_arity, :call, "expected (call \"tool-name\") or (call \"tool-name\" args)"}}
  end

  # ============================================================
  # Tool invocation via ctx namespace: (ctx/tool-name args...)
  # ============================================================

  defp analyze_ctx_call(tool_name, arg_asts, scope) do
    with {:ok, args} <- analyze_list(arg_asts, scope) do
      {:ok, {:ctx_call, tool_name, args}}
    end
  end

  # ============================================================
  # Syntactic sugar: return and fail (desugar to call_tool)
  # ============================================================

  defp analyze_return([value_ast], scope) do
    with {:ok, value} <- do_analyze(value_ast, scope) do
      {:ok, {:call_tool, "return", value}}
    end
  end

  defp analyze_return(_, _scope) do
    {:error, {:invalid_arity, :return, "expected (return value)"}}
  end

  defp analyze_fail([error_ast], scope) do
    with {:ok, error} <- do_analyze(error_ast, scope) do
      {:ok, {:call_tool, "fail", error}}
    end
  end

  defp analyze_fail(_, _scope) do
    {:error, {:invalid_arity, :fail, "expected (fail error)"}}
  end

  # ============================================================
  # User namespace binding: def
  # Note: def is only reachable at top level, so we analyze values at top level.
  # ============================================================

  # (def name value)
  defp analyze_def([{:symbol, name}, value_ast]) do
    with {:ok, value} <- do_analyze(value_ast, :top_level) do
      {:ok, {:def, name, value}}
    end
  end

  # (def name docstring value) - docstring is ignored but allowed for Clojure compat
  defp analyze_def([{:symbol, name}, {:string, _docstring}, value_ast]) do
    with {:ok, value} <- do_analyze(value_ast, :top_level) do
      {:ok, {:def, name, value}}
    end
  end

  defp analyze_def([{:symbol, _name}]) do
    {:error, {:invalid_arity, :def, "expected (def name value), got (def name) without value"}}
  end

  defp analyze_def([{:symbol, _name} | _]) do
    # First arg is a symbol but wrong number of total args
    {:error, {:invalid_arity, :def, "expected (def name value) or (def name docstring value)"}}
  end

  defp analyze_def([non_symbol | _]) do
    {:error, {:invalid_form, "def name must be a symbol, got: #{inspect(non_symbol)}"}}
  end

  defp analyze_def(_) do
    {:error, {:invalid_arity, :def, "expected (def name value) or (def name docstring value)"}}
  end

  # ============================================================
  # Named function definition: defn (desugars to def + fn)
  # Note: defn is only reachable at top level.
  # The body is analyzed with :lexical scope (it's a function body).
  # ============================================================

  # (defn name docstring [params] body) - docstring variant (4 args, must be checked first)
  defp analyze_defn([{:symbol, name}, {:string, _docstring}, {:vector, _} = params_ast, body_ast]) do
    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, body} <- do_analyze(body_ast, :lexical) do
      {:ok, {:def, name, {:fn, params, body}}}
    end
  end

  # (defn name docstring [params] body1 body2 ...) - docstring + multiple bodies
  defp analyze_defn([
         {:symbol, name},
         {:string, _docstring},
         {:vector, _} = params_ast | body_asts
       ])
       when is_list(body_asts) and length(body_asts) > 1 do
    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, bodies} <- analyze_list(body_asts, :lexical) do
      {:ok, {:def, name, {:fn, params, {:do, bodies}}}}
    end
  end

  # (defn name [params] body) - standard 3 args
  defp analyze_defn([{:symbol, name}, {:vector, _} = params_ast, body_ast]) do
    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, body} <- do_analyze(body_ast, :lexical) do
      # Desugar: (defn name [params] body) → (def name (fn [params] body))
      {:ok, {:def, name, {:fn, params, body}}}
    end
  end

  # (defn name [params] body1 body2 ...) - multiple body expressions → implicit do
  defp analyze_defn([{:symbol, name}, {:vector, _} = params_ast | body_asts])
       when is_list(body_asts) and length(body_asts) > 1 do
    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, bodies} <- analyze_list(body_asts, :lexical) do
      {:ok, {:def, name, {:fn, params, {:do, bodies}}}}
    end
  end

  # Error: (defn name [params]) - missing body
  defp analyze_defn([{:symbol, _name}, {:vector, _params}]) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body), missing body"}}
  end

  # Error: (defn name) - missing params and body
  defp analyze_defn([{:symbol, _name}]) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body)"}}
  end

  # Error: multi-arity syntax (defn f ([x] ...) ([x y] ...))
  defp analyze_defn([{:symbol, _name}, {:list, _} | _]) do
    {:error,
     {:invalid_form, "multi-arity defn not supported, use separate defn forms for each arity"}}
  end

  # Error: non-symbol name
  defp analyze_defn([non_symbol | _]) do
    {:error, {:invalid_form, "defn name must be a symbol, got: #{inspect(non_symbol)}"}}
  end

  defp analyze_defn(_) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body)"}}
  end

  # ============================================================
  # Comparison operators (strict 2-arity)
  # ============================================================

  defp analyze_comparison(op, [left_ast, right_ast], scope) do
    with {:ok, left} <- do_analyze(left_ast, scope),
         {:ok, right} <- do_analyze(right_ast, scope) do
      {:ok, {:call, {:var, op}, [left, right]}}
    end
  end

  defp analyze_comparison(op, args, _scope) do
    {:error,
     {:invalid_arity, op,
      "comparison operators require exactly 2 arguments, got #{length(args)}. " <>
        "Use (and (#{op} a b) (#{op} b c)) for chained comparisons."}}
  end

  # ============================================================
  # Generic function call
  # ============================================================

  defp analyze_call({:list, [f_ast | arg_asts]}, scope) do
    with {:ok, f} <- do_analyze(f_ast, scope),
         {:ok, args} <- analyze_list(arg_asts, scope) do
      {:ok, {:call, f, args}}
    end
  end

  # ============================================================
  # Helper functions
  # ============================================================

  defp analyze_list(xs, scope) do
    xs
    |> Enum.reduce_while({:ok, []}, fn x, {:ok, acc} ->
      case do_analyze(x, scope) do
        {:ok, x2} -> {:cont, {:ok, [x2 | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp analyze_pairs(pairs, scope) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      with {:ok, k2} <- do_analyze(k, scope),
           {:ok, v2} <- do_analyze(v, scope) do
        {:cont, {:ok, [{k2, v2} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  # ============================================================
  # Placeholder detection
  # ============================================================

  # Check if a symbol name is a placeholder (%, %1, %2, etc.)
  @doc false
  def placeholder?(name) do
    case to_string(name) do
      "%" -> true
      "%" <> rest -> String.match?(rest, ~r/^\d+$/)
      _ -> false
    end
  end
end
