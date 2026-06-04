defmodule PtcRunner.Lisp.Prelude.Compiler do
  @moduledoc """
  Compiles deployment prelude SOURCE into a `%PtcRunner.Lisp.Prelude{}`
  artifact (Capability Prelude V1, plan §1 / §3).

  ## What this does

    1. Parses the prelude source to raw AST.
    2. Walks the top-level program treating `(ns name "doc" {meta})` as a
       COMPILER-ONLY directive (not a general user-runtime form), and
       `defn`/`defn-` as export/private-helper definitions under the current
       namespace.
    3. Runs compile-time validation that does NOT depend on a selected
       runtime: reserved-namespace rejection, missing/invalid namespace,
       duplicate public refs, invalid visibility, invalid arity/signature
       metadata. Failures are returned as
       `{:error, %PtcRunner.Lisp.Prelude.ValidationError{}}`.
    4. Builds `%Export{}` records for public definitions, normalizing
       kebab-case PTC-Lisp metadata keywords (`:provider-ref`) at the host
       boundary and inferring backing metadata only for literal
       `(tool/call {:server "x" :tool "y" ...})` patterns (plan §3).
    5. Captures a callable private prelude env by analyzing+evaluating the
       definition forms (ns directives stripped, `defn-` rewritten to `defn`)
       through the existing PTC-Lisp pipeline. The captured value is the
       resulting `user_ns` map (bare symbol => `{:closure, ...}`). NOTE: the
       evaluator's lexical closure capture does NOT fold sibling top-level
       defs into each closure's `captured_env` — sibling helpers resolve by
       name through `user_ns` at CALL time. The whole `private_env` map IS
       that namespace, so P2 must thread `private_env` as the user_ns layer
       when invoking an export for siblings to resolve (fact #6 capture seam,
       proven end-to-end during P0).
    6. Computes a sha256 source hash (plan §12).

  Attach-time `requires` validation against a selected upstream runtime is a
  SEPARATE later phase and is not performed here.
  """

  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Env
  alias PtcRunner.Lisp.Eval
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Export
  alias PtcRunner.Lisp.Prelude.Spec
  alias PtcRunner.Lisp.Prelude.ValidationError
  alias PtcRunner.Lisp.ProtectedNamespaces
  alias PtcRunner.Lisp.SourceAtoms
  alias PtcRunner.Sandbox

  @default_visibility :prompt
  @valid_effects [:read, :write, :unknown]

  @doc """
  Compiles prelude `source` into a `%PtcRunner.Lisp.Prelude{}`.

  Returns `{:ok, prelude}` or `{:error, %ValidationError{}}`.
  """
  @spec compile(String.t()) :: {:ok, Prelude.t()} | {:error, ValidationError.t()}
  def compile(source) when is_binary(source) do
    with {:ok, {:program, forms}} <- parse(source),
         {:ok, specs, ns_meta} <- collect_specs(forms),
         {:ok, exports} <- build_exports(specs, ns_meta),
         {:ok, private_env} <- build_runtime(specs) do
      namespaces = ns_meta |> Map.keys() |> Enum.sort()

      {:ok,
       %Prelude{
         namespaces: namespaces,
         exports: exports,
         private_env: private_env,
         source_hash: source_hash(source),
         metadata: %{namespaces: ns_meta}
       }}
    end
  end

  # ============================================================
  # Parse
  # ============================================================

  defp parse(source) do
    case Parser.parse(source) do
      {:ok, ast} ->
        {:ok, normalize_program(ast)}

      {:error, {:parse_error, message}} ->
        {:error, ValidationError.new(:parse_error, "prelude parse error: #{message}")}
    end
  end

  # Multiple top-level forms parse to `{:program, forms}`; a single top-level
  # form parses to the bare form. Normalize both to `{:program, forms}`.
  defp normalize_program({:program, forms}) when is_list(forms), do: {:program, forms}
  defp normalize_program(single), do: {:program, [single]}

  # ============================================================
  # Collect namespace directives + definition specs
  # ============================================================

  # Walks the top-level forms left-to-right, threading the "current
  # namespace" and accumulated namespace metadata. Returns specs in source
  # order plus a namespace-name => namespace-meta map.
  defp collect_specs(forms) do
    initial = %{current_ns: nil, ns_meta: %{}, specs: []}

    forms
    |> Enum.reduce_while({:ok, initial}, fn form, {:ok, acc} ->
      case handle_form(form, acc) do
        {:ok, acc2} -> {:cont, {:ok, acc2}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, %{ns_meta: ns_meta, specs: specs}} ->
        {:ok, Enum.reverse(specs), ns_meta}

      {:error, _} = err ->
        err
    end
  end

  # (ns name "doc" {meta}) — compiler directive.
  defp handle_form({:list, [{:symbol, ns_head} | rest]}, acc) when ns_head in ["ns", :ns] do
    handle_ns_directive(rest, acc)
  end

  # (defn ...) / (defn- ...) — definition.
  defp handle_form({:list, [{:symbol, defn_head} | rest]}, acc)
       when defn_head in [:defn, "defn", "defn-"] do
    private? = defn_head == "defn-"
    handle_defn(rest, private?, acc)
  end

  # (def name value) — a plain prelude constant/binding. Treated as a public
  # export with arity 0 unless private markers are added later. For V1 only
  # symbol-named defs are accepted; everything else is a signature error.
  defp handle_form({:list, [{:symbol, def_head} | rest]}, acc) when def_head in [:def, "def"] do
    handle_def(rest, acc)
  end

  defp handle_form(other, _acc) do
    {:error,
     ValidationError.new(
       :compile_error,
       "unsupported top-level prelude form: #{inspect(other, limit: 5)}"
     )}
  end

  # ============================================================
  # (ns ...) directive
  # ============================================================

  defp handle_ns_directive([name_ast | rest], acc) do
    with {:ok, ns_name} <- namespace_name(name_ast),
         :ok <- reject_reserved(ns_name),
         :ok <- reject_redeclared(ns_name, acc),
         {:ok, ns_meta} <- ns_metadata(rest) do
      {:ok,
       %{
         acc
         | current_ns: ns_name,
           ns_meta: Map.put(acc.ns_meta, ns_name, ns_meta)
       }}
    end
  end

  defp handle_ns_directive([], _acc) do
    {:error, ValidationError.new(:invalid_namespace, "(ns ...) requires a namespace name")}
  end

  # A namespace must be declared exactly once: re-opening it with a different
  # default (e.g. `:visibility`) would retroactively change the visibility of
  # definitions collected under the FIRST directive. Reject it fail-closed
  # rather than silently mis-compiling earlier exports.
  defp reject_redeclared(ns_name, acc) do
    if Map.has_key?(acc.ns_meta, ns_name) do
      {:error,
       ValidationError.new(
         :invalid_namespace,
         "namespace `#{ns_name}` is declared more than once; declare each prelude namespace exactly once",
         namespace: ns_name
       )}
    else
      :ok
    end
  end

  defp namespace_name({:symbol, name}) when is_binary(name), do: {:ok, name}
  defp namespace_name({:symbol, name}) when is_atom(name), do: {:ok, Atom.to_string(name)}

  defp namespace_name(other) do
    {:error,
     ValidationError.new(
       :invalid_namespace,
       "namespace name must be a symbol, got: #{inspect(other, limit: 5)}"
     )}
  end

  defp reject_reserved(ns_name) do
    if ProtectedNamespaces.reserved?(ns_name) do
      {:error,
       ValidationError.new(
         :reserved_namespace,
         "prelude cannot declare reserved namespace `#{ns_name}`",
         namespace: ns_name
       )}
    else
      :ok
    end
  end

  # (ns name) | (ns name "doc") | (ns name "doc" {meta}) | (ns name {meta})
  defp ns_metadata([]), do: {:ok, %{doc: nil, visibility: @default_visibility}}

  defp ns_metadata([{:string, doc}]),
    do: {:ok, %{doc: doc, visibility: @default_visibility}}

  defp ns_metadata([{:map, _} = meta_ast]), do: ns_metadata([{:string, nil}, meta_ast])

  defp ns_metadata([{:string, doc}, {:map, pairs}]) do
    with {:ok, meta} <- normalize_meta(pairs),
         {:ok, visibility} <- visibility(Map.get(meta, "visibility")) do
      {:ok, %{doc: doc, visibility: visibility}}
    end
  end

  defp ns_metadata(other) do
    {:error,
     ValidationError.new(
       :invalid_namespace,
       "malformed (ns ...) directive: #{inspect(other, limit: 5)}"
     )}
  end

  # ============================================================
  # (defn ...) / (defn- ...)
  # ============================================================

  # (defn name "doc" {meta} [params] body...)
  defp handle_defn([name_ast, {:string, doc}, {:map, pairs}, params_ast | body], private?, acc) do
    with {:ok, meta} <- normalize_meta(pairs) do
      add_def(acc, name_ast, doc, meta, params_ast, body, private?)
    end
  end

  # (defn name "doc" [params] body...)
  defp handle_defn([name_ast, {:string, doc}, params_ast | body], private?, acc) do
    add_def(acc, name_ast, doc, %{}, params_ast, body, private?)
  end

  # (defn name {meta} [params] body...)
  defp handle_defn([name_ast, {:map, pairs}, params_ast | body], private?, acc) do
    with {:ok, meta} <- normalize_meta(pairs) do
      add_def(acc, name_ast, nil, meta, params_ast, body, private?)
    end
  end

  # (defn name [params] body...)
  defp handle_defn([name_ast, params_ast | body], private?, acc) do
    add_def(acc, name_ast, nil, %{}, params_ast, body, private?)
  end

  defp handle_defn(other, _private?, _acc) do
    {:error,
     ValidationError.new(
       :invalid_signature,
       "malformed defn in prelude: #{inspect(other, limit: 5)}"
     )}
  end

  # (def name value) | (def name "doc" value)
  defp handle_def([name_ast, {:string, doc}, value_ast], acc) do
    add_const(acc, name_ast, doc, value_ast)
  end

  defp handle_def([name_ast, value_ast], acc) do
    add_const(acc, name_ast, nil, value_ast)
  end

  defp handle_def(other, _acc) do
    {:error,
     ValidationError.new(
       :invalid_signature,
       "malformed def in prelude: #{inspect(other, limit: 5)}"
     )}
  end

  # ============================================================
  # Spec construction
  # ============================================================

  defp add_def(acc, name_ast, doc, metadata, params_ast, body, private?) do
    with {:ok, ns} <- require_current_ns(acc, name_ast),
         {:ok, symbol} <- symbol_name(name_ast),
         :ok <- reject_builtin_name(symbol),
         {:ok, arity} <- params_arity(params_ast) do
      spec = %Spec{
        namespace: ns,
        symbol: symbol,
        private?: private?,
        arity: arity,
        doc: doc,
        metadata: metadata,
        params_form: params_ast,
        body_form: rewrite_self_refs(body, ns)
      }

      {:ok, %{acc | specs: [spec | acc.specs]}}
    end
  end

  defp add_const(acc, name_ast, doc, value_ast) do
    with {:ok, ns} <- require_current_ns(acc, name_ast),
         {:ok, symbol} <- symbol_name(name_ast),
         :ok <- reject_builtin_name(symbol) do
      spec = %Spec{
        namespace: ns,
        symbol: symbol,
        private?: false,
        arity: 0,
        doc: doc,
        metadata: %{},
        params_form: nil,
        body_form: rewrite_self_refs([value_ast], ns)
      }

      {:ok, %{acc | specs: [spec | acc.specs]}}
    end
  end

  # A prelude definition name must not collide with a bounded built-in or
  # special form (e.g. `count`, `map`, `if`). Such names intern to ATOMS, while
  # prelude defs are captured under STRING keys, so a bare same-namespace
  # reference would silently resolve to the built-in instead of the prelude def.
  # Reject fail-closed; prelude exports should use distinct kebab-case names.
  defp reject_builtin_name(symbol) do
    if is_atom(SourceAtoms.intern(symbol)) do
      {:error,
       ValidationError.new(
         :reserved_name,
         "prelude definition `#{symbol}` collides with a built-in name; choose a distinct (kebab-case) name"
       )}
    else
      :ok
    end
  end

  # Rewrite SAME-namespace qualified refs (e.g. `crm/get-user` inside namespace
  # `crm`) to bare refs (`get-user`) so a prelude export can call a SIBLING
  # export by its public qualified name. The bare ref resolves at runtime through
  # the namespace's captured private env, and the `requires` call-graph sees it
  # as a real sibling edge. Reserved/other-namespace refs (`tool/...`, `hr/...`)
  # are left untouched.
  defp rewrite_self_refs(forms, ns) when is_list(forms),
    do: Enum.map(forms, &rewrite_self_refs(&1, ns))

  defp rewrite_self_refs({:ns_symbol, ns, sym}, ns) when is_binary(ns), do: {:symbol, sym}

  defp rewrite_self_refs({:list, items}, ns), do: {:list, rewrite_self_refs(items, ns)}

  defp rewrite_self_refs({:vector, items}, ns), do: {:vector, rewrite_self_refs(items, ns)}

  defp rewrite_self_refs({:map, pairs}, ns),
    do:
      {:map,
       Enum.map(pairs, fn {k, v} -> {rewrite_self_refs(k, ns), rewrite_self_refs(v, ns)} end)}

  defp rewrite_self_refs(other, _ns), do: other

  defp require_current_ns(%{current_ns: nil}, name_ast) do
    {:error,
     ValidationError.new(
       :missing_namespace,
       "definition #{inspect(name_ast, limit: 3)} appears before any (ns ...) directive"
     )}
  end

  defp require_current_ns(%{current_ns: ns}, _name_ast), do: {:ok, ns}

  defp symbol_name({:symbol, name}) when is_binary(name), do: {:ok, name}
  defp symbol_name({:symbol, name}) when is_atom(name), do: {:ok, Atom.to_string(name)}

  defp symbol_name(other) do
    {:error,
     ValidationError.new(
       :invalid_signature,
       "definition name must be a symbol, got: #{inspect(other, limit: 5)}"
     )}
  end

  defp params_arity({:vector, params}), do: {:ok, vector_arity(params)}

  defp params_arity(other) do
    {:error,
     ValidationError.new(
       :invalid_signature,
       "expected a [params] vector, got: #{inspect(other, limit: 5)}"
     )}
  end

  # `& rest` variadic marker makes arity :variadic.
  defp vector_arity(params) do
    if Enum.any?(params, &variadic_marker?/1) do
      :variadic
    else
      length(params)
    end
  end

  defp variadic_marker?({:symbol, :&}), do: true
  defp variadic_marker?({:symbol, "&"}), do: true
  defp variadic_marker?(_), do: false

  # ============================================================
  # Build public Export records
  # ============================================================

  defp build_exports(specs, ns_meta) do
    public = Enum.reject(specs, & &1.private?)
    ns_backing = namespace_backing(specs)

    with :ok <- reject_duplicate_refs(specs) do
      Enum.reduce_while(public, {:ok, []}, fn spec, {:ok, acc} ->
        case build_export(spec, ns_meta, ns_backing) do
          {:ok, export} -> {:cont, {:ok, [export | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        {:error, _} = err -> err
      end
    end
  end

  # Names must be unique within a namespace across BOTH public and private
  # definitions: `build_runtime/1` captures public and private defns into one
  # per-namespace map keyed by bare symbol, so a public/private name clash would
  # silently overwrite the callable while the public export record (arity/docs)
  # kept pointing at the shadowed definition.
  defp reject_duplicate_refs(specs) do
    specs
    |> Enum.map(&ref(&1.namespace, &1.symbol))
    |> Enum.frequencies()
    |> Enum.find(fn {_ref, count} -> count > 1 end)
    |> case do
      nil ->
        :ok

      {ref, _} ->
        {:error,
         ValidationError.new(
           :duplicate_ref,
           "duplicate prelude definition `#{ref}` (names must be unique within a namespace)",
           ref: ref
         )}
    end
  end

  defp build_export(%Spec{} = spec, ns_meta, ns_backing) do
    # Visibility precedence: explicit export metadata, then the declaring
    # namespace's default, then the global default (plan §10).
    ns_default =
      ns_meta
      |> Map.get(spec.namespace, %{})
      |> Map.get(:visibility, @default_visibility)

    with {:ok, visibility} <- visibility(Map.get(spec.metadata, "visibility", ns_default)),
         {:ok, explicit_requires} <- validate_requires(Map.get(spec.metadata, "requires")) do
      transitive =
        ns_backing
        |> Map.get(spec.namespace, %{})
        |> Map.get(spec.symbol, %{requires: [], tool_refs: []})

      backing = backing(spec, explicit_requires, transitive.requires)

      {:ok,
       %Export{
         ref: ref(spec.namespace, spec.symbol),
         namespace: spec.namespace,
         symbol: spec.symbol,
         arity: spec.arity,
         min_arity: min_arity(spec.arity, spec.params_form),
         doc: spec.doc,
         visibility: visibility,
         effect: backing.effect,
         provider_ref: backing.provider_ref,
         requires: backing.requires,
         tool_refs: transitive.tool_refs
       }}
    end
  end

  # Minimum args a call must supply. Fixed arity == its own value; a variadic
  # `[a b & rest]` requires its leading params (the count before `&`).
  defp min_arity(arity, _params) when is_integer(arity), do: arity

  defp min_arity(:variadic, {:vector, params}) do
    case Enum.find_index(params, &variadic_marker?/1) do
      nil -> 0
      idx -> idx
    end
  end

  defp min_arity(:variadic, _params), do: 0

  defp ref(namespace, symbol), do: "#{namespace}/#{symbol}"

  # ============================================================
  # Backing inference + explicit metadata (plan §3)
  # ============================================================

  # Explicit prelude metadata wins over inference. `provider_ref` is inferred
  # only from a single literal (tool/call {:server "x" :tool "y" ...}) in the
  # export's OWN body. `requires` is the export's TRANSITIVE set of literal
  # upstream ids — its own body plus the bodies of the same-namespace private
  # helpers it (transitively) calls — so an export that reaches an upstream
  # THROUGH a helper still carries the requirement (attach-time validation fails
  # closed) WITHOUT inheriting a sibling export's unrelated requirements.
  defp backing(%Spec{metadata: metadata, body_form: body}, explicit_requires, transitive_ids) do
    explicit_provider = Map.get(metadata, "provider-ref")
    explicit_effect = effect(Map.get(metadata, "effect"))

    inferred = infer_backing(body)

    provider_ref = explicit_provider || inferred.provider_ref
    requires = explicit_requires || transitive_ids

    effect =
      cond do
        explicit_effect != nil -> explicit_effect
        provider_ref != nil -> :read
        requires != [] -> :read
        true -> :unknown
      end

    %{provider_ref: provider_ref, requires: requires || [], effect: effect}
  end

  # `%{namespace => %{symbol => sorted upstream ids}}` where each symbol's id set
  # is its body's literal upstream ids UNIONED with those transitively reachable
  # through the same-namespace helpers it calls. This keeps a public export's
  # `requires` precise (it does not absorb a sibling export's requirements) while
  # still capturing helper-backed upstream operations.
  # `%{namespace => %{symbol => %{requires: [...], tool_refs: [...]}}}`. Both the
  # upstream `requires` ids AND the typed `tool_refs` names are computed PER
  # EXPORT and transitively over the same-namespace helpers it actually calls
  # (sharing one scope-aware call graph), so a pure export does NOT inherit a
  # sibling export's tools/requirements.
  defp namespace_backing(specs) do
    specs
    |> Enum.group_by(& &1.namespace)
    |> Map.new(fn {ns, ns_specs} -> {ns, transitive_backing(ns_specs)} end)
  end

  # Plain lists throughout (not MapSet) to avoid dialyzer opaque-type friction;
  # results are small (a namespace's symbol/id sets) so list dedup is cheap.
  defp transitive_backing(ns_specs) do
    direct_ids =
      Map.new(ns_specs, fn %Spec{symbol: sym, body_form: body} ->
        ids =
          body
          |> Enum.flat_map(&literal_tool_calls/1)
          |> Enum.map(fn {server, tool} -> "upstream:#{server}/#{tool}" end)
          |> Enum.uniq()

        {sym, ids}
      end)

    direct_tools =
      Map.new(ns_specs, fn %Spec{symbol: sym, body_form: body} ->
        {sym, body |> Enum.reduce([], &collect_tool_names_raw/2) |> Enum.uniq()}
      end)

    ns_symbols = Enum.map(ns_specs, & &1.symbol)

    calls =
      Map.new(ns_specs, fn %Spec{symbol: sym, params_form: params, body_form: body} ->
        refs =
          body
          |> Enum.reduce([], &collect_refs(&1, param_names(params), &2))
          |> Enum.uniq()
          |> Enum.filter(&(&1 in ns_symbols))

        {sym, refs}
      end)

    Map.new(ns_specs, fn %Spec{symbol: sym} ->
      {sym,
       %{
         requires: sym |> reachable_ids(direct_ids, calls, []) |> Enum.uniq() |> Enum.sort(),
         tool_refs: sym |> reachable_ids(direct_tools, calls, []) |> Enum.uniq() |> Enum.sort()
       }}
    end)
  end

  # Typed tool NAMES a raw body references via `tool/<name>` (in call-head or
  # value position), EXCLUDING the discovery form `tool/servers` (not a tool
  # call). Matches the names `check_undefined_tools` collects from the analyzed
  # AST.
  defp collect_tool_names_raw({:ns_symbol, :tool, name}, acc)
       when name not in [:servers, "servers"],
       do: [to_string(name) | acc]

  defp collect_tool_names_raw({:list, items}, acc) when is_list(items),
    do: Enum.reduce(items, acc, &collect_tool_names_raw/2)

  defp collect_tool_names_raw({:vector, items}, acc) when is_list(items),
    do: Enum.reduce(items, acc, &collect_tool_names_raw/2)

  defp collect_tool_names_raw({:map, pairs}, acc) when is_list(pairs),
    do:
      Enum.reduce(pairs, acc, fn {k, v}, a ->
        collect_tool_names_raw(v, collect_tool_names_raw(k, a))
      end)

  defp collect_tool_names_raw(_other, acc), do: acc

  # Upstream ids reachable from `sym`: its own plus those of every helper it
  # transitively calls. `visited` guards mutual-recursion cycles.
  defp reachable_ids(sym, direct, calls, visited) do
    if sym in visited do
      []
    else
      visited = [sym | visited]
      own = Map.get(direct, sym, [])

      Enum.reduce(Map.get(calls, sym, []), own, fn callee, acc ->
        acc ++ reachable_ids(callee, direct, calls, visited)
      end)
    end
  end

  # Scope-aware raw-AST collector of symbol references an export's body actually
  # USES (call heads and values passed to calls), used to build the
  # same-namespace call graph. It excludes locally-bound names — the def's params
  # plus `fn`/`let`/`loop` bindings — so a parameter or local that merely shares
  # a helper's name does NOT create a false requirement edge. Quoted symbols are
  # a distinct `:quoted_symbol` node and are ignored here. Non-sibling names are
  # filtered by the caller against the namespace's declared symbols.

  # (fn [params] body...) — params shadow within the body.
  defp collect_refs({:list, [{:symbol, fn_h}, {:vector, params} | body]}, bound, acc)
       when fn_h in [:fn, "fn"] do
    inner = bound ++ param_names({:vector, params})
    Enum.reduce(body, acc, &collect_refs(&1, inner, &2))
  end

  # (let [a v ...] body...) / (loop [...] body...) — bindings shadow.
  defp collect_refs({:list, [{:symbol, binder}, {:vector, bindings} | body]}, bound, acc)
       when binder in [:let, "let", :loop, "loop"] do
    {names, acc2} = collect_let_bindings(bindings, bound, acc)
    inner = bound ++ names
    Enum.reduce(body, acc2, &collect_refs(&1, inner, &2))
  end

  defp collect_refs({:list, items}, bound, acc) when is_list(items),
    do: Enum.reduce(items, acc, &collect_refs(&1, bound, &2))

  defp collect_refs({:vector, items}, bound, acc) when is_list(items),
    do: Enum.reduce(items, acc, &collect_refs(&1, bound, &2))

  defp collect_refs({:map, pairs}, bound, acc) when is_list(pairs),
    do:
      Enum.reduce(pairs, acc, fn {k, v}, a ->
        collect_refs(v, bound, collect_refs(k, bound, a))
      end)

  defp collect_refs({:symbol, name}, bound, acc) do
    s = to_string(name)
    if s in bound, do: acc, else: [s | acc]
  end

  defp collect_refs(_other, _bound, acc), do: acc

  # Walk `let`/`loop` binding pairs left-to-right: each value sees the names
  # bound before it; the accumulated names then shadow the body.
  defp collect_let_bindings(bindings, bound, acc) do
    bindings
    |> Enum.chunk_every(2)
    |> Enum.reduce({[], acc}, fn
      [name_form, val], {names, a} ->
        a2 = collect_refs(val, bound ++ names, a)
        {names ++ pattern_names(name_form), a2}

      [val], {names, a} ->
        {names, collect_refs(val, bound ++ names, a)}
    end)
  end

  defp param_names({:vector, params}), do: Enum.flat_map(params, &pattern_names/1)
  defp param_names(_), do: []

  # Names a binding pattern introduces (plain symbol or simple destructuring).
  defp pattern_names({:symbol, name}), do: [to_string(name)]
  defp pattern_names({:vector, items}), do: Enum.flat_map(items, &pattern_names/1)
  defp pattern_names({:map, pairs}), do: Enum.flat_map(pairs, fn {k, _v} -> pattern_names(k) end)
  defp pattern_names(_other), do: []

  # Look through the body forms for literal tool/calls with a string :server and
  # string :tool. A single literal yields a backing provider_ref; multiple
  # literals have no single provider but ALL their upstream ids are kept in
  # `requires` so attach-time validation checks every one (fail-closed) instead
  # of silently dropping them. Dynamic values yield :unknown.
  defp infer_backing(body) do
    case Enum.flat_map(body, &literal_tool_calls/1) do
      [] ->
        %{provider_ref: nil, requires: nil}

      [{server, tool}] ->
        id = "upstream:#{server}/#{tool}"
        %{provider_ref: id, requires: [id]}

      multiple ->
        ids =
          multiple
          |> Enum.map(fn {server, tool} -> "upstream:#{server}/#{tool}" end)
          |> Enum.uniq()
          |> Enum.sort()

        %{provider_ref: nil, requires: ids}
    end
  end

  # Recursively find literal tool/call forms. Returns {server, tool} only when
  # both are string literals.
  defp literal_tool_calls({:list, [{:ns_symbol, :tool, name} | args]})
       when name in ["call", :call] do
    case args do
      [{:map, pairs}] ->
        with {:ok, server} <- literal_string(meta_get(pairs, "server")),
             {:ok, tool} <- literal_string(meta_get(pairs, "tool")) do
          [{server, tool}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp literal_tool_calls({:list, items}) when is_list(items) do
    Enum.flat_map(items, &literal_tool_calls/1)
  end

  defp literal_tool_calls({:vector, items}) when is_list(items) do
    Enum.flat_map(items, &literal_tool_calls/1)
  end

  defp literal_tool_calls({:map, pairs}) when is_list(pairs) do
    Enum.flat_map(pairs, fn {k, v} ->
      literal_tool_calls(k) ++ literal_tool_calls(v)
    end)
  end

  defp literal_tool_calls(_), do: []

  defp literal_string({:string, s}) when is_binary(s), do: {:ok, s}
  defp literal_string(_), do: :error

  # In a tool/call map the :server key is string-keyed but :tool may intern as
  # an atom (it's in SourceAtoms @bounded_namespaces). Match both.
  defp meta_get(pairs, "server"), do: keyword_value(pairs, "server")
  defp meta_get(pairs, "tool"), do: keyword_value(pairs, "tool") || keyword_value(pairs, :tool)

  defp keyword_value(pairs, key) do
    Enum.find_value(pairs, fn
      {{:keyword, ^key}, value} -> value
      _ -> nil
    end)
  end

  # ============================================================
  # Metadata normalization (host boundary, plan §3)
  # ============================================================

  # Normalize a parsed metadata map's keyword keys to binary strings and
  # keyword values to atoms only for the small bounded set we interpret.
  # Everything stays string-backed except the curated enums.
  defp normalize_meta(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key_ast, value_ast}, {:ok, acc} ->
      case meta_key(key_ast) do
        {:ok, key} -> {:cont, {:ok, Map.put(acc, key, meta_value(value_ast))}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp meta_key({:keyword, k}) when is_binary(k), do: {:ok, k}
  defp meta_key({:keyword, k}) when is_atom(k), do: {:ok, Atom.to_string(k)}

  # A non-keyword metadata key (e.g. a string key `{"visibility" :prompt}`) is a
  # recoverable validation error, NOT a FunctionClauseError that crashes the
  # caller (Lisp.run(prelude: source) compiles directly).
  defp meta_key(other) do
    {:error,
     ValidationError.new(
       :invalid_metadata,
       "prelude metadata keys must be keywords, got: #{inspect(other, limit: 3)}"
     )}
  end

  defp meta_value({:keyword, v}) when is_binary(v), do: {:keyword, v}
  defp meta_value({:keyword, v}) when is_atom(v), do: {:keyword, Atom.to_string(v)}
  defp meta_value({:string, s}), do: s
  defp meta_value({:vector, elems}), do: Enum.map(elems, &meta_value/1)
  defp meta_value(other), do: other

  # Visibility value comes through as `{:keyword, "prompt"}` after normalize.
  defp visibility(nil), do: {:ok, @default_visibility}
  defp visibility(@default_visibility), do: {:ok, @default_visibility}
  defp visibility(:discoverable), do: {:ok, :discoverable}
  defp visibility({:keyword, "prompt"}), do: {:ok, :prompt}
  defp visibility({:keyword, "discoverable"}), do: {:ok, :discoverable}

  defp visibility({:keyword, other}) do
    {:error,
     ValidationError.new(
       :invalid_visibility,
       "invalid visibility `:#{other}` (expected :prompt or :discoverable)"
     )}
  end

  defp visibility(other) do
    {:error,
     ValidationError.new(
       :invalid_visibility,
       "invalid visibility #{inspect(other, limit: 3)} (expected :prompt or :discoverable)"
     )}
  end

  # Effect value (string-keyed keyword after normalize). Unknown effects are
  # ignored (fall back to inference) rather than rejected in V1.
  defp effect(nil), do: nil
  defp effect({:keyword, name}), do: effect_atom(name)
  defp effect(name) when is_binary(name), do: effect_atom(name)
  defp effect(_), do: nil

  defp effect_atom(name) do
    Enum.find(@valid_effects, fn e -> Atom.to_string(e) == name end)
  end

  # Explicit `:requires` metadata must be a list of canonical string ids. Invalid
  # entries FAIL compilation (plan §10: bad export metadata fails fast at load
  # time) rather than being silently dropped — a silently-emptied `requires`
  # would skip attach-time validation and hide a missing/typo'd backing id.
  defp validate_requires(nil), do: {:ok, nil}

  defp validate_requires(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      {:ok, list}
    else
      bad = Enum.reject(list, &is_binary/1)

      {:error,
       ValidationError.new(
         :invalid_requires,
         "prelude :requires must be a list of strings; invalid entries: #{inspect(bad, limit: 5)}"
       )}
    end
  end

  defp validate_requires(other) do
    {:error,
     ValidationError.new(
       :invalid_requires,
       "prelude :requires must be a list of strings, got: #{inspect(other, limit: 5)}"
     )}
  end

  # ============================================================
  # Private env capture (fact #6)
  # ============================================================

  # Build the captured runtime tables, namespace by namespace. Each namespace is
  # analyzed + evaluated IN ISOLATION so that same-named definitions in different
  # namespaces stay distinct (e.g. `crm/who` vs `hr/who`) and a helper resolves
  # only its own namespace's siblings. Returns the per-namespace private env
  # (`%{ns => %{symbol => callable}}`) plus a `%{ref => [tool]}` map of the
  # typed tools each export invokes (used by the pre-execution tool guard).
  #
  # Each spec becomes a plain `(defn symbol [params] body...)` (or `(def ...)`
  # for constants) — ns directives stripped, `defn-` downgraded to `defn` so the
  # existing analyzer accepts it — then run through the standard analyze+eval
  # pipeline.
  defp build_runtime(specs) do
    specs
    |> Enum.group_by(& &1.namespace)
    |> Enum.reduce_while({:ok, %{}}, fn {ns, ns_specs}, {:ok, env_acc} ->
      program = {:program, Enum.map(ns_specs, &spec_to_defn_form/1)}

      with {:ok, core} <- analyze(program),
           {:ok, env} <- eval_runtime(core) do
        {:cont, {:ok, Map.put(env_acc, ns, env)}}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # A (def ...) constant: params_form is nil.
  defp spec_to_defn_form(%Spec{params_form: nil, body_form: [value_ast]} = spec) do
    {:list, [{:symbol, :def}, {:symbol, spec.symbol}, value_ast]}
  end

  # A (defn ...) function: reuse the ORIGINAL params vector and body forms so
  # the captured closure's bound variables match the source exactly.
  defp spec_to_defn_form(%Spec{} = spec) do
    {:list, [{:symbol, :defn}, {:symbol, spec.symbol}, spec.params_form | spec.body_form]}
  end

  defp analyze(program) do
    case Analyze.analyze(program) do
      {:ok, core} ->
        {:ok, core}

      {:error, reason} ->
        {:error,
         ValidationError.new(
           :compile_error,
           "prelude analysis failed: #{inspect(reason, limit: 6)}"
         )}
    end
  end

  defp eval_runtime(core) do
    # Stateless prelude compilation: a no-op tool executor. `defn` bodies only
    # bind closures, but a top-level `(def x <expr>)` constant's value IS
    # evaluated here, so run under the bounded sandbox (timeout + max_heap) — an
    # expensive or huge constant expression fails RECOVERABLY instead of hanging
    # or exhausting memory in the caller process.
    tool_exec = fn _name, _args -> nil end

    bounded =
      Sandbox.run_bounded(fn ->
        Eval.eval(core, %{}, %{}, Env.initial(), tool_exec, [], [])
      end)

    case bounded do
      {:ok, {:ok, _result, user_ns}} ->
        {:ok, user_ns}

      {:ok, {:error, reason}} ->
        {:error,
         ValidationError.new(
           :compile_error,
           "prelude evaluation failed: #{inspect(reason, limit: 6)}"
         )}

      {:error, sandbox_reason} ->
        {:error,
         ValidationError.new(
           :compile_error,
           "prelude evaluation exceeded sandbox limits: #{inspect(sandbox_reason)}"
         )}
    end
  end

  # ============================================================
  # Source hash (plan §12)
  # ============================================================

  defp source_hash(source) do
    :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
  end
end
