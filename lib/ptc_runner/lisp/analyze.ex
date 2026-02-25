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
  alias PtcRunner.Lisp.Env

  @type error_reason ::
          {:invalid_form, String.t()}
          | {:invalid_arity, atom(), String.t()}
          | {:invalid_where_form, String.t()}
          | {:invalid_where_operator, atom()}
          | {:invalid_cond_form, String.t()}
          | {:invalid_thread_form, atom(), String.t()}
          | {:unsupported_pattern, term()}
          | {:invalid_placeholder, atom()}

  @spec analyze(term()) :: {:ok, CoreAST.t()} | {:error, error_reason()}
  def analyze(raw_ast) do
    do_analyze(raw_ast, false)
  end

  # ============================================================
  # Multiple top-level expressions (implicit do)
  # ============================================================

  defp do_analyze({:program, exprs}, _tail?) when is_list(exprs) do
    with {:ok, analyzed} <- analyze_list(exprs) do
      {:ok, {:do, analyzed}}
    end
  end

  # ============================================================
  # Literals and basic values
  # ============================================================

  defp do_analyze(nil, _tail?), do: {:ok, nil}
  defp do_analyze(true, _tail?), do: {:ok, true}
  defp do_analyze(false, _tail?), do: {:ok, false}
  defp do_analyze(n, _tail?) when is_integer(n) or is_float(n), do: {:ok, n}
  defp do_analyze(a, _tail?) when a in [:infinity, :negative_infinity, :nan], do: {:ok, a}

  defp do_analyze({:string, s}, _tail?), do: {:ok, {:string, s}}
  defp do_analyze({:keyword, k}, _tail?), do: {:ok, {:keyword, k}}

  # ============================================================
  # Collections
  # ============================================================

  defp do_analyze({:vector, elems}, _tail?) do
    with {:ok, elems2} <- analyze_list(elems) do
      {:ok, {:vector, elems2}}
    end
  end

  defp do_analyze({:map, pairs}, _tail?) do
    with {:ok, pairs2} <- analyze_pairs(pairs) do
      {:ok, {:map, pairs2}}
    end
  end

  defp do_analyze({:set, elems}, _tail?) do
    with {:ok, elems2} <- analyze_list(elems) do
      {:ok, {:set, elems2}}
    end
  end

  # ============================================================
  # Short function syntax: #()
  # ============================================================

  defp do_analyze({:short_fn, body_asts}, tail?) do
    with {:ok, desugared_ast} <- ShortFn.desugar(body_asts) do
      do_analyze(desugared_ast, tail?)
    end
  end

  # ============================================================
  # Regex literal: #"..." desugars to (re-pattern "...")
  # ============================================================

  defp do_analyze({:regex_literal, pattern}, _tail?) do
    case :re.compile(pattern) do
      {:ok, _} ->
        {:ok, {:call, {:var, :"re-pattern"}, [{:string, pattern}]}}

      {:error, {reason, position}} ->
        {:error,
         {:invalid_form,
          "invalid regex literal #\"#{pattern}\": #{reason} at position #{position}"}}
    end
  end

  # ============================================================
  # Symbols and variables
  # ============================================================

  defp do_analyze({:symbol, name}, _tail?) do
    if placeholder?(name) do
      {:error, {:invalid_placeholder, name}}
    else
      {:ok, {:var, name}}
    end
  end

  # Var reader syntax: #'name produces {:var, name} from the parser
  defp do_analyze({:var, name}, _tail?) when is_atom(name), do: {:ok, {:var, name}}

  defp do_analyze({:ns_symbol, :data, key}, _tail?), do: {:ok, {:data, key}}

  # Budget introspection: (budget/remaining) returns budget info map
  defp do_analyze({:ns_symbol, :budget, :remaining}, _tail?), do: {:ok, {:budget_remaining}}

  # Invalid budget namespace functions
  defp do_analyze({:ns_symbol, :budget, other}, _tail?) do
    {:error,
     {:invalid_form, "Unknown budget function: budget/#{other}. Available: budget/remaining"}}
  end

  # Clojure-style namespaces: normalize to built-in or provide helpful error
  defp do_analyze({:ns_symbol, ns, key}, _tail?) do
    normalize_clojure_namespace(ns, key, fn -> {:ok, {:var, key}} end)
  end

  # Turn history variables: *1, *2, *3
  defp do_analyze({:turn_history, n}, _tail?) when n in [1, 2, 3], do: {:ok, {:turn_history, n}}

  # ============================================================
  # List forms (special forms and function calls)
  # ============================================================

  defp do_analyze({:list, [head | rest]} = list, tail?) do
    dispatch_list_form(head, rest, list, tail?)
  end

  defp do_analyze({:list, []}, _tail?) do
    {:error, {:invalid_form, "Empty list is not a valid expression"}}
  end

  # Dispatch special forms based on the head symbol
  defp dispatch_list_form({:symbol, :let}, rest, _list, tail?), do: analyze_let(rest, tail?)
  defp dispatch_list_form({:symbol, :loop}, rest, _list, tail?), do: analyze_loop(rest, tail?)
  defp dispatch_list_form({:symbol, :recur}, rest, _list, tail?), do: analyze_recur(rest, tail?)
  defp dispatch_list_form({:symbol, :doseq}, rest, _list, tail?), do: analyze_doseq(rest, tail?)
  defp dispatch_list_form({:symbol, :for}, rest, _list, tail?), do: analyze_for(rest, tail?)
  defp dispatch_list_form({:symbol, :fn}, rest, _list, _tail?), do: analyze_fn(rest)

  # Conditionals: if variants
  defp dispatch_list_form({:symbol, :if}, rest, _list, tail?), do: analyze_if(rest, tail?)

  defp dispatch_list_form({:symbol, :"if-not"}, rest, _list, tail?),
    do: analyze_if_not(rest, tail?)

  # Conditionals: when variants
  defp dispatch_list_form({:symbol, :when}, rest, _list, tail?), do: analyze_when(rest, tail?)

  defp dispatch_list_form({:symbol, :"when-not"}, rest, _list, tail?),
    do: analyze_when_not(rest, tail?)

  # Conditionals: binding variants
  defp dispatch_list_form({:symbol, :"if-let"}, rest, _list, tail?),
    do: analyze_if_let(rest, tail?)

  defp dispatch_list_form({:symbol, :"when-let"}, rest, _list, tail?),
    do: analyze_when_let(rest, tail?)

  # Conditionals: multi-way
  defp dispatch_list_form({:symbol, :cond}, rest, _list, tail?), do: analyze_cond(rest, tail?)

  defp dispatch_list_form({:symbol, :->}, rest, _list, tail?),
    do: analyze_thread(:->, rest, tail?)

  defp dispatch_list_form({:symbol, :"->>"}, rest, _list, tail?),
    do: analyze_thread(:"->>", rest, tail?)

  defp dispatch_list_form({:symbol, :do}, rest, _list, tail?), do: analyze_do(rest, tail?)
  defp dispatch_list_form({:symbol, :and}, rest, _list, tail?), do: analyze_and(rest, tail?)
  defp dispatch_list_form({:symbol, :or}, rest, _list, tail?), do: analyze_or(rest, tail?)
  defp dispatch_list_form({:symbol, :where}, rest, _list, tail?), do: analyze_where(rest, tail?)

  defp dispatch_list_form({:symbol, :"all-of"}, rest, _list, tail?),
    do: analyze_pred_comb(:all_of, rest, tail?)

  defp dispatch_list_form({:symbol, :"any-of"}, rest, _list, tail?),
    do: analyze_pred_comb(:any_of, rest, tail?)

  defp dispatch_list_form({:symbol, :"none-of"}, rest, _list, tail?),
    do: analyze_pred_comb(:none_of, rest, tail?)

  defp dispatch_list_form({:symbol, :juxt}, rest, _list, tail?), do: analyze_juxt(rest, tail?)
  defp dispatch_list_form({:symbol, :pmap}, rest, _list, tail?), do: analyze_pmap(rest, tail?)
  defp dispatch_list_form({:symbol, :pcalls}, rest, _list, tail?), do: analyze_pcalls(rest, tail?)
  defp dispatch_list_form({:symbol, :apply}, rest, _list, tail?), do: analyze_apply(rest, tail?)

  defp dispatch_list_form({:symbol, :.}, _rest, _list, _tail?) do
    {:error,
     {:invalid_form, "(. obj method) syntax is not supported. Use (.method obj) instead."}}
  end

  defp dispatch_list_form({:symbol, :return}, rest, _list, tail?), do: analyze_return(rest, tail?)
  defp dispatch_list_form({:symbol, :fail}, rest, _list, tail?), do: analyze_fail(rest, tail?)
  defp dispatch_list_form({:symbol, :task}, rest, _list, tail?), do: analyze_task(rest, tail?)

  defp dispatch_list_form({:symbol, :"step-done"}, rest, _list, tail?),
    do: analyze_step_done(rest, tail?)

  defp dispatch_list_form({:symbol, :"task-reset"}, rest, _list, tail?),
    do: analyze_task_reset(rest, tail?)

  defp dispatch_list_form({:symbol, :def}, rest, _list, tail?), do: analyze_def(rest, tail?)

  defp dispatch_list_form({:symbol, :defonce}, rest, _list, tail?),
    do: analyze_defonce(rest, tail?)

  defp dispatch_list_form({:symbol, :defn}, rest, _list, tail?), do: analyze_defn(rest, tail?)

  # Tool invocation via tool/ namespace: (tool/name args...)
  defp dispatch_list_form({:ns_symbol, :tool, tool_name}, rest, _list, tail?),
    do: analyze_tool_call(tool_name, rest, tail?)

  # Budget introspection via budget/ namespace: (budget/remaining)
  defp dispatch_list_form({:ns_symbol, :budget, :remaining}, [], _list, _tail?),
    do: {:ok, {:budget_remaining}}

  defp dispatch_list_form({:ns_symbol, :budget, :remaining}, _args, _list, _tail?),
    do: {:error, {:invalid_arity, :"budget/remaining", "(budget/remaining) takes no arguments"}}

  defp dispatch_list_form({:ns_symbol, :budget, other}, _rest, _list, _tail?),
    do:
      {:error,
       {:invalid_form, "Unknown budget function: budget/#{other}. Available: budget/remaining"}}

  # Clojure-style namespaces in call position: (clojure.string/join "," items)
  defp dispatch_list_form({:ns_symbol, ns, func}, rest, list, tail?) do
    normalize_clojure_namespace(ns, func, fn ->
      dispatch_list_form({:symbol, func}, rest, list, tail?)
    end)
  end

  # Comparison operators (strict 2-arity per spec section 8.4)
  defp dispatch_list_form({:symbol, op}, rest, _list, tail?)
       when op in [:=, :"not=", :>, :<, :>=, :<=],
       do: analyze_comparison(op, rest, tail?)

  # Generic function call
  defp dispatch_list_form(_head, _rest, list, tail?), do: analyze_call(list, tail?)

  # ============================================================
  # Special form: let
  # ============================================================

  defp analyze_let([bindings_ast, first_body | rest_body], tail?) do
    body_asts = [first_body | rest_body]

    with {:ok, bindings} <- analyze_bindings(bindings_ast),
         {:ok, body} <- wrap_body(body_asts, tail?) do
      {:ok, {:let, bindings, body}}
    end
  end

  defp analyze_let(_, _tail?) do
    {:error, {:invalid_arity, :let, "expected (let [bindings] body ...)"}}
  end

  defp analyze_bindings({:vector, elems}) do
    if rem(length(elems), 2) != 0 do
      {:error, {:invalid_form, "let bindings require even number of forms"}}
    else
      elems
      |> Enum.chunk_every(2)
      |> Enum.reduce_while({:ok, []}, fn [pattern_ast, value_ast], {:ok, acc} ->
        with {:ok, pattern} <- analyze_pattern(pattern_ast),
             {:ok, value} <- do_analyze(value_ast, false) do
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

  defp analyze_bindings(_) do
    {:error, {:invalid_form, "let bindings must be a vector"}}
  end

  # ============================================================
  # Special form: loop
  # ============================================================

  defp analyze_loop([bindings_ast, first_body | rest_body], _tail?) do
    body_asts = [first_body | rest_body]

    with {:ok, bindings} <- analyze_bindings(bindings_ast),
         {:ok, body} <- wrap_body(body_asts, true) do
      {:ok, {:loop, bindings, body}}
    end
  end

  defp analyze_loop(_, _tail?) do
    {:error, {:invalid_arity, :loop, "expected (loop [bindings] body ...)"}}
  end

  # ============================================================
  # Special form: recur
  # ============================================================

  defp analyze_recur(args, true) do
    with {:ok, analyzed_args} <- analyze_list(args) do
      {:ok, {:recur, analyzed_args}}
    end
  end

  defp analyze_recur(_args, false) do
    {:error, {:invalid_form, "recur must be in tail position"}}
  end

  # ============================================================
  # Special form: doseq
  # ============================================================

  defp analyze_doseq([{:vector, bindings}, first_body | rest_body], _tail?) do
    body_asts = [first_body | rest_body]

    case parse_binding_segments(bindings) do
      {:ok, segments} ->
        do_build_doseq(segments, body_asts)

      {:error, _} = err ->
        err
    end
  end

  defp analyze_doseq([{:vector, _bindings}], _tail?) do
    {:error,
     {:invalid_arity, :doseq, "doseq requires at least one body expression, missing body"}}
  end

  defp analyze_doseq(_, _tail?) do
    {:error, {:invalid_arity, :doseq, "expected (doseq [bindings] body ...)"}}
  end

  # Parse binding vector into segments: [{binding, collection, modifiers}, ...]
  # Modifiers are :when/:let/:while keywords that follow a binding pair.
  defp parse_binding_segments(bindings) do
    parse_binding_segments(bindings, [])
  end

  defp parse_binding_segments([], acc) do
    case acc do
      [] -> {:error, {:invalid_form, "for/doseq requires at least one binding pair"}}
      _ -> {:ok, Enum.reverse(acc)}
    end
  end

  # Keyword in binding position → error
  defp parse_binding_segments([{:keyword, k} | _], _acc) do
    {:error,
     {:invalid_form,
      "expected a binding symbol, got keyword :#{k}. Keywords like :when/:let/:while must follow a binding pair"}}
  end

  defp parse_binding_segments([binding, coll | rest], acc) do
    case parse_modifiers(rest, []) do
      {:ok, modifiers, remaining} ->
        segment = %{binding: binding, collection: coll, modifiers: modifiers}
        parse_binding_segments(remaining, [segment | acc])

      {:error, _} = err ->
        err
    end
  end

  defp parse_binding_segments([_single], _acc) do
    {:error, {:invalid_form, "for/doseq bindings require pairs, got trailing element"}}
  end

  @known_modifiers [:when, :let, :while]

  defp parse_modifiers([{:keyword, k} | rest], acc) when k in @known_modifiers do
    case {k, rest} do
      {_, []} ->
        {:error, {:invalid_form, "modifier :#{k} requires a value"}}

      {:let, [{:vector, _} = vec | remaining]} ->
        parse_modifiers(remaining, [{:let, vec} | acc])

      {:let, [other | _]} ->
        {:error,
         {:invalid_form,
          ":let modifier requires a vector of bindings, got: #{inspect_ast(other)}"}}

      {mod, [expr | remaining]} ->
        parse_modifiers(remaining, [{mod, expr} | acc])
    end
  end

  defp parse_modifiers([{:keyword, k} | _], _acc) do
    {:error, {:invalid_form, "unknown modifier :#{k} in for/doseq. Known: :when, :let, :while"}}
  end

  defp parse_modifiers(rest, acc) do
    {:ok, Enum.reverse(acc), rest}
  end

  defp inspect_ast({:vector, _}), do: "vector"
  defp inspect_ast({:symbol, s}), do: "symbol '#{s}'"
  defp inspect_ast({:keyword, k}), do: ":#{k}"
  defp inspect_ast(n) when is_number(n), do: "#{n}"
  defp inspect_ast({:string, s}), do: inspect(s)
  defp inspect_ast(other), do: inspect(other)

  # Reconstruct flat binding tokens from a segment (for recursive inner for/doseq calls)
  defp segment_to_bindings(%{binding: b, collection: c, modifiers: mods}) do
    [b, c | Enum.flat_map(mods, &modifier_to_tokens/1)]
  end

  defp modifier_to_tokens({:let, vec}), do: [{:keyword, :let}, vec]
  defp modifier_to_tokens({mod, expr}), do: [{:keyword, mod}, expr]

  # Wrap an inner expression with modifiers applied in reverse declaration order.
  # This ensures earlier modifiers wrap later ones (correct nesting).
  defp wrap_with_modifiers(modifiers, inner, skip_expr, stop_expr) do
    modifiers
    |> Enum.reverse()
    |> Enum.reduce(inner, fn
      {:when, pred}, acc ->
        {:list, [{:symbol, :if}, pred, acc, skip_expr]}

      {:while, pred}, acc ->
        {:list, [{:symbol, :if}, pred, acc, stop_expr]}

      {:let, {:vector, _} = bindings_vec}, acc ->
        {:list, [{:symbol, :let}, bindings_vec, acc]}
    end)
  end

  defp do_build_doseq([segment | rest_segments], body_asts) do
    %{binding: binding_ast, collection: coll_ast, modifiers: modifiers} = segment

    case check_iterator_collection(:doseq, binding_ast, coll_ast) do
      {:error, _} = err ->
        err

      {:ok, _} ->
        inner_form =
          if rest_segments == [] do
            {:program, body_asts}
          else
            inner_bindings = Enum.flat_map(rest_segments, &segment_to_bindings/1)
            {:list, [{:symbol, :doseq}, {:vector, inner_bindings} | body_asts]}
          end

        temp_sym = {:symbol, :"$doseq_temp"}

        # Skip expression for :when — just advance iterator
        skip_expr = {:list, [{:symbol, :recur}, {:list, [{:symbol, :next}, temp_sym]}]}

        # Stop expression for :while — return nil immediately
        stop_expr = nil

        # Start with innermost: do { body; recur next }
        recur_expr = {:list, [{:symbol, :recur}, {:list, [{:symbol, :next}, temp_sym]}]}

        innermost =
          {:list,
           [
             {:symbol, :do},
             inner_form,
             recur_expr
           ]}

        # Wrap with modifiers in reverse order
        wrapped = wrap_with_modifiers(modifiers, innermost, skip_expr, stop_expr)

        desugared =
          {:list,
           [
             {:symbol, :loop},
             {:vector, [temp_sym, {:list, [{:symbol, :seq}, coll_ast]}]},
             {:list,
              [
                {:symbol, :if},
                temp_sym,
                {:list,
                 [
                   {:symbol, :let},
                   {:vector, [binding_ast, {:list, [{:symbol, :first}, temp_sym]}]},
                   wrapped
                 ]},
                nil
              ]}
           ]}

        do_analyze(desugared, true)
    end
  end

  defp check_iterator_collection(op, binding_ast, coll_ast) do
    case coll_ast do
      n when is_number(n) ->
        name = binding_name_prefix(binding_ast)

        {:error,
         {:invalid_arity, op, "#{op} binding #{name}expected a collection, got: #{n} (number)"}}

      {:keyword, k} ->
        name = binding_name_prefix(binding_ast)

        {:error,
         {:invalid_arity, op, "#{op} binding #{name}expected a collection, got: :#{k} (keyword)"}}

      _ ->
        {:ok, coll_ast}
    end
  end

  defp binding_name_prefix({:symbol, sym}), do: "'#{sym}' "
  defp binding_name_prefix(_), do: ""

  # ============================================================
  # Special form: for (list comprehension)
  # ============================================================

  defp analyze_for([{:vector, bindings}, first_body | rest_body], _tail?) do
    body_asts = [first_body | rest_body]

    case parse_binding_segments(bindings) do
      {:ok, segments} ->
        do_build_for(segments, body_asts)

      {:error, _} = err ->
        err
    end
  end

  defp analyze_for([{:vector, _bindings}], _tail?) do
    {:error, {:invalid_arity, :for, "for requires at least one body expression"}}
  end

  defp analyze_for(_, _tail?) do
    {:error, {:invalid_arity, :for, "expected (for [bindings] body ...)"}}
  end

  defp do_build_for([segment | rest_segments], body_asts) do
    %{binding: binding_ast, collection: coll_ast, modifiers: modifiers} = segment

    case check_iterator_collection(:for, binding_ast, coll_ast) do
      {:error, _} = err ->
        err

      {:ok, _} ->
        inner_form =
          if rest_segments == [] do
            # Last segment: body result gets conj'd into accumulator
            {:program, body_asts}
          else
            # More segments: recursive inner (for ...) call
            inner_bindings = Enum.flat_map(rest_segments, &segment_to_bindings/1)
            {:list, [{:symbol, :for}, {:vector, inner_bindings} | body_asts]}
          end

        seq_sym = {:symbol, :"$for_seq"}
        acc_sym = {:symbol, :"$for_acc"}

        body_expr =
          if rest_segments == [] do
            # (conj $for_acc body)
            {:list, [{:symbol, :conj}, acc_sym, inner_form]}
          else
            # (into $for_acc (for [...] body))
            {:list, [{:symbol, :into}, acc_sym, inner_form]}
          end

        # Skip expression for :when — advance iterator, keep acc
        skip_expr =
          {:list, [{:symbol, :recur}, {:list, [{:symbol, :next}, seq_sym]}, acc_sym]}

        # Stop expression for :while — return accumulated results
        stop_expr = acc_sym

        # Innermost: (recur (next $for_seq) body_expr)
        innermost =
          {:list,
           [
             {:symbol, :recur},
             {:list, [{:symbol, :next}, seq_sym]},
             body_expr
           ]}

        # Wrap with modifiers in reverse order
        wrapped = wrap_with_modifiers(modifiers, innermost, skip_expr, stop_expr)

        desugared =
          {:list,
           [
             {:symbol, :loop},
             {:vector, [seq_sym, {:list, [{:symbol, :seq}, coll_ast]}, acc_sym, {:vector, []}]},
             {:list,
              [
                {:symbol, :if},
                seq_sym,
                {:list,
                 [
                   {:symbol, :let},
                   {:vector, [binding_ast, {:list, [{:symbol, :first}, seq_sym]}]},
                   wrapped
                 ]},
                acc_sym
              ]}
           ]}

        do_analyze(desugared, true)
    end
  end

  # ============================================================
  # Pattern analysis (destructuring)
  # Delegated to PtcRunner.Lisp.Analyze.Patterns
  # ============================================================

  defp analyze_pattern(ast), do: Patterns.analyze_pattern(ast)

  # ============================================================
  # Special form: if and when
  # ============================================================

  defp analyze_if([cond_ast, then_ast, else_ast], tail?) do
    with {:ok, c} <- do_analyze(cond_ast, false),
         {:ok, t} <- do_analyze(then_ast, tail?),
         {:ok, e} <- do_analyze(else_ast, tail?) do
      {:ok, {:if, c, t, e}}
    end
  end

  defp analyze_if([cond_ast, then_ast], tail?) do
    with {:ok, c} <- do_analyze(cond_ast, false),
         {:ok, t} <- do_analyze(then_ast, tail?) do
      {:ok, {:if, c, t, nil}}
    end
  end

  defp analyze_if(_, _tail?) do
    {:error, {:invalid_arity, :if, "expected (if cond then else?)"}}
  end

  # ============================================================
  # Special form: if-not
  # ============================================================

  # Desugar (if-not test then else) -> (if test else then)
  defp analyze_if_not([cond_ast, then_ast, else_ast], tail?) do
    with {:ok, c} <- do_analyze(cond_ast, false),
         {:ok, t} <- do_analyze(then_ast, tail?),
         {:ok, e} <- do_analyze(else_ast, tail?) do
      {:ok, {:if, c, e, t}}
    end
  end

  # Desugar (if-not test then) -> (if test nil then)
  defp analyze_if_not([cond_ast, then_ast], tail?) do
    with {:ok, c} <- do_analyze(cond_ast, false),
         {:ok, t} <- do_analyze(then_ast, tail?) do
      {:ok, {:if, c, nil, t}}
    end
  end

  defp analyze_if_not(_, _tail?) do
    {:error, {:invalid_arity, :"if-not", "expected (if-not cond then else?)"}}
  end

  defp analyze_when([cond_ast, first_body | rest_body], tail?) do
    body_asts = [first_body | rest_body]

    with {:ok, c} <- do_analyze(cond_ast, false),
         {:ok, b} <- wrap_body(body_asts, tail?) do
      {:ok, {:if, c, b, nil}}
    end
  end

  defp analyze_when(_, _tail?) do
    {:error, {:invalid_arity, :when, "expected (when cond body ...)"}}
  end

  # ============================================================
  # Special form: if-let and when-let (conditional binding)
  # ============================================================

  # Desugar (if-let [x cond] then else) to (let [x cond] (if x then else))
  defp analyze_if_let([{:vector, [name_ast, cond_ast]}, then_ast, else_ast], tail?) do
    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- do_analyze(cond_ast, false),
         {:ok, t} <- do_analyze(then_ast, tail?),
         {:ok, e} <- do_analyze(else_ast, tail?) do
      binding = {:binding, name, c}
      {:ok, {:let, [binding], {:if, name, t, e}}}
    end
  end

  defp analyze_if_let([{:vector, bindings}, _then_ast, _else_ast], _tail?)
       when length(bindings) != 2 do
    {:error, {:invalid_form, "if-let requires exactly one binding pair [name expr]"}}
  end

  defp analyze_if_let(_, _tail?) do
    {:error, {:invalid_arity, :"if-let", "expected (if-let [name expr] then else)"}}
  end

  # Desugar (when-let [x cond] body ...) to (let [x cond] (if x body nil))
  defp analyze_when_let([{:vector, [name_ast, cond_ast]}, first_body | rest_body], tail?) do
    body_asts = [first_body | rest_body]

    with {:ok, {:var, _} = name} <- analyze_simple_binding(name_ast),
         {:ok, c} <- do_analyze(cond_ast, false),
         {:ok, b} <- wrap_body(body_asts, tail?) do
      binding = {:binding, name, c}
      {:ok, {:let, [binding], {:if, name, b, nil}}}
    end
  end

  defp analyze_when_let([{:vector, bindings} | _body_asts], _tail?) when length(bindings) != 2 do
    {:error, {:invalid_form, "when-let requires exactly one binding pair [name expr]"}}
  end

  defp analyze_when_let(_, _tail?) do
    {:error, {:invalid_arity, :"when-let", "expected (when-let [name expr] body ...)"}}
  end

  # ============================================================
  # Special form: when-not
  # ============================================================

  # Desugar (when-not cond body ...) -> (if cond nil (do body ...))
  defp analyze_when_not([cond_ast, first_body | rest_body], tail?) do
    body_asts = [first_body | rest_body]

    with {:ok, c} <- do_analyze(cond_ast, false),
         {:ok, b} <- wrap_body(body_asts, tail?) do
      {:ok, {:if, c, nil, b}}
    end
  end

  defp analyze_when_not(_, _tail?) do
    {:error, {:invalid_arity, :"when-not", "expected (when-not cond body ...)"}}
  end

  # Helper: only allow simple symbol bindings (no destructuring)
  defp analyze_simple_binding({:symbol, name}), do: {:ok, {:var, name}}

  defp analyze_simple_binding(_) do
    {:error, {:invalid_form, "binding must be a simple symbol, not a destructuring pattern"}}
  end

  # ============================================================
  # Special form: cond → nested if
  # ============================================================

  defp analyze_cond([], _tail?) do
    {:error, {:invalid_cond_form, "cond requires at least one test/result pair"}}
  end

  defp analyze_cond(args, tail?) do
    with {:ok, pairs, default} <- split_cond_args(args) do
      build_nested_if(pairs, default, tail?)
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

  defp build_nested_if(pairs, default_ast, tail?) do
    with {:ok, default_core} <- maybe_analyze(default_ast, tail?) do
      pairs
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, default_core}, fn {c_ast, r_ast}, {:ok, acc} ->
        with {:ok, c} <- do_analyze(c_ast, false),
             {:ok, r} <- do_analyze(r_ast, tail?) do
          {:cont, {:ok, {:if, c, r, acc}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp maybe_analyze(nil, _tail?), do: {:ok, nil}
  defp maybe_analyze(ast, tail?), do: do_analyze(ast, tail?)

  # ============================================================
  # Special form: fn (anonymous functions)
  # ============================================================

  defp analyze_fn([params_ast, first_body | rest_body]) do
    body_asts = [first_body | rest_body]

    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, body} <- wrap_body(body_asts, true) do
      {:ok, {:fn, params, body}}
    end
  end

  defp analyze_fn(_) do
    {:error, {:invalid_arity, :fn, "expected (fn [params] body ...)"}}
  end

  defp analyze_fn_params({:vector, param_asts}) do
    case Patterns.split_at_ampersand(param_asts) do
      {:rest, leading, rest_ast} ->
        with {:ok, leading_patterns} <- analyze_list_of_patterns(leading),
             {:ok, rest_pattern} <- analyze_pattern(rest_ast) do
          {:ok, {:variadic, leading_patterns, rest_pattern}}
        end

      :no_rest ->
        analyze_list_of_patterns(param_asts)

      {:error, _} = err ->
        err
    end
  end

  defp analyze_fn_params(_) do
    {:error, {:invalid_form, "fn parameters must be a vector"}}
  end

  defp analyze_list_of_patterns(patterns) do
    patterns
    |> Enum.reduce_while({:ok, []}, fn ast, {:ok, acc} ->
      case analyze_pattern(ast) do
        {:ok, pattern} -> {:cont, {:ok, [pattern | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  # ============================================================
  # Sequential evaluation: do
  # ============================================================

  defp analyze_do(args, tail?) do
    case args do
      [] ->
        {:ok, nil}

      _ ->
        with {:ok, exprs} <- analyze_list_with_tail(args, tail?) do
          {:ok, {:do, exprs}}
        end
    end
  end

  # ============================================================
  # Short-circuit logic: and/or
  # ============================================================

  defp analyze_and(args, tail?) do
    case args do
      [] ->
        {:ok, true}

      _ ->
        with {:ok, exprs} <- analyze_list_with_tail(args, tail?) do
          {:ok, {:and, exprs}}
        end
    end
  end

  defp analyze_or(args, tail?) do
    case args do
      [] ->
        {:ok, nil}

      _ ->
        with {:ok, exprs} <- analyze_list_with_tail(args, tail?) do
          {:ok, {:or, exprs}}
        end
    end
  end

  # ============================================================
  # Threading macros: -> and ->>
  # ============================================================

  defp analyze_thread(kind, [], _tail?) do
    {:error, {:invalid_thread_form, kind, "requires at least one expression"}}
  end

  defp analyze_thread(kind, [first | steps], tail?) do
    with {:ok, acc} <- do_analyze(first, false) do
      thread_steps(kind, acc, steps, tail?)
    end
  end

  defp thread_steps(_kind, acc, [], _tail?), do: {:ok, acc}

  defp thread_steps(kind, acc, [step | rest], tail?) do
    # Only the very last step in a thread can be in a tail position
    is_last? = rest == []
    step_tail? = is_last? and tail?

    with {:ok, acc2} <- apply_thread_step(kind, acc, step, step_tail?) do
      thread_steps(kind, acc2, rest, tail?)
    end
  end

  defp apply_thread_step(kind, acc, {:list, [f_ast | arg_asts]}, tail?) do
    # Handle special forms (return, fail) that need the threaded value
    case f_ast do
      {:symbol, :return} when arg_asts == [] ->
        {:ok, {:return, acc}}

      {:symbol, :fail} when arg_asts == [] ->
        {:ok, {:fail, acc}}

      _ ->
        with {:ok, f} <- do_analyze(f_ast, false),
             {:ok, args} <- analyze_list(arg_asts) do
          new_args =
            case kind do
              :-> -> [acc | args]
              :"->>" -> args ++ [acc]
            end

          resolve_call_or_recur(f, new_args, tail?)
        end
    end
  end

  defp apply_thread_step(_kind, acc, step_ast, tail?) do
    with {:ok, f} <- do_analyze(step_ast, false) do
      resolve_call_or_recur(f, [acc], tail?)
    end
  end

  defp resolve_call_or_recur({:var, :recur}, args, true), do: {:ok, {:recur, args}}

  defp resolve_call_or_recur({:var, :recur}, _args, false),
    do: {:error, {:invalid_form, "recur must be in tail position"}}

  defp resolve_call_or_recur(f, args, _tail?), do: {:ok, {:call, f, args}}

  # ============================================================
  # Predicates: where and combinators
  # Delegated to PtcRunner.Lisp.Analyze.Predicates
  # ============================================================

  defp analyze_where(args, _tail?),
    do: Predicates.analyze_where(args, fn ast -> do_analyze(ast, false) end)

  defp analyze_pred_comb(kind, args, _tail?),
    do: Predicates.analyze_pred_comb(kind, args, &analyze_list/1)

  # ============================================================
  # Function combinator: juxt
  # ============================================================

  defp analyze_juxt(args, _tail?) do
    with {:ok, fns} <- analyze_list(args) do
      {:ok, {:juxt, fns}}
    end
  end

  # ============================================================
  # Parallel map: pmap
  # ============================================================

  # (pmap f coll) - parallel map, evaluates f for each element concurrently
  defp analyze_pmap([fn_ast, coll_ast], _tail?) do
    with {:ok, fn_core} <- do_analyze(fn_ast, false),
         {:ok, coll_core} <- do_analyze(coll_ast, false) do
      {:ok, {:pmap, fn_core, coll_core}}
    end
  end

  defp analyze_pmap(_, _tail?) do
    {:error, {:invalid_arity, :pmap, "expected (pmap f coll)"}}
  end

  # ============================================================
  # Parallel calls: pcalls
  # ============================================================

  # (pcalls f1 f2 ... fN) - parallel calls, executes N thunks concurrently
  defp analyze_pcalls(fn_asts, _tail?) do
    with {:ok, fn_cores} <- analyze_list(fn_asts) do
      {:ok, {:pcalls, fn_cores}}
    end
  end

  # ============================================================
  # Functional: apply
  # ============================================================

  defp analyze_apply(args, _tail?) do
    if length(args) < 2 do
      {:error, {:invalid_arity, :apply, "expected (apply f coll) or (apply f x y coll)"}}
    else
      with {:ok, analyzed} <- analyze_list(args) do
        {:ok, {:call, {:var, :apply}, analyzed}}
      end
    end
  end

  # ============================================================
  # Tool invocation via tool/ namespace: (tool/name args...)
  # ============================================================

  defp analyze_tool_call(tool_name, arg_asts, _tail?) do
    with {:ok, args} <- analyze_list(arg_asts) do
      {:ok, {:tool_call, tool_name, args}}
    end
  end

  # ============================================================
  # Control flow signals: return and fail
  # ============================================================

  defp analyze_return([value_ast], _tail?) do
    with {:ok, value} <- do_analyze(value_ast, false) do
      {:ok, {:return, value}}
    end
  end

  defp analyze_return(_, _tail?) do
    {:error, {:invalid_arity, :return, "expected (return value)"}}
  end

  defp analyze_fail([error_ast], _tail?) do
    with {:ok, error} <- do_analyze(error_ast, false) do
      {:ok, {:fail, error}}
    end
  end

  defp analyze_fail(_, _tail?) do
    {:error, {:invalid_arity, :fail, "expected (fail error)"}}
  end

  # ============================================================
  # Journaled task: (task "id" expr) or (task id-expr expr)
  # ============================================================

  defp analyze_task([{:string, id}, body_ast], _tail?) do
    with {:ok, body} <- do_analyze(body_ast, false) do
      {:ok, {:task, id, body}}
    end
  end

  defp analyze_task([id_ast, body_ast], _tail?) do
    with {:ok, id_expr} <- do_analyze(id_ast, false),
         {:ok, body} <- do_analyze(body_ast, false) do
      {:ok, {:task_dynamic, id_expr, body}}
    end
  end

  defp analyze_task(_, _tail?) do
    {:error, {:invalid_arity, :task, "expected (task \"id\" expr)"}}
  end

  # ============================================================
  # Step done: (step-done "id" "summary")
  # ============================================================

  defp analyze_step_done([id_ast, summary_ast], _tail?) do
    with {:ok, id} <- do_analyze(id_ast, false),
         {:ok, summary} <- do_analyze(summary_ast, false) do
      {:ok, {:step_done, id, summary}}
    end
  end

  defp analyze_step_done(_, _tail?) do
    {:error, {:invalid_arity, :"step-done", "expected (step-done id summary)"}}
  end

  # ============================================================
  # Task reset: (task-reset "id")
  # ============================================================

  defp analyze_task_reset([id_ast], _tail?) do
    with {:ok, id} <- do_analyze(id_ast, false) do
      {:ok, {:task_reset, id}}
    end
  end

  defp analyze_task_reset(_, _tail?) do
    {:error, {:invalid_arity, :"task-reset", "expected (task-reset id)"}}
  end

  # ============================================================
  # User namespace binding: def
  # ============================================================

  # (def name value)
  defp analyze_def([{:symbol, name}, value_ast], _tail?) do
    with {:ok, value} <- do_analyze(value_ast, false) do
      {:ok, {:def, name, value, %{}}}
    end
  end

  # (def name docstring value) - docstring preserved for user/ namespace display
  defp analyze_def([{:symbol, name}, {:string, docstring}, value_ast], _tail?) do
    with {:ok, value} <- do_analyze(value_ast, false) do
      {:ok, {:def, name, value, %{docstring: docstring}}}
    end
  end

  defp analyze_def([{:symbol, _name}], _tail?) do
    {:error, {:invalid_arity, :def, "expected (def name value), got (def name) without value"}}
  end

  defp analyze_def([{:symbol, _name} | _], _tail?) do
    # First arg is a symbol but wrong number of total args
    {:error, {:invalid_arity, :def, "expected (def name value) or (def name docstring value)"}}
  end

  defp analyze_def([non_symbol | _], _tail?) do
    {:error, {:invalid_form, "def name must be a symbol, got: #{inspect(non_symbol)}"}}
  end

  defp analyze_def(_, _tail?) do
    {:error, {:invalid_arity, :def, "expected (def name value) or (def name docstring value)"}}
  end

  # ============================================================
  # Idempotent definition: defonce
  # ============================================================

  defp analyze_defonce([{:symbol, name}, value_ast], _tail?) do
    with {:ok, value} <- do_analyze(value_ast, false) do
      {:ok, {:defonce, name, value, %{}}}
    end
  end

  defp analyze_defonce([{:symbol, name}, {:string, docstring}, value_ast], _tail?) do
    with {:ok, value} <- do_analyze(value_ast, false) do
      {:ok, {:defonce, name, value, %{docstring: docstring}}}
    end
  end

  defp analyze_defonce([{:symbol, _name}], _tail?) do
    {:error,
     {:invalid_arity, :defonce, "expected (defonce name value), got (defonce name) without value"}}
  end

  defp analyze_defonce([{:symbol, _name} | _], _tail?) do
    {:error,
     {:invalid_arity, :defonce, "expected (defonce name value) or (defonce name docstring value)"}}
  end

  defp analyze_defonce([non_symbol | _], _tail?) do
    {:error, {:invalid_form, "defonce name must be a symbol, got: #{inspect(non_symbol)}"}}
  end

  defp analyze_defonce(_, _tail?) do
    {:error,
     {:invalid_arity, :defonce, "expected (defonce name value) or (defonce name docstring value)"}}
  end

  # ============================================================
  # Named function definition: defn (desugars to def + fn)
  # ============================================================

  # (defn name docstring [params] body ...) - with docstring
  defp analyze_defn(
         [
           {:symbol, name},
           {:string, docstring},
           {:vector, _} = params_ast,
           first_body | rest_body
         ],
         _tail?
       ) do
    body_asts = [first_body | rest_body]

    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, body} <- wrap_body(body_asts, true) do
      {:ok, {:def, name, {:fn, params, body}, %{docstring: docstring}}}
    end
  end

  # (defn name [params] body ...) - without docstring
  defp analyze_defn([{:symbol, name}, {:vector, _} = params_ast, first_body | rest_body], _tail?) do
    body_asts = [first_body | rest_body]

    with {:ok, params} <- analyze_fn_params(params_ast),
         {:ok, body} <- wrap_body(body_asts, true) do
      {:ok, {:def, name, {:fn, params, body}, %{}}}
    end
  end

  # Error: (defn name [params]) - missing body
  defp analyze_defn([{:symbol, _name}, {:vector, _params}], _tail?) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body), missing body"}}
  end

  # Error: (defn name) - missing params and body
  defp analyze_defn([{:symbol, _name}], _tail?) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body)"}}
  end

  # Error: multi-arity syntax (defn f ([x] ...) ([x y] ...))
  defp analyze_defn([{:symbol, _name}, {:list, _} | _], _tail?) do
    {:error,
     {:invalid_form, "multi-arity defn not supported, use separate defn forms for each arity"}}
  end

  # Error: non-symbol name
  defp analyze_defn([non_symbol | _], _tail?) do
    {:error, {:invalid_form, "defn name must be a symbol, got: #{inspect(non_symbol)}"}}
  end

  defp analyze_defn(_, _tail?) do
    {:error, {:invalid_arity, :defn, "expected (defn name [params] body)"}}
  end

  # ============================================================
  # Comparison operators (strict 2-arity)
  # ============================================================

  defp analyze_comparison(op, [left_ast, right_ast], _tail?) do
    with {:ok, left} <- do_analyze(left_ast, false),
         {:ok, right} <- do_analyze(right_ast, false) do
      {:ok, {:call, {:var, op}, [left, right]}}
    end
  end

  defp analyze_comparison(op, args, _tail?) do
    {:error,
     {:invalid_arity, op,
      "comparison operators require exactly 2 arguments, got #{length(args)}. " <>
        "Use (and (#{op} a b) (#{op} b c)) for chained comparisons."}}
  end

  # ============================================================
  # Generic function call
  # ============================================================

  defp analyze_call({:list, [f_ast | arg_asts]}, _tail?) do
    with {:ok, f} <- do_analyze(f_ast, false),
         {:ok, args} <- analyze_list(arg_asts) do
      {:ok, {:call, f, args}}
    end
  end

  # ============================================================
  # Helper functions
  # ============================================================

  # Wrap multiple bodies in {:do, ...}, pass single body through (implicit do)
  @spec wrap_body([term()], boolean()) :: {:ok, CoreAST.t()} | {:error, error_reason()}
  defp wrap_body([single], tail?), do: do_analyze(single, tail?)

  defp wrap_body(bodies, tail?) when length(bodies) > 1 do
    with {:ok, analyzed} <- analyze_list_with_tail(bodies, tail?) do
      {:ok, {:do, analyzed}}
    end
  end

  defp analyze_list(xs) do
    xs
    |> Enum.reduce_while({:ok, []}, fn x, {:ok, acc} ->
      case do_analyze(x, false) do
        {:ok, x2} -> {:cont, {:ok, [x2 | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp analyze_list_with_tail(xs, tail?) do
    {others, last} = Enum.split(xs, -1)

    with {:ok, others2} <- analyze_list(others),
         {:ok, last2} <- do_analyze(List.first(last), tail?) do
      {:ok, others2 ++ [last2]}
    end
  end

  defp analyze_pairs(pairs) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn {k, v}, {:ok, acc} ->
      with {:ok, k2} <- do_analyze(k, false),
           {:ok, v2} <- do_analyze(v, false) do
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
  # Clojure namespace normalization
  # ============================================================

  # Normalize Clojure-style namespaces to builtins or provide helpful errors.
  # Takes a success callback to allow different behavior for symbol vs call position.
  defp normalize_clojure_namespace(ns, func, on_success) do
    cond do
      Env.clojure_namespace?(ns) and Env.constant?(ns, func) ->
        {:constant, value} = Map.get(Env.initial(), func)
        {:ok, {:literal, value}}

      Env.clojure_namespace?(ns) and Env.builtin?(func) ->
        on_success.()

      Env.clojure_namespace?(ns) ->
        category = Env.namespace_category(ns)
        available = Env.builtins_by_category(category) |> Enum.map_join(", ", &to_string/1)
        category_name = Env.category_name(category)

        {:error,
         {:invalid_form, "#{func} is not available. #{category_name} functions: #{available}"}}

      true ->
        {:error,
         {:invalid_form, "unknown namespace #{ns}/. Use tool/ for tools, data/ for input data"}}
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
