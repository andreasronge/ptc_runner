defmodule PtcRunner.Lisp.Analyze do
  @moduledoc """
  Validates and desugars RawAST into CoreAST.

  The analyzer transforms the parser's output (RawAST) into a validated,
  desugared intermediate form (CoreAST) that the interpreter can safely evaluate.

  ## Error Handling

  Returns `{:ok, CoreAST.t()}` on success or `{:error, error_reason()}` on failure.
  """

  alias PtcRunner.Lisp.Analyze.Conditionals
  alias PtcRunner.Lisp.Analyze.Definitions
  alias PtcRunner.Lisp.Analyze.Iteration
  alias PtcRunner.Lisp.Analyze.Patterns
  alias PtcRunner.Lisp.Analyze.Placeholder
  alias PtcRunner.Lisp.Analyze.PreludeScope
  alias PtcRunner.Lisp.Analyze.ShortFn
  alias PtcRunner.Lisp.CoreAST
  alias PtcRunner.Lisp.Env

  # Special form names that can be shadowed by local bindings.
  # These correspond to Clojure macros (not true special forms like if/def/recur/do).
  @shadowable_forms MapSet.new([
                      :fn,
                      :defn,
                      :let,
                      :loop,
                      :when,
                      :"when-not",
                      :"if-not",
                      :"if-let",
                      :"when-let",
                      :"if-some",
                      :"when-some",
                      :"when-first",
                      :cond,
                      :case,
                      :condp,
                      :and,
                      :or,
                      :->,
                      :"->>",
                      :"as->",
                      :"cond->",
                      :"cond->>",
                      :"some->",
                      :"some->>",
                      # Function-like forms intercepted by the analyzer but
                      # semantically plain functions in Clojure — must stay
                      # rebindable so `(let [pmap f] (pmap x))` calls the local.
                      :juxt,
                      :pmap,
                      :pcalls,
                      :apply,
                      :comment,
                      :doseq,
                      :for,
                      :quote,
                      :apropos,
                      :dir,
                      :doc,
                      :meta,
                      :"all-ns",
                      :"ns-name",
                      :"ns-publics"
                    ])

  @type error_reason ::
          {:invalid_form, String.t()}
          | {:invalid_arity, atom(), String.t()}
          | {:invalid_cond_form, String.t()}
          | {:invalid_thread_form, atom(), String.t()}
          | {:unsupported_pattern, term()}
          | {:invalid_placeholder, atom()}

  @doc """
  Returns the canonical list of all forms handled by the analyzer.

  These are forms dispatched via `dispatch_list_form/4` — special forms,
  macros, predicate builders, and control flow that the analyzer intercepts
  before the interpreter sees them.

  ## Examples

      iex> :let in PtcRunner.Lisp.Analyze.supported_forms()
      true

      iex> :filter in PtcRunner.Lisp.Analyze.supported_forms()
      false
  """
  @spec supported_forms() :: [atom()]
  def supported_forms do
    [
      :let,
      :loop,
      :recur,
      :doseq,
      :for,
      :fn,
      :if,
      :"if-not",
      :when,
      :"when-not",
      :"if-let",
      :"when-let",
      :"if-some",
      :"when-some",
      :"when-first",
      :cond,
      :case,
      :condp,
      :->,
      :"->>",
      :"as->",
      :"cond->",
      :"cond->>",
      :"some->",
      :"some->>",
      :do,
      :comment,
      :and,
      :or,
      :juxt,
      :pmap,
      :pcalls,
      :apply,
      :println,
      :return,
      :fail,
      :task,
      :"step-done",
      :"task-reset",
      :def,
      :defonce,
      :defn,
      :quote,
      :apropos,
      :dir,
      :doc,
      :meta,
      :"ns-publics",
      :"all-ns",
      :"ns-name",
      :"tool/servers"
    ]
  end

  @doc """
  Validates and desugars `raw_ast` into CoreAST.

  When a compiled `prelude` (`%PtcRunner.Lisp.Prelude{}`) is supplied, the
  analyzer resolves qualified prelude calls/refs (e.g. `crm/get-user`) against
  the prelude's PUBLIC export table and rejects writes into protected prelude
  namespaces (e.g. `(defn crm/get-user ...)`) with a protection programmer
  fault. The prelude is consulted via process-local state scoped to this single
  analysis pass (set on entry, cleared on exit), so the deep mutually-recursive
  `do_analyze/2` clauses do not each have to thread it. Passing `nil` keeps the
  pre-prelude behavior unchanged.
  """
  @spec analyze(term(), PtcRunner.Lisp.Prelude.t() | nil) ::
          {:ok, CoreAST.t()} | {:error, error_reason()}
  def analyze(raw_ast, prelude \\ nil) do
    PreludeScope.with_prelude(prelude, fn -> do_analyze(raw_ast, false) end)
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

  defp do_analyze({:quoted_symbol, name}, _tail?) when is_binary(name),
    do: {:ok, {:symbol_ref, name}}

  # ============================================================
  # Collections
  # ============================================================

  defp do_analyze({:vector, elems}, _tail?) do
    with {:ok, elems2} <- analyze_list(elems) do
      {:ok, {:vector, elems2}}
    end
  end

  defp do_analyze({:map, pairs}, _tail?) do
    # Clojure rejects a map literal with structurally-equal key FORMS at read
    # time (`{:a 1 :a 2}`, `{(f 1) :x (f 1) :y}`). That is a program-shape error
    # (rule 4), so PTC raises rather than silently dropping a pair. Keys that
    # only collide at runtime (distinct forms, e.g. `{:a 1 (keyword "a") 9}`, or
    # keyword/string flex-collisions) are NOT detectable here and dedupe at eval
    # (DIV-06 / DIV-47).
    with :ok <- check_duplicate_forms(Enum.map(pairs, fn {k, _v} -> k end), "key", "map"),
         {:ok, pairs2} <- analyze_pairs(pairs) do
      {:ok, {:map, pairs2}}
    end
  end

  defp do_analyze({:set, elems}, _tail?) do
    with :ok <- check_duplicate_forms(elems, "element", "set"),
         {:ok, elems2} <- analyze_list(elems) do
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
    if Placeholder.placeholder?(name) do
      {:error, {:invalid_placeholder, name}}
    else
      {:ok, {:var, name}}
    end
  end

  # Shadowed local: a symbol that was pre-marked because it shadows a special form name.
  # Treated as a plain variable reference so dispatch_list_form won't match it as a special form.
  defp do_analyze({:shadowed_local, name}, _tail?), do: {:ok, {:var, name}}

  # Var reader syntax: #'name produces {:var, name} from the parser
  defp do_analyze({:var, name}, _tail?) when is_atom(name) or is_binary(name),
    do: {:ok, {:var, name}}

  # Pre-analyzed core spliced in by the threading macros (-> ->> some-> cond->).
  # Threading is macro-like: it rewrites each step into a full list form and
  # re-analyzes it so the head dispatches as a special form (pmap, juxt, apply,
  # recur, ...) or a plain call. The already-analyzed accumulator rides through
  # this passthrough node instead of being re-analyzed from source.
  defp do_analyze({:analyzed, core}, _tail?), do: {:ok, core}

  defp do_analyze({:ns_symbol, :data, key}, _tail?), do: {:ok, {:data, key}}

  # Runtime tool callable in value position: `tool/search`.
  # Call position remains the existing direct `{:tool_call, ...}` path.
  defp do_analyze({:ns_symbol, :tool, name}, _tail?) do
    {:ok, {:runtime_callable, :tool, name}}
  end

  # Budget introspection: (budget/remaining) returns budget info map
  defp do_analyze({:ns_symbol, :budget, :remaining}, _tail?), do: {:ok, {:budget_remaining}}

  # Invalid budget namespace functions
  defp do_analyze({:ns_symbol, :budget, other}, _tail?) do
    {:error,
     {:invalid_form, "Unknown budget function: budget/#{other}. Available: budget/remaining"}}
  end

  # Clojure-style namespaces: normalize to built-in or provide helpful error.
  # `json/` uses namespace-qualified env keys (e.g., `:"json/parse-string"`)
  # so they need per-namespace lookup tables — see `normalize_clojure_namespace/3`
  # and `qualified_namespace_lookup/2` (Plans/json-support.md §4.4 OQ-5 option (a)).
  defp do_analyze({:ns_symbol, ns, key}, _tail?) do
    case PreludeScope.fetch_export(ns, key) do
      {:ok, export} ->
        # Value-position prelude export ref: resolves to the callable export
        # value at eval time. Arity is enforced at call position.
        {:ok, {:prelude_ref, export.ref}}

      :error ->
        case qualified_namespace_lookup(ns, key) do
          {:ok, qualified} -> {:ok, {:var, qualified}}
          :not_qualified -> prelude_or_clojure_namespace(ns, key, fn -> {:ok, {:var, key}} end)
          :unknown_member -> namespaced_unknown_member_error(ns, key)
        end
    end
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

  # Conditionals: nil-safe binding variants
  defp dispatch_list_form({:symbol, :"if-some"}, rest, _list, tail?),
    do: analyze_if_some(rest, tail?)

  defp dispatch_list_form({:symbol, :"when-some"}, rest, _list, tail?),
    do: analyze_when_some(rest, tail?)

  defp dispatch_list_form({:symbol, :"when-first"}, rest, _list, tail?),
    do: analyze_when_first(rest, tail?)

  # Conditionals: multi-way
  defp dispatch_list_form({:symbol, :cond}, rest, _list, tail?), do: analyze_cond(rest, tail?)
  defp dispatch_list_form({:symbol, :case}, rest, _list, tail?), do: analyze_case(rest, tail?)
  defp dispatch_list_form({:symbol, :condp}, rest, _list, tail?), do: analyze_condp(rest, tail?)

  defp dispatch_list_form({:symbol, :->}, rest, _list, tail?),
    do: analyze_thread(:->, rest, tail?)

  defp dispatch_list_form({:symbol, :"->>"}, rest, _list, tail?),
    do: analyze_thread(:"->>", rest, tail?)

  defp dispatch_list_form({:symbol, :"as->"}, rest, _list, tail?),
    do: analyze_as_thread(rest, tail?)

  defp dispatch_list_form({:symbol, :"cond->"}, rest, _list, tail?),
    do: analyze_cond_thread(:->, rest, tail?)

  defp dispatch_list_form({:symbol, :"cond->>"}, rest, _list, tail?),
    do: analyze_cond_thread(:"->>", rest, tail?)

  defp dispatch_list_form({:symbol, :"some->"}, rest, _list, tail?),
    do: analyze_some_thread(:->, rest, tail?)

  defp dispatch_list_form({:symbol, :"some->>"}, rest, _list, tail?),
    do: analyze_some_thread(:"->>", rest, tail?)

  defp dispatch_list_form({:symbol, :do}, rest, _list, tail?), do: analyze_do(rest, tail?)
  defp dispatch_list_form({:symbol, :comment}, _rest, _list, _tail?), do: {:ok, nil}
  defp dispatch_list_form({:symbol, :and}, rest, _list, tail?), do: analyze_and(rest, tail?)
  defp dispatch_list_form({:symbol, :or}, rest, _list, tail?), do: analyze_or(rest, tail?)
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

  # Qualified definition targets: `(def crm/x ...)` / `(defn crm/get-user ...)`.
  # V1 supports these only to REJECT writes into protected namespaces with a
  # protection programmer fault (plan §2), not to enable general qualified defs.
  defp dispatch_list_form({:symbol, head}, [{:ns_symbol, ns, sym} | _], _list, _tail?)
       when head in [:def, :defonce, :defn] do
    analyze_qualified_definition(head, ns, sym)
  end

  defp dispatch_list_form({:symbol, :def}, rest, _list, tail?), do: analyze_def(rest, tail?)

  defp dispatch_list_form({:symbol, :defonce}, rest, _list, tail?),
    do: analyze_defonce(rest, tail?)

  defp dispatch_list_form({:symbol, :defn}, rest, _list, tail?), do: analyze_defn(rest, tail?)

  defp dispatch_list_form({:symbol, :quote}, [symbol_ast], _list, _tail?),
    do: analyze_quote(symbol_ast)

  defp dispatch_list_form({:symbol, :quote}, args, _list, _tail?) do
    {:error,
     {:invalid_arity, :quote, "(quote symbol) requires exactly 1 symbol, got #{length(args)}"}}
  end

  defp dispatch_list_form({:symbol, :apropos}, [query_ast], _list, _tail?) do
    with {:ok, query} <- do_analyze(query_ast, false) do
      {:ok, {:repl_discovery, :apropos, [query]}}
    end
  end

  defp dispatch_list_form({:symbol, :apropos}, [query_ast, opts_ast], _list, _tail?) do
    with {:ok, query} <- do_analyze(query_ast, false),
         {:ok, opts} <- do_analyze(opts_ast, false) do
      {:ok, {:repl_discovery, :apropos, [query, opts]}}
    end
  end

  defp dispatch_list_form({:symbol, :apropos}, args, _list, _tail?) do
    {:error,
     {:invalid_arity, :apropos,
      "(apropos query) or (apropos query opts) — got #{length(args)} args"}}
  end

  defp dispatch_list_form({:symbol, :dir}, [server_ast], _list, _tail?) do
    with {:ok, server} <- do_analyze(server_ast, false) do
      {:ok, {:repl_discovery, :dir, [server]}}
    end
  end

  defp dispatch_list_form({:symbol, :dir}, [server_ast, opts_ast], _list, _tail?) do
    with {:ok, server} <- do_analyze(server_ast, false),
         {:ok, opts} <- do_analyze(opts_ast, false) do
      {:ok, {:repl_discovery, :dir, [server, opts]}}
    end
  end

  defp dispatch_list_form({:symbol, :dir}, args, _list, _tail?) do
    {:error,
     {:invalid_arity, :dir, "(dir server) or (dir server opts) — got #{length(args)} args"}}
  end

  defp dispatch_list_form({:symbol, :doc}, [tool_ref_ast], _list, _tail?) do
    with {:ok, tool_ref} <- do_analyze(tool_ref_ast, false) do
      {:ok, {:repl_discovery, :doc, [tool_ref]}}
    end
  end

  defp dispatch_list_form({:symbol, :doc}, args, _list, _tail?) do
    {:error,
     {:invalid_arity, :doc, "(doc tool-ref) requires exactly 1 argument, got #{length(args)}"}}
  end

  defp dispatch_list_form({:symbol, :meta}, [tool_ref_ast], _list, _tail?) do
    with {:ok, tool_ref} <- do_analyze(tool_ref_ast, false) do
      {:ok, {:repl_discovery, :meta, [tool_ref]}}
    end
  end

  defp dispatch_list_form({:symbol, :meta}, args, _list, _tail?) do
    {:error,
     {:invalid_arity, :meta, "(meta tool-ref) requires exactly 1 argument, got #{length(args)}"}}
  end

  defp dispatch_list_form({:symbol, :"ns-publics"}, [ns_ast], _list, _tail?) do
    with {:ok, ns_ref} <- do_analyze(ns_ast, false) do
      {:ok, {:repl_discovery, :ns_publics, [ns_ref]}}
    end
  end

  defp dispatch_list_form({:symbol, :"ns-publics"}, args, _list, _tail?) do
    {:error,
     {:invalid_arity, :"ns-publics",
      "(ns-publics namespace) requires exactly 1 argument, got #{length(args)}"}}
  end

  defp dispatch_list_form({:symbol, :"all-ns"}, [], _list, _tail?),
    do: {:ok, {:repl_discovery, :all_ns, []}}

  defp dispatch_list_form({:symbol, :"all-ns"}, args, _list, _tail?) do
    {:error, {:invalid_arity, :"all-ns", "(all-ns) takes no arguments, got #{length(args)}"}}
  end

  defp dispatch_list_form({:symbol, :"ns-name"}, [ns_ast], _list, _tail?) do
    with {:ok, ns_ref} <- do_analyze(ns_ast, false) do
      {:ok, {:repl_discovery, :ns_name, [ns_ref]}}
    end
  end

  defp dispatch_list_form({:symbol, :"ns-name"}, args, _list, _tail?) do
    {:error,
     {:invalid_arity, :"ns-name",
      "(ns-name namespace) requires exactly 1 argument, got #{length(args)}"}}
  end

  # Tool invocation via tool/ namespace: (tool/name args...)
  # Tool discovery via tool/ namespace
  defp dispatch_list_form({:ns_symbol, :tool, :servers}, [], _list, _tail?),
    do: {:ok, {:repl_discovery, :servers, []}}

  defp dispatch_list_form({:ns_symbol, :tool, :servers}, _args, _list, _tail?),
    do: {:error, {:invalid_arity, :"tool/servers", "(tool/servers) takes no arguments"}}

  defp dispatch_list_form({:ns_symbol, :tool, tool_name}, rest, _list, tail?),
    do: analyze_tool_call(tool_name, rest, tail?)

  defp dispatch_list_form({:ns_symbol, :mcp, other}, _rest, _list, _tail?),
    do: {:error, {:invalid_form, "Unknown mcp function: mcp/#{other}. Available: tool/servers"}}

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
    case PreludeScope.fetch_export(ns, func) do
      {:ok, export} ->
        analyze_prelude_call(export, rest, tail?)

      :error ->
        case qualified_namespace_lookup(ns, func) do
          {:ok, qualified} ->
            dispatch_list_form({:symbol, qualified}, rest, list, tail?)

          :not_qualified ->
            prelude_or_clojure_namespace(ns, func, fn ->
              dispatch_list_form({:symbol, func}, rest, list, tail?)
            end)

          :unknown_member ->
            namespaced_unknown_member_error(ns, func)
        end
    end
  end

  # Generic function call
  defp dispatch_list_form(_head, _rest, list, tail?), do: analyze_call(list, tail?)

  # ============================================================
  # Special form: let
  # ============================================================

  defp analyze_let([bindings_ast | body_asts], tail?) do
    with {:ok, bindings, shadowed} <- analyze_bindings(bindings_ast) do
      body_asts = mark_shadowed_asts(body_asts, shadowed)

      with {:ok, body} <- wrap_body(body_asts, tail?) do
        {:ok, {:let, bindings, body}}
      end
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
      |> Enum.reduce_while({:ok, [], MapSet.new()}, fn [pattern_ast, value_ast],
                                                       {:ok, acc, shadowed} ->
        marked_value = mark_shadowed_calls(value_ast, shadowed)

        with {:ok, pattern} <- analyze_pattern(pattern_ast),
             {:ok, value} <- do_analyze(marked_value, false) do
          new_shadows = MapSet.union(shadowed, compute_shadowed_names(pattern))
          {:cont, {:ok, [{:binding, pattern, value} | acc], new_shadows}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, rev, shadows} -> {:ok, Enum.reverse(rev), shadows}
        {:error, _} = err -> err
      end
    end
  end

  defp analyze_bindings(_) do
    {:error, {:invalid_form, "let bindings must be a vector"}}
  end

  # ============================================================
  # Special form: loop
  # ============================================================

  defp analyze_loop([bindings_ast | body_asts], _tail?) do
    with {:ok, bindings, shadowed} <- analyze_bindings(bindings_ast) do
      body_asts = mark_shadowed_asts(body_asts, shadowed)

      with {:ok, body} <- wrap_body(body_asts, true) do
        {:ok, {:loop, bindings, body}}
      end
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

  defp analyze_doseq(args, _tail?),
    do: Iteration.analyze_doseq(args, &do_analyze/2)

  defp analyze_for(args, _tail?),
    do: Iteration.analyze_for(args, &do_analyze/2)

  # ============================================================
  # Pattern analysis (destructuring)
  # Delegated to PtcRunner.Lisp.Analyze.Patterns
  # ============================================================

  defp analyze_pattern(ast), do: Patterns.analyze_pattern(ast)

  # ============================================================
  # Special form: if and when
  # ============================================================

  defp analyze_if(args, tail?),
    do: Conditionals.analyze_if(args, tail?, &do_analyze/2, &wrap_body/2)

  defp analyze_if_not(args, tail?),
    do: Conditionals.analyze_if_not(args, tail?, &do_analyze/2, &wrap_body/2)

  defp analyze_when(args, tail?),
    do: Conditionals.analyze_when(args, tail?, &do_analyze/2, &wrap_body/2)

  defp analyze_when_not(args, tail?),
    do: Conditionals.analyze_when_not(args, tail?, &do_analyze/2, &wrap_body/2)

  defp analyze_if_let(args, tail?),
    do: Conditionals.analyze_if_let(args, tail?, &do_analyze/2, &wrap_body/2)

  defp analyze_when_let(args, tail?),
    do: Conditionals.analyze_when_let(args, tail?, &do_analyze/2, &wrap_body/2)

  defp analyze_if_some(args, tail?),
    do:
      Conditionals.analyze_if_some(
        args,
        tail?,
        &do_analyze/2,
        &wrap_body/2,
        &mark_shadow_for_binding/2
      )

  defp analyze_when_some(args, tail?),
    do:
      Conditionals.analyze_when_some(
        args,
        tail?,
        &do_analyze/2,
        &wrap_body/2,
        &mark_shadow_for_binding/2
      )

  defp analyze_when_first(args, tail?),
    do:
      Conditionals.analyze_when_first(
        args,
        tail?,
        &do_analyze/2,
        &wrap_body/2,
        &mark_shadow_for_binding/2
      )

  defp analyze_cond(args, tail?),
    do: Conditionals.analyze_cond(args, tail?, &do_analyze/2, &wrap_body/2)

  defp analyze_case(args, tail?),
    do: Conditionals.analyze_case(args, tail?, &do_analyze/2, &wrap_body/2)

  defp analyze_condp(args, tail?),
    do: Conditionals.analyze_condp(args, tail?, &do_analyze/2, &wrap_body/2)

  # ============================================================
  # Special form: fn (anonymous functions)
  # ============================================================

  # Named fn: (fn name [params] body ...)
  defp analyze_fn([{:symbol, name}, params_ast | body_asts])
       when is_atom(name) or is_binary(name) do
    with {:ok, params} <- analyze_fn_params(params_ast) do
      shadowed = compute_shadowed_names(params)
      body_asts = mark_shadowed_asts(body_asts, shadowed)

      with {:ok, body} <- wrap_body(body_asts, true) do
        {:ok, {:fn, name, params, body}}
      end
    end
  end

  # Anonymous fn: (fn [params] body ...)
  defp analyze_fn([params_ast | body_asts]) do
    with {:ok, params} <- analyze_fn_params(params_ast) do
      shadowed = compute_shadowed_names(params)
      body_asts = mark_shadowed_asts(body_asts, shadowed)

      with {:ok, body} <- wrap_body(body_asts, true) do
        {:ok, {:fn, params, body}}
      end
    end
  end

  defp analyze_fn(_) do
    {:error,
     {:invalid_arity, :fn, "expected (fn [params] body ...) or (fn name [params] body ...)"}}
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

  defp analyze_quote({:symbol, name}), do: {:ok, {:symbol_ref, to_string(name)}}
  defp analyze_quote({:ns_symbol, ns, name}), do: {:ok, {:symbol_ref, "#{ns}/#{name}"}}
  defp analyze_quote({:quoted_symbol, name}) when is_binary(name), do: {:ok, {:symbol_ref, name}}

  defp analyze_quote(other) do
    {:error, {:invalid_form, "quote only supports symbols in this phase, got #{inspect(other)}"}}
  end

  defp analyze_list_of_patterns(patterns),
    do: Patterns.collect_results(patterns, &analyze_pattern/1)

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

  # Splice the threaded value into the step form and re-analyze the whole list,
  # so the head dispatches like any other list form. This keeps special forms
  # (pmap, pcalls, juxt, apply, return, recur, ...) working inside threads — a
  # direct {:call, ...} would treat their head as an undefined variable.
  defp apply_thread_step(kind, acc, {:list, [f_ast | arg_asts]}, tail?) do
    acc_ast = {:analyzed, acc}

    new_arg_asts =
      case kind do
        :-> -> [acc_ast | arg_asts]
        :"->>" -> arg_asts ++ [acc_ast]
      end

    do_analyze({:list, [f_ast | new_arg_asts]}, tail?)
  end

  # Bare step (e.g. `(-> x inc)`): resolve the head as a value and call it with
  # the threaded arg. A bare symbol is value position in source, so it is never
  # a special form here — resolving it as a var preserves local bindings that
  # shadow a form name (`(let [pmap f] (-> 3 pmap))`), which call-position shadow
  # marking can't reach.
  defp apply_thread_step(_kind, acc, step_ast, tail?) do
    with {:ok, f} <- do_analyze(step_ast, false) do
      resolve_call_or_recur(f, [acc], tail?)
    end
  end

  # ============================================================
  # Threading macro: as->
  # ============================================================

  defp analyze_as_thread([_expr_ast, {:symbol, _name}] = args, tail?) do
    analyze_as_thread_impl(args, tail?)
  end

  defp analyze_as_thread([_expr_ast, {:symbol, _name} | _forms] = args, tail?) do
    analyze_as_thread_impl(args, tail?)
  end

  defp analyze_as_thread(_, _tail?) do
    {:error, {:invalid_thread_form, :"as->", "expected (as-> expr name form ...)"}}
  end

  defp analyze_as_thread_impl([expr_ast, {:symbol, name} | forms], tail?) do
    with {:ok, acc} <- do_analyze(expr_ast, false) do
      as_thread_steps(name, acc, forms, tail?)
    end
  end

  defp as_thread_steps(_name, acc, [], _tail?), do: {:ok, acc}

  defp as_thread_steps(name, acc, [form | rest], tail?) do
    is_last? = rest == []
    step_tail? = is_last? and tail?

    # Mark shadowing in the form if the name shadows a special form
    shadowed = compute_shadowed_names({:var, name})
    form = mark_shadowed_calls(form, shadowed)

    with {:ok, form_core} <- do_analyze(form, step_tail?) do
      if is_last? do
        {:ok, {:let, [{:binding, {:var, name}, acc}], form_core}}
      else
        with {:ok, inner} <- as_thread_steps(name, {:var, name}, rest, tail?) do
          {:ok,
           {:let, [{:binding, {:var, name}, acc}],
            {:let, [{:binding, {:var, name}, form_core}], inner}}}
        end
      end
    end
  end

  # ============================================================
  # Threading macros: cond-> and cond->>
  # ============================================================

  defp analyze_cond_thread(_kind, [], _tail?) do
    {:error, {:invalid_thread_form, :"cond->", "requires at least one expression"}}
  end

  defp analyze_cond_thread(kind, [expr_ast | clause_forms], tail?) do
    if rem(length(clause_forms), 2) != 0 do
      form_name = if kind == :->, do: :"cond->", else: :"cond->>"

      {:error,
       {:invalid_thread_form, form_name,
        "requires even number of test/form pairs after expression"}}
    else
      with {:ok, acc} <- do_analyze(expr_ast, false) do
        pairs = clause_forms |> Enum.chunk_every(2) |> Enum.map(fn [t, f] -> {t, f} end)
        cond_thread_steps(kind, acc, pairs, tail?)
      end
    end
  end

  defp cond_thread_steps(_kind, acc, [], _tail?), do: {:ok, acc}

  defp cond_thread_steps(kind, acc, pairs, _tail?) do
    temp = {:var, :__ct}

    pairs
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, temp}, fn {test_ast, step_ast}, {:ok, inner} ->
      with {:ok, test_core} <- do_analyze(test_ast, false),
           {:ok, stepped} <- apply_thread_step(kind, temp, step_ast, false) do
        {:cont, {:ok, {:let, [{:binding, temp, {:if, test_core, stepped, temp}}], inner}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, body} -> {:ok, {:let, [{:binding, temp, acc}], body}}
      {:error, _} = err -> err
    end
  end

  # ============================================================
  # Threading macros: some-> and some->>
  # ============================================================

  defp analyze_some_thread(_kind, [], _tail?) do
    {:error, {:invalid_thread_form, :"some->", "requires at least one expression"}}
  end

  defp analyze_some_thread(_kind, [expr_ast], _tail?) do
    do_analyze(expr_ast, false)
  end

  defp analyze_some_thread(kind, [expr_ast | steps], tail?) do
    with {:ok, acc} <- do_analyze(expr_ast, false) do
      some_thread_steps(kind, acc, steps, tail?)
    end
  end

  defp some_thread_steps(_kind, acc, [], _tail?), do: {:ok, acc}

  defp some_thread_steps(kind, acc, [step | rest], tail?) do
    is_last? = rest == []
    step_tail? = is_last? and tail?
    temp = {:var, :__st}
    nil_check = {:call, {:var, :nil?}, [temp]}

    with {:ok, stepped} <- apply_thread_step(kind, temp, step, step_tail?) do
      if is_last? do
        {:ok, {:let, [{:binding, temp, acc}], {:if, nil_check, nil, stepped}}}
      else
        with {:ok, inner} <- some_thread_steps(kind, stepped, rest, tail?) do
          {:ok, {:let, [{:binding, temp, acc}], {:if, nil_check, nil, inner}}}
        end
      end
    end
  end

  defp resolve_call_or_recur({:var, :recur}, args, true), do: {:ok, {:recur, args}}

  defp resolve_call_or_recur({:var, :recur}, _args, false),
    do: {:error, {:invalid_form, "recur must be in tail position"}}

  defp resolve_call_or_recur(f, args, _tail?), do: {:ok, {:call, f, args}}

  # ============================================================
  # Function combinator: juxt
  # ============================================================

  # Clojure's juxt requires at least one function; a zero-arity (juxt) is an
  # arity error rather than a function that always returns [].
  defp analyze_juxt([], _tail?) do
    {:error, {:invalid_arity, :juxt, "expected (juxt f ...) with at least one function"}}
  end

  defp analyze_juxt(args, _tail?) do
    with {:ok, fns} <- analyze_list(args) do
      {:ok, {:juxt, fns}}
    end
  end

  # ============================================================
  # Parallel map: pmap
  # ============================================================

  # (pmap f coll) / (pmap f c1 c2 ...) - parallel map over one or more finite
  # collections, evaluating f for each (zipped) element concurrently. Multiple
  # collections zip element-wise and truncate to the shortest, matching `map`.
  defp analyze_pmap([fn_ast | coll_asts], _tail?) when coll_asts != [] do
    with {:ok, fn_core} <- do_analyze(fn_ast, false),
         {:ok, coll_cores} <- analyze_list(coll_asts) do
      {:ok, {:pmap, fn_core, coll_cores}}
    end
  end

  defp analyze_pmap(_, _tail?) do
    {:error, {:invalid_arity, :pmap, "expected (pmap f coll) or (pmap f c1 c2 ...)"}}
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
  # Definitions: def, defonce, defn
  # Delegated to PtcRunner.Lisp.Analyze.Definitions
  # ============================================================

  defp analyze_def(args, _tail?),
    do: Definitions.analyze_def(args, &analyze_value/1)

  defp analyze_defonce(args, _tail?),
    do: Definitions.analyze_defonce(args, &analyze_value/1)

  defp analyze_defn(args, _tail?) do
    Definitions.analyze_defn(args, &analyze_fn_params/1, fn body_asts, tail?, params ->
      shadowed = compute_shadowed_names(params)
      body_asts = mark_shadowed_asts(body_asts, shadowed)
      wrap_body(body_asts, tail?)
    end)
  end

  defp analyze_value(ast), do: do_analyze(ast, false)

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
  # An empty implicit-do body (e.g. `(when test)`, `(let [x 1])`) evaluates to
  # nil in Clojure rather than raising an arity error.
  defp wrap_body([], _tail?), do: {:ok, nil}

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

  # Read-time duplicate detection for map/set literals: two key/element FORMS
  # whose canonical values are equal are a duplicate (matches Clojure's reader;
  # rule 4 — a program-shape error). Returns the first repeated form. Runtime-only
  # collisions (distinct forms with equal values) are not detectable here and
  # dedupe at eval (DIV-06 / DIV-47).
  defp check_duplicate_forms(forms, label, container) do
    forms
    |> Enum.reduce_while(MapSet.new(), fn f, seen ->
      key = canonical_form(f)

      if MapSet.member?(seen, key),
        do: {:halt, {:dup, f}},
        else: {:cont, MapSet.put(seen, key)}
    end)
    |> case do
      {:dup, f} ->
        {:error,
         {:duplicate_key, "duplicate #{label} #{format_dup_form(f)} in #{container} literal"}}

      _seen ->
        :ok
    end
  end

  # Canonicalize a key/element form for value equality, recursively, approximating
  # Clojure's reader equality at any nesting depth:
  #   - map/set literals are UNORDERED -> sort their contents
  #     (`{:a 1 :b 2}` ≡ `{:b 2 :a 1}`, `#{1 2}` ≡ `#{2 1}`)
  #   - vector AND list literals are sequential and compare equal element-wise
  #     (`(= '(1 2) [1 2])` is true) -> one ordered `:seq` tag, order preserved
  #     (`[1 2]` ≠ `[2 1]`)
  #   - `+0.0` and `-0.0` are `=` in Clojure -> normalize to `0.0`
  #   - regex literals read into a FRESH Pattern each time -> a unique ref, so
  #     two `#"a"` forms (even nested, e.g. `#{[#"a"] [#"a"]}`) are never equal
  #
  # Best-effort STRUCTURAL form-equality, NOT full Clojure reader parity. It does
  # not unify cross-type numeric equals (`1` vs `1N`), nor reader-quote desugaring
  # (`'x` reads as `(quote x)` in Clojure but parses to a distinct AST node here).
  # Such rare cases dedupe at eval rather than raising (acceptable under-approx).
  #
  # Regex literals (`#"..."`) and short-fn literals (`#(...)`) each read as a fresh
  # object — a new `Pattern`, or in JVM Clojure a `fn*` with freshly-gensym'd
  # params — so two occurrences are never `=` and never collide. `make_ref/0`
  # guarantees each gets a unique canonical token, matching JVM Clojure (Babashka
  # diverges by reusing the stable `%1` param and wrongly flagging `#()` dups).
  defp canonical_form({:regex_literal, _}), do: make_ref()
  defp canonical_form({:short_fn, _}), do: make_ref()
  # Shadow-marking (a post-read semantic pass) rewrites call-position symbols to
  # `:shadowed_local`, but Clojure's reader dup check is name-based and predates
  # any binding analysis. Normalize back to the source symbol so e.g.
  # `(let [and ...] #{(and 1) [and 1]})` is still caught as a duplicate.
  defp canonical_form({:shadowed_local, name}), do: {:symbol, name}

  defp canonical_form({:map, pairs}) do
    {:map,
     pairs |> Enum.map(fn {k, v} -> {canonical_form(k), canonical_form(v)} end) |> Enum.sort()}
  end

  defp canonical_form({:set, elems}) do
    {:set, elems |> Enum.map(&canonical_form/1) |> Enum.sort()}
  end

  defp canonical_form({:vector, elems}), do: {:seq, Enum.map(elems, &canonical_form/1)}
  defp canonical_form({:list, elems}), do: {:seq, Enum.map(elems, &canonical_form/1)}
  defp canonical_form(n) when is_float(n) and n == 0.0, do: 0.0
  defp canonical_form(other), do: other

  defp format_dup_form({:keyword, kw}), do: ":#{kw}"
  defp format_dup_form({:string, s}), do: inspect(s)
  defp format_dup_form(n) when is_number(n), do: to_string(n)
  defp format_dup_form(other), do: inspect(other)

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

  # Per-namespace lookup tables for namespace-qualified env keys (OQ-5 option (a)).
  # Namespaces listed here use qualified atoms in `Env.initial()` (e.g.
  # `:"json/parse-string"`) rather than aliasing the unqualified name.
  # See Plans/json-support.md §4.4 step 4.
  #
  # Tables are computed at compile time from `Env.initial()` so the lookup is
  # a plain map access at runtime, and so the qualified atoms are guaranteed
  # interned before any user input reaches the analyzer (avoids the
  # `String.to_existing_atom/1` race where the analyzer module loads before
  # `Env.initial/0` (which consumes `Runtime.Builtins.bindings/0`) runs).
  @qualified_namespaces [:json, :Duration]

  @qualified_namespace_tables (for ns <- @qualified_namespaces, into: %{} do
                                 prefix = Atom.to_string(ns) <> "/"
                                 prefix_len = byte_size(prefix)

                                 entries =
                                   for {atom, _binding} <- PtcRunner.Lisp.Env.initial(),
                                       atom_str = Atom.to_string(atom),
                                       String.starts_with?(atom_str, prefix),
                                       into: %{} do
                                     rest =
                                       binary_part(
                                         atom_str,
                                         prefix_len,
                                         byte_size(atom_str) - prefix_len
                                       )

                                     {String.to_atom(rest), atom}
                                   end

                                 {ns, entries}
                               end)

  @qualified_namespace_members (for {ns, table} <- @qualified_namespace_tables, into: %{} do
                                  members = table |> Map.values() |> Enum.map(&Atom.to_string/1)
                                  {ns, members |> Enum.sort() |> Enum.join(", ")}
                                end)

  # Lookup a `(namespace/func)` form against the qualified-env-key namespaces.
  # Returns:
  #   - `{:ok, qualified_atom}` when `<ns>/<func>` resolves to an env entry
  #   - `:unknown_member` when `<ns>` is qualified but `<func>` isn't a member
  #   - `:not_qualified` when `<ns>` is not in the qualified namespace set
  #     (caller falls through to the legacy `normalize_clojure_namespace/3` path)
  defp qualified_namespace_lookup(:Boolean, "parseBoolean"), do: {:ok, :"Boolean/parseBoolean"}
  defp qualified_namespace_lookup(:Double, "parseDouble"), do: {:ok, :"parse-double"}
  defp qualified_namespace_lookup(:Float, "parseFloat"), do: {:ok, :"parse-double"}
  defp qualified_namespace_lookup(:Integer, "parseInt"), do: {:ok, :"parse-long"}
  defp qualified_namespace_lookup(:Long, "parseLong"), do: {:ok, :"parse-long"}
  defp qualified_namespace_lookup(:"java.time.Duration", :between), do: {:ok, :"Duration/between"}

  defp qualified_namespace_lookup(:"java.time.Duration", "between"),
    do: {:ok, :"Duration/between"}

  defp qualified_namespace_lookup(ns, func) do
    case Map.get(@qualified_namespace_tables, ns) do
      nil ->
        :not_qualified

      table ->
        case Map.get(table, func) do
          nil -> :unknown_member
          qualified -> {:ok, qualified}
        end
    end
  end

  defp namespaced_unknown_member_error(ns, func) do
    available = Map.get(@qualified_namespace_members, ns, "")
    category_name = Env.category_name(Env.namespace_category(ns))

    {:error,
     {:invalid_form, "#{ns}/#{func} is not available. #{category_name} functions: #{available}"}}
  end

  # A public prelude export call: validate arity against the export record,
  # analyze the args, and emit a {:prelude_call, ref, args} node the evaluator
  # resolves from the export table (invoking the captured closure against the
  # captured private prelude env). Private helpers have no export record, so
  # this path is unreachable for them — they stay user-invisible (plan §5/§8).
  defp analyze_prelude_call(%{ref: ref, arity: arity} = export, arg_asts, _tail?) do
    actual = length(arg_asts)
    min_arity = Map.get(export, :min_arity, 0)

    cond do
      arity == :variadic and actual >= min_arity ->
        with {:ok, args} <- analyze_list(arg_asts) do
          {:ok, {:prelude_call, ref, args}}
        end

      arity == :variadic ->
        {:error,
         {:invalid_arity, :prelude_call,
          "#{ref} expects at least #{min_arity} argument(s), got #{actual}"}}

      arity == actual ->
        with {:ok, args} <- analyze_list(arg_asts) do
          {:ok, {:prelude_call, ref, args}}
        end

      true ->
        {:error,
         {:invalid_arity, :prelude_call, "#{ref} expects #{arity} argument(s), got #{actual}"}}
    end
  end

  # Resolution fall-through for an `ns/func` in call/value position whose `ns`
  # is NOT a known public prelude export. Clojure-style builtin namespaces keep
  # their existing normalization. A KNOWN prelude namespace whose member is not
  # a public export (an unknown export, or a private helper with no export
  # record) becomes an actionable unknown-export programmer fault pointing at
  # discovery forms (plan acceptance: "Reject Unknown Namespaced Call",
  # "Private Helper Is Not User-visible"). Everything else keeps the generic
  # unknown-namespace message.
  defp prelude_or_clojure_namespace(ns, func, on_success) do
    cond do
      Env.clojure_namespace?(ns) ->
        normalize_clojure_namespace(ns, func, on_success)

      PreludeScope.prelude_namespace?(ns) ->
        unknown_export_error(ns, func)

      true ->
        normalize_clojure_namespace(ns, func, on_success)
    end
  end

  # A prelude namespace is known but `func` is not one of its public exports
  # (unknown export, or a private helper that has no export record).
  defp unknown_export_error(ns, func) do
    {:error,
     {:invalid_form,
      "#{ns}/#{func} is not a public export of namespace #{ns}. " <>
        "Discover its public exports with (ns-publics '#{ns}) or (apropos \"#{func}\")."}}
  end

  # A qualified definition target `(def ns/sym ...)` / `(defn ns/sym ...)`.
  # Writing into a PROTECTED namespace (reserved or prelude-declared) or onto a
  # public prelude EXPORT is a protection programmer fault naming the
  # namespace/symbol (plan §2). A qualified definition outside any protected
  # namespace is an explicit unsupported-qualified-definition error (V1 does
  # not support general qualified defs).
  defp analyze_qualified_definition(_head, ns, sym) do
    cond do
      # The target IS a public prelude export: say so explicitly so the user
      # learns they are attempting to shadow a curated capability, not just
      # writing into a protected namespace (plan §2 "OR the symbol is a public
      # prelude export").
      match?({:ok, _}, PreludeScope.fetch_export(ns, sym)) ->
        {:error,
         {:invalid_form,
          "cannot redefine #{ns}/#{sym}: it is a public export of the protected " <>
            "namespace #{ns} and cannot be redefined by user code."}}

      # The target's namespace is protected (reserved host namespace or a
      # prelude-declared namespace) even though the symbol is not a public
      # export (e.g. a private helper or a brand-new symbol).
      PreludeScope.protected_namespace?(ns) ->
        {:error,
         {:invalid_form,
          "cannot define #{ns}/#{sym}: #{ns} is a protected namespace whose " <>
            "names cannot be redefined by user code."}}

      true ->
        {:error,
         {:invalid_form,
          "qualified definitions are not supported: cannot define #{ns}/#{sym}. " <>
            "Define unqualified names in the user namespace instead."}}
    end
  end

  # Normalize Clojure-style namespaces to builtins or provide helpful errors.
  # Takes a success callback to allow different behavior for symbol vs call position.
  defp normalize_clojure_namespace(ns, func, on_success) do
    cond do
      Env.clojure_namespace?(ns) and namespace_builtin?(ns, func) and Env.constant?(ns, func) ->
        {:constant, value} = Map.get(Env.initial(), func)
        {:ok, {:literal, value}}

      Env.clojure_namespace?(ns) and namespace_builtin?(ns, func) ->
        on_success.()

      Env.clojure_namespace?(ns) ->
        category = Env.namespace_category(ns)
        available = Env.builtins_by_namespace(ns) |> Enum.map_join(", ", &to_string/1)
        category_name = Env.category_name(category)

        {:error,
         {:invalid_form, "#{func} is not available. #{category_name} functions: #{available}"}}

      true ->
        {:error,
         {:invalid_form,
          "unknown namespace #{ns}/. Available namespaces: #{available_namespaces()}. " <>
            "For JSON parsing use json/parse-string (not cheshire.core/...)."}}
    end
  end

  defp namespace_builtin?(ns, func) do
    Env.clojure_namespace?(ns) and func in Env.builtins_by_namespace(ns)
  end

  defp available_namespaces do
    [
      "data/",
      "tool/",
      "mcp/",
      "budget/",
      "json/",
      "clojure.core/",
      "core/",
      "clojure.string/",
      "str/",
      "string/",
      "clojure.set/",
      "set/",
      "clojure.walk/",
      "walk/",
      "regex/",
      "Math/",
      "System/",
      "Boolean/",
      "Double/",
      "Float/",
      "Integer/",
      "Long/",
      "LocalDate/",
      "Instant/",
      "Duration/",
      "java.time.LocalDate/",
      "java.time.Instant/",
      "java.time.Duration/",
      "java.util.Date."
    ]
    |> Enum.join(", ")
  end

  # ============================================================
  # Placeholder detection
  # ============================================================

  # ============================================================
  # Local shadowing of special form names (GAP-S06)
  # ============================================================

  # Compute the set of special form names that are shadowed by fn params
  # (list of patterns or {:variadic, ...} tuple from analyze_fn_params).
  defp compute_shadowed_names(params) when is_list(params) do
    params |> param_names() |> MapSet.new() |> MapSet.intersection(@shadowable_forms)
  end

  defp compute_shadowed_names({:variadic, _, _} = params) do
    params |> param_names() |> MapSet.new() |> MapSet.intersection(@shadowable_forms)
  end

  # Compute shadowed names from a single analyzed pattern (for let/loop bindings).
  defp compute_shadowed_names(pattern) do
    pattern |> pattern_names() |> MapSet.new() |> MapSet.intersection(@shadowable_forms)
  end

  # Extract names bound by fn params (analyzed CoreAST form).
  defp param_names(params) when is_list(params), do: Enum.flat_map(params, &pattern_names/1)

  defp param_names({:variadic, leading, rest_pattern}) do
    Enum.flat_map(leading, &pattern_names/1) ++ pattern_names(rest_pattern)
  end

  # Extract variable names from a single analyzed pattern.
  defp pattern_names({:var, name}), do: [name]
  defp pattern_names({:destructure, {:keys, keys, _defaults}}), do: keys

  defp pattern_names({:destructure, {:map, keys, renames, _defaults}}) do
    keys ++
      Enum.flat_map(renames, fn {target_pattern, _source_key} -> pattern_names(target_pattern) end)
  end

  defp pattern_names({:destructure, {:as, name, inner}}), do: [name | pattern_names(inner)]

  defp pattern_names({:destructure, {:seq, patterns}}),
    do: Enum.flat_map(patterns, &pattern_names/1)

  defp pattern_names({:destructure, {:seq_rest, leading, rest}}) do
    Enum.flat_map(leading, &pattern_names/1) ++ pattern_names(rest)
  end

  defp pattern_names(_), do: []

  # Compute and apply shadowing for a single binding name in conditional forms.
  # Used as a callback by if-some, when-some, when-first in Conditionals module.
  defp mark_shadow_for_binding({:var, name}, asts) when is_list(asts) do
    shadowed = [name] |> MapSet.new() |> MapSet.intersection(@shadowable_forms)
    mark_shadowed_asts(asts, shadowed)
  end

  # Mark a list of RawAST forms with shadowed calls.
  defp mark_shadowed_asts(asts, shadowed) when is_list(asts) do
    if Enum.empty?(shadowed),
      do: asts,
      else: Enum.map(asts, &do_mark_shadowed(&1, shadowed))
  end

  # Pre-transform RawAST to replace shadowed special form names in call position
  # with {:shadowed_local, name} so dispatch_list_form treats them as function calls.
  defp mark_shadowed_calls(ast, shadowed) do
    if Enum.empty?(shadowed), do: ast, else: do_mark_shadowed(ast, shadowed)
  end

  defp do_mark_shadowed({:list, [{:symbol, name} | rest]}, shadowed) do
    if MapSet.member?(shadowed, name) do
      {:list, [{:shadowed_local, name} | Enum.map(rest, &do_mark_shadowed(&1, shadowed))]}
    else
      {:list, [{:symbol, name} | Enum.map(rest, &do_mark_shadowed(&1, shadowed))]}
    end
  end

  defp do_mark_shadowed({:list, elems}, shadowed) do
    {:list, Enum.map(elems, &do_mark_shadowed(&1, shadowed))}
  end

  defp do_mark_shadowed({:vector, elems}, shadowed) do
    {:vector, Enum.map(elems, &do_mark_shadowed(&1, shadowed))}
  end

  defp do_mark_shadowed({:map, pairs}, shadowed) do
    {:map,
     Enum.map(pairs, fn {k, v} ->
       {do_mark_shadowed(k, shadowed), do_mark_shadowed(v, shadowed)}
     end)}
  end

  defp do_mark_shadowed({:set, elems}, shadowed) do
    {:set, Enum.map(elems, &do_mark_shadowed(&1, shadowed))}
  end

  defp do_mark_shadowed({:short_fn, body}, shadowed) do
    {:short_fn, Enum.map(body, &do_mark_shadowed(&1, shadowed))}
  end

  defp do_mark_shadowed({:program, exprs}, shadowed) do
    {:program, Enum.map(exprs, &do_mark_shadowed(&1, shadowed))}
  end

  defp do_mark_shadowed(other, _shadowed), do: other
end
