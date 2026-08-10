defmodule PtcRunner.Lisp.Prelude.CompilerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.ErrorSpan
  alias PtcRunner.Lisp.Prelude.Export

  # ============================================================
  # Happy path
  # ============================================================

  describe "compile/1 happy path" do
    setup do
      source = """
      (ns crm
        "CRM helpers."
        {:visibility :prompt})

      (defn get-user
        "Return a CRM user by id."
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      %{prelude: prelude, source: source}
    end

    test "returns a compiled %Prelude{} artifact", %{prelude: prelude} do
      assert %Prelude{} = prelude
    end

    test "declared namespace is recorded", %{prelude: prelude} do
      assert "crm" in Prelude.namespaces(prelude)
    end

    test "public export record carries ref/namespace/symbol/arity/params/doc", %{prelude: prelude} do
      assert [%Export{} = export] = prelude.exports
      assert export.ref == "crm/get-user"
      assert export.namespace == "crm"
      assert export.symbol == "get-user"
      assert export.arity == 1
      assert export.params == ["id"]
      assert export.doc == "Return a CRM user by id."
      assert export.visibility == :prompt
    end

    test "namespace-default visibility flows into the export", %{prelude: prelude} do
      [export] = prelude.exports
      assert export.visibility == :prompt
    end

    test "source hash is a stable lowercase hex digest", %{prelude: prelude, source: source} do
      assert is_binary(prelude.source_hash)
      assert prelude.source_hash =~ ~r/\A[0-9a-f]{64}\z/

      {:ok, again} = Compiler.compile(source)
      assert again.source_hash == prelude.source_hash
    end

    test "captured private env holds a callable closure for the export", %{prelude: prelude} do
      [export] = prelude.exports
      # private_env is namespace-scoped: %{namespace => %{symbol => callable}}.
      assert is_map(prelude.private_env)
      ns_env = prelude.private_env[export.namespace]
      assert is_map(ns_env)
      assert Map.has_key?(ns_env, export.symbol)
      # defn closures are represented as a {:closure, ...} tuple captured over
      # the private prelude env (the contract P2 invokes).
      assert match?(
               {:closure, _params, _body, _env, _th, _meta},
               ns_env[export.symbol]
             )
    end

    test "ref keeps the curated kebab-case Lisp spelling", %{prelude: prelude} do
      [export] = prelude.exports
      assert export.symbol == "get-user"
      refute export.symbol =~ "_"
    end

    test "allows qualified prelude exports whose bare name is a built-in at runtime" do
      source = """
      (ns prelude "Prelude helpers." {:visibility :prompt})
      (defn list "List items." [] "prelude-list")
      (defn call-list "Call list." [] (list))
      """

      assert {:ok, prelude} = Compiler.compile(source)

      assert Enum.map(prelude.exports, & &1.ref) == ~w(prelude/list prelude/call-list)
      assert {:ok, %{return: "prelude-list"}} = Lisp.run("(prelude/list)", prelude: prelude)
      assert {:ok, %{return: "prelude-list"}} = Lisp.run("(prelude/call-list)", prelude: prelude)
    end
  end

  # ============================================================
  # tool requirement inference
  # ============================================================

  describe "compile/1 tool requirement inference" do
    test "tool/call records the generic tool requirement" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn get-user
        "Return a CRM user by id."
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports

      assert export.requires == ["tool:call"]
      assert export.effect == :read
    end

    test "dynamic arguments do not change the named tool requirement" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn proxy
        "Dynamic call."
        [server tool]
        (tool/call {:server server :tool tool :args {}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports

      assert export.effect == :read
      assert export.requires == ["tool:call"]
    end

    test "explicit metadata adds requirements and overrides effect" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn get-user
        "Return a CRM user by id."
        {:effect :write :requires ["tool:audit"]}
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports

      assert export.requires == ["tool:audit", "tool:call"]
      assert export.effect == :write
      assert export.declared_effect == :write
    end
  end

  # ============================================================
  # Visibility
  # ============================================================

  describe "compile/1 visibility" do
    test "export-level :discoverable visibility overrides namespace default" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn get-user
        "Return a CRM user by id."
        {:visibility :discoverable}
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports
      assert export.visibility == :discoverable
    end

    test "rejects an invalid visibility value" do
      source = """
      (ns crm "CRM helpers." {:visibility :loud})

      (defn get-user "doc" [id] (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_visibility
      assert err.message =~ "loud"
    end
  end

  # ============================================================
  # Private helpers (defn-)
  # ============================================================

  describe "compile/1 private helpers" do
    setup do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn- normalize-user
        [u]
        u)

      (defn get-user
        "Return a CRM user by id."
        [id]
        (normalize-user (tool/call {:server "crm" :tool "get_user" :args {:id id}})))
      """

      {:ok, prelude} = Compiler.compile(source)
      %{prelude: prelude}
    end

    test "private helper produces no public export record", %{prelude: prelude} do
      refs = Enum.map(prelude.exports, & &1.ref)
      assert refs == ["crm/get-user"]
      refute "crm/normalize-user" in refs
    end

    test "private helper closure lives in the captured private env", %{prelude: prelude} do
      crm_env = prelude.private_env["crm"]
      assert Map.has_key?(crm_env, "normalize-user")
      assert match?({:closure, _, _, _, _, _}, crm_env["normalize-user"])
    end
  end

  # ============================================================
  # form_graph (prelude form-edit/introspection plan, Phase 1)
  # ============================================================

  describe "compile/1 form_graph" do
    setup do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn- fetch-raw
        "Fetch the raw user record."
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))

      (defn get-user
        "Return a CRM user by id."
        [id]
        (fetch-raw id))

      (defn- unused-helper
        "Never called by anything."
        []
        42)

      (def max-retries "Retry budget." 3)
      """

      {:ok, prelude} = Compiler.compile(source)
      %{prelude: prelude, graph: prelude.form_graph["crm"]}
    end

    test "public function entry carries visibility/kind/arity/doc/calls", %{graph: graph} do
      entry = graph["get-user"]
      assert entry.visibility == :public
      assert entry.kind == :function
      assert entry.arity == 1
      assert entry.doc == "Return a CRM user by id."
      assert entry.calls == ["fetch-raw"]
    end

    test "private helper entry is present even though it has no public export", %{graph: graph} do
      entry = graph["fetch-raw"]
      assert entry.visibility == :private
      assert entry.kind == :function
    end

    test "a def constant is kind :constant with arity 0", %{graph: graph} do
      entry = graph["max-retries"]
      assert entry.kind == :constant
      assert entry.arity == 0
      assert entry.doc == "Retry budget."
      assert entry.calls == []
    end

    test "direct requires/tool_refs cover only the form's own body", %{graph: graph} do
      helper = graph["fetch-raw"]
      assert helper.requires.direct == ["tool:call"]
      assert helper.tool_refs.direct == ["call"]

      export = graph["get-user"]
      assert export.requires.direct == []
      assert export.tool_refs.direct == []
    end

    test "transitive requires/tool_refs widen through a called private helper and match the resolved export",
         %{prelude: prelude, graph: graph} do
      entry = graph["get-user"]
      export = Enum.find(prelude.exports, &(&1.ref == "crm/get-user"))

      assert entry.requires.transitive == ["tool:call"]
      assert entry.tool_refs.transitive == ["call"]
      assert export.requires == ["tool:call"]
      assert export.tool_refs == ["call"]
    end

    test "an unreferenced ('dead') private still appears in the graph", %{graph: graph} do
      assert Map.has_key?(graph, "unused-helper")
      assert graph["unused-helper"].calls == []
    end
  end

  # ============================================================
  # Rejections
  # ============================================================

  describe "compile/1 rejections" do
    test "rejects duplicate signature parameter names" do
      source = """
      (ns crm "doc" {:visibility :prompt})
      (defn find {:signature "(query :string, query :int) -> :string"} [left right] left)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_signature
      assert err.message =~ "duplicate"
      assert err.message =~ "query"
    end

    test "rejects signatures on variadic definitions explicitly" do
      source = """
      (ns crm "doc" {:visibility :prompt})
      (defn find {:signature "(query :string) -> :string"} [query & rest] query)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_signature
      assert err.message =~ "fixed-arity"
    end

    test "rejects normalized shaped-map field collisions" do
      source = """
      (ns crm "doc" {:visibility :prompt})
      (defn find
        {:signature "(input {user-id :string, user_id :int}) -> :string"}
        [input]
        "ok")
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_signature
      assert err.message =~ "duplicate"
      assert err.message =~ "user_id"
    end

    test "rejects a public constant whose value violates its type" do
      source = """
      (ns cfg "doc" {:visibility :prompt})
      (def answer {:type ":int"} "forty-two")
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_signature
      assert err.message =~ "cfg/answer"
      assert err.message =~ "expected int"
    end

    test "bounds diagnostics for a constant with many invalid elements" do
      values = Enum.map_join(0..99, " ", &~s|"bad#{&1}"|)

      assert {:error, %Prelude.ValidationError{} = err} =
               Compiler.compile("""
               (ns api)
               (def values {:type "[:int]"} [#{values}])
               """)

      assert err.reason == :invalid_signature
      assert err.message =~ "0: expected int"
      assert err.message =~ "15: expected int"
      refute err.message =~ "16: expected int"
      assert byte_size(err.message) <= 4_096
    end

    test "bounds a constant diagnostic containing a very long contract path" do
      field = String.duplicate("a", 5_000)

      assert {:error, %Prelude.ValidationError{} = err} =
               Compiler.compile("""
               (ns api)
               (def value {:type "{#{field} :int}"} {})
               """)

      assert err.reason == :invalid_signature
      assert byte_size(err.message) == 4_096
      assert String.valid?(err.message)
    end

    test "rejects function-style signatures used as constant types without crashing" do
      source = """
      (ns cfg "Config")
      (def answer {:type "(value :int) -> :int"} 42)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_signature
      assert err.message =~ "constant :type"
      assert err.message =~ "parameters"
    end

    test "rejects strings, nil, and boolean constants declared as keywords" do
      for value <- [~S|"plain"|, "nil", "true", "false"] do
        source = """
        (ns cfg "Config")
        (def answer {:type ":keyword"} #{value})
        """

        assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
        assert err.reason == :invalid_signature
        assert err.message =~ "expected keyword"
      end
    end

    test "rejects invalid effect metadata" do
      source = """
      (ns crm "doc" {:visibility :prompt})
      (defn find {:effect :maybe} [query] query)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_metadata
      assert err.message =~ "effect"
    end

    test "rejects invalid effect metadata on private helpers" do
      source = """
      (ns crm "doc" {:visibility :prompt})
      (defn- find {:effect :maybe} [query] query)
      (defn run [query] (find query))
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_metadata
      assert err.message =~ "effect"
    end

    test "rejects declaring a reserved namespace (tool)" do
      source = """
      (ns tool "nope" {:visibility :prompt})
      (defn evil [x] x)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :reserved_namespace
      assert err.message =~ "tool"
    end

    test "rejects declaring a reserved namespace (data)" do
      source = """
      (ns data "nope" {:visibility :prompt})
      (defn evil [x] x)
      """

      assert {:error, %Prelude.ValidationError{reason: :reserved_namespace}} =
               Compiler.compile(source)
    end

    test "rejects declaring a reserved namespace (ptc.core)" do
      source = """
      (ns ptc.core "nope" {:visibility :prompt})
      (defn evil [x] x)
      """

      assert {:error, %Prelude.ValidationError{reason: :reserved_namespace}} =
               Compiler.compile(source)
    end

    test "rejects namespaces that shadow Java class spellings" do
      for namespace <- ["Boolean", "java.lang.Boolean", "java.util.Date."] do
        source = """
        (ns #{namespace} "nope" {:visibility :prompt})
        (defn parseBoolean [x] x)
        """

        assert {:error, %Prelude.ValidationError{reason: :reserved_namespace}} =
                 Compiler.compile(source)
      end
    end

    test "rejects duplicate export refs" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})
      (defn get-user "first" [id] id)
      (defn get-user "second" [id] id)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :duplicate_ref
      assert err.message =~ "crm/get-user"
    end

    test "rejects a defn appearing before any (ns ...) directive" do
      source = """
      (defn orphan [x] x)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :missing_namespace
    end

    test "rejects a non-symbol namespace name" do
      source = """
      (ns "crm" "doc" {:visibility :prompt})
      (defn get-user "doc" [id] id)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason == :invalid_namespace
    end

    test "rejects invalid arity/signature metadata (non-vector params)" do
      source = """
      (ns crm "doc" {:visibility :prompt})
      (defn get-user "doc" id id)
      """

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason in [:invalid_signature, :compile_error]
    end

    test "rejects parse errors with a compile_error validation result" do
      source = "(ns crm \"doc\" {:visibility :prompt}) (defn get-user [id"

      assert {:error, %Prelude.ValidationError{} = err} = Compiler.compile(source)
      assert err.reason in [:parse_error, :compile_error]
    end
  end

  # ============================================================
  # Metadata normalization at the host boundary
  # ============================================================

  describe "compile/1 metadata normalization" do
    test "kebab-case :requires values remain string-backed" do
      source = """
      (ns crm "doc" {:visibility :prompt})
      (defn get-user
        "doc"
        {:requires ["tool:audit"] :effect :read}
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports
      assert export.requires == ["tool:audit", "tool:call"]
      # host boundary stays string-backed; refs/namespace/symbol are strings.
      assert is_binary(export.ref)
      assert is_binary(export.namespace)
      assert is_binary(export.symbol)
    end
  end

  # ============================================================
  # Fail-closed raw-AST guard (issue #1095 hardening)
  # ============================================================

  describe "leaf_node?/1 classifies the canonical raw-AST node set" do
    test "every terminal node (and scalar) is a leaf — these never false-close" do
      terminals = [
        {:string, "s"},
        {:keyword, "k"},
        {:symbol, "x"},
        {:ns_symbol, "crm", "get-user"},
        {:quoted_symbol, "flag"},
        {:regex_literal, "a+"},
        {:var, "inc"},
        {:turn_history, 1},
        42,
        1.5,
        true,
        false,
        nil,
        :infinity,
        :negative_infinity,
        :nan
      ]

      for node <- terminals do
        assert Compiler.leaf_node?(node), "expected #{inspect(node)} to be a leaf"
      end
    end

    test "containers and any unrecognized tagged node are NOT leaves (descend or fail closed)" do
      for node <- [
            {:list, []},
            {:vector, []},
            {:map, []},
            {:set, []},
            {:short_fn, []},
            # A hypothetical future parser node: absent from @leaf_tags by
            # construction, so the inference walkers fail closed on it.
            {:future_reader_macro, "x"}
          ] do
        refute Compiler.leaf_node?(node), "expected #{inspect(node)} to be a non-leaf"
      end
    end
  end

  # ============================================================
  # Declared prelude-to-prelude dependencies
  # ============================================================

  describe "compile/2 declared dependencies" do
    @dep_base_source """
    (ns base "Shared helpers.")

    (defn- normalize [x] (str "n:" x))

    (defn helper
      "Normalize and tag one value."
      [x]
      (str "helper:" (normalize x)))

    (defn fetch
      "Wrapped tool fetch."
      [id]
      (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
    """

    defp dep_base do
      {:ok, base} = Compiler.compile(@dep_base_source)
      base
    end

    defp compile_audit(body, opts \\ []) do
      source = """
      (ns audit "Audit checks.")
      #{body}
      """

      Compiler.compile(
        source,
        Keyword.merge([deps: [dep_base()], namespace_deps: %{"audit" => ["base"]}], opts)
      )
    end

    test "qualified call into a declared external dep compiles; dep namespaces stay external" do
      assert {:ok, prelude} = compile_audit("(defn check [x] (base/helper x))")
      assert Prelude.namespaces(prelude) == ["audit"]
      assert [%Export{ref: "audit/check"}] = prelude.exports
    end

    test "dep call unions the dep export's requires and tool_refs (call position)" do
      assert {:ok, prelude} = compile_audit("(defn check [id] (base/fetch id))")
      [%Export{} = check] = prelude.exports
      assert "tool:call" in check.requires
      assert "call" in check.tool_refs
    end

    test "value-position dep ref unions authority too" do
      assert {:ok, prelude} = compile_audit("(defn check-all [ids] (map base/fetch ids))")
      [%Export{} = check] = prelude.exports
      assert "tool:call" in check.requires
      assert "call" in check.tool_refs
    end

    test "short-fn dep ref unions authority (walker container coverage)" do
      assert {:ok, prelude} = compile_audit("(defn check-all [ids] (map #(base/fetch %) ids))")
      [%Export{} = check] = prelude.exports
      assert "tool:call" in check.requires
    end

    test "union flows through the dependent's own private helpers" do
      body = """
      (defn- inner [id] (base/fetch id))

      (defn check [id] (inner id))
      """

      assert {:ok, prelude} = compile_audit(body)
      [%Export{ref: "audit/check"} = check] = prelude.exports
      assert "tool:call" in check.requires
    end

    test "form_graph records dep_calls as full-ref strings" do
      assert {:ok, prelude} = compile_audit("(defn check [x] (base/helper x))")
      entry = prelude.form_graph["audit"]["check"]
      assert entry.dep_calls.direct == ["base/helper"]
      assert entry.dep_calls.transitive == ["base/helper"]
    end

    test "wrong arity on a dep call is rejected precisely" do
      assert {:error, error} = compile_audit("(defn check [x] (base/helper x x x))")
      assert error.message =~ "base/helper expects 1 argument(s), got 3"
    end

    test "a dep's defn- private is not reachable across preludes" do
      assert {:error, error} = compile_audit("(defn check [x] (base/normalize x))")
      assert error.message =~ "not a public export"
    end

    test "an undeclared namespace keeps failing with a requires_preludes hint" do
      source = """
      (ns audit "Audit checks.")
      (defn check [x] (base/helper x))
      """

      # Without any dep opts, and with deps supplied but NOT declared: both fail.
      for opts <- [[], [deps: [dep_base()]]] do
        assert {:error, error} = Compiler.compile(source, opts)
        assert error.reason == :compile_error
        assert error.message =~ "unknown namespace"
        assert error.message =~ "requires_preludes"
      end
    end

    test "dep references in def initializers are rejected fail-closed" do
      for body <- [
            ~s{(def cfg (base/helper "x"))},
            ~s{(def f base/helper)},
            ~s{(def g (fn [x] (base/helper x)))},
            ~s{(def h #(base/helper %))}
          ] do
        assert {:error, error} = compile_audit(body), "expected rejection for #{body}"
        assert error.reason == :dep_ref_in_def
        assert error.message =~ "base/helper"
        assert error.message =~ "defn"
      end
    end

    test "quoted dep symbols are data, not references" do
      assert {:ok, _} = compile_audit("(def cfg (quote base/helper))")
    end

    test "sibling namespaces compile with progressive scope in both source orders" do
      audit_ns = """
      (ns audit "Audit checks.")
      (defn check [id] (base/fetch id))
      """

      for source <- [@dep_base_source <> audit_ns, audit_ns <> @dep_base_source] do
        assert {:ok, prelude} =
                 Compiler.compile(source, namespace_deps: %{"audit" => ["base"]})

        assert Prelude.namespaces(prelude) == ["audit", "base"]
        {:ok, check} = Prelude.fetch_export(prelude, "audit/check")
        assert "tool:call" in check.requires
        assert "call" in check.tool_refs
      end
    end

    test "compiled sibling dep calls run end-to-end (pure runtime smoke)" do
      audit_ns = """
      (ns audit "Audit checks.")
      (defn check [x] (base/helper x))
      """

      assert {:ok, prelude} =
               Compiler.compile(audit_ns <> @dep_base_source,
                 namespace_deps: %{"audit" => ["base"]}
               )

      assert {:ok, step} =
               Lisp.run(~s{(audit/check "v")},
                 prelude: prelude,
                 tools: %{"call" => fn _ -> nil end}
               )

      assert step.return == "helper:n:v"
    end

    test "dependency cycles fail closed" do
      source = """
      (ns a "A.")
      (defn fa [x] x)
      (ns b "B.")
      (defn fb [x] x)
      """

      assert {:error, error} =
               Compiler.compile(source, namespace_deps: %{"a" => ["b"], "b" => ["a"]})

      assert error.reason == :dependency_cycle

      assert {:error, self_error} =
               Compiler.compile(source, namespace_deps: %{"a" => ["a"]})

      assert self_error.reason == :dependency_cycle
    end

    test "a declared dep that is neither external nor sibling is unknown" do
      source = """
      (ns audit "Audit checks.")
      (defn check [x] x)
      """

      assert {:error, error} = Compiler.compile(source, namespace_deps: %{"audit" => ["nope"]})
      assert error.reason == :unknown_dependency
      assert error.message =~ "nope"
    end

    test "a dep namespace provided both externally and as a sibling fails closed" do
      source = """
      (ns base "Shadow.")
      (defn helper [x] x)
      (ns audit "Audit checks.")
      (defn check [x] (base/helper x))
      """

      assert {:error, error} =
               Compiler.compile(source,
                 deps: [dep_base()],
                 namespace_deps: %{"audit" => ["base"]}
               )

      assert error.message =~ "provided both"
    end
  end

  # ============================================================
  # Failure spans
  # ============================================================

  describe "compile/2 failure spans" do
    # The oracle everywhere below is the SLICE, never the offsets: a span is
    # only useful if cutting the source at it yields the form a reader should
    # be looking at.
    defp failing_slice(source, opts \\ []) do
      assert {:error, %Prelude.ValidationError{} = error} = Compiler.compile(source, opts)
      {offset, length} = error.span
      {error, binary_part(source, offset, length)}
    end

    test "a failure raised while walking a top-level form spans that form" do
      source = """
      (ns crm "doc")

      (defn fine [x] x)

      (defn broken)
      """

      assert {error, slice} = failing_slice(source)
      assert error.reason == :invalid_signature
      assert slice == "(defn broken)"
    end

    test "post-walk export validation spans the offending definition" do
      cases = [
        {~S|(defn bad {:effect :network} [] 1)|, :invalid_metadata},
        {~S|(defn bad {:requires ["not-a-tool"]} [] 1)|, :invalid_requires},
        {~S|(defn bad {:signature "[:int -> :int]"} [] 1)|, :invalid_signature}
      ]

      for {definition, reason} <- cases do
        source = "(ns crm \"doc\")\n(defn fine [] 1)\n#{definition}\n"

        assert {error, slice} = failing_slice(source)
        assert error.reason == reason
        assert slice == definition
      end
    end

    test "the bundle-facing compile path retains a locator without resolving it" do
      source = "(ns crm \"doc\")\n(defn fine [] 1)\n(defn broken)\n"

      assert {:error, %Prelude.ValidationError{} = error} =
               Compiler.compile_unlocated(source)

      assert error.form_index == 2
      assert error.span == nil
    end

    test "a failure raised after the walk spans the definition its ref names" do
      source = """
      (ns cfg "doc")
      (def fine 1)
      (def answer {:type ":int"} "forty-two")
      """

      assert {error, slice} = failing_slice(source)
      assert error.ref == "cfg/answer"
      assert slice == ~S[(def answer {:type ":int"} "forty-two")]
    end

    test "a namespace-level failure spans the declaring (ns ...) form" do
      source = """
      (ns first-ns "doc")
      (defn a [] 1)
      (ns crm "doc")
      (defn b [] 2)
      """

      assert {error, slice} = failing_slice(source, namespace_deps: %{"crm" => ["missing"]})
      assert error.reason == :unknown_dependency
      assert slice == ~S[(ns crm "doc")]
    end

    test "a parse error carries no span, because no form can be blamed" do
      unbalanced = "(ns crm \"doc\") (defn a [] (+ 1)"

      assert {:error, %Prelude.ValidationError{} = error} = Compiler.compile(unbalanced)

      assert error.reason == :parse_error
      assert error.span == nil
    end

    test "a duplicate definition spans the redefinition that collided" do
      source = """
      (ns crm "doc")
      (defn a [] 1)
      (defn a [] 2)
      """

      assert {error, slice} = failing_slice(source)
      assert error.reason == :duplicate_ref
      assert slice == "(defn a [] 2)"
    end

    test "an ambiguous ref resolves to no span rather than an innocent namesake" do
      # `dep_ref_in_def` is raised BEFORE duplicate names are rejected, so its
      # ref matches two forms here and only the second one is at fault. A span
      # on the first would send a reader to code that is not the problem.
      source = """
      (ns audit "doc")
      (def a 1)
      (def a (base/helper 1))
      """

      assert {:error, %Prelude.ValidationError{} = error} =
               Compiler.compile(source,
                 deps: [dep_base()],
                 namespace_deps: %{"audit" => ["base"]}
               )

      assert error.reason == :dep_ref_in_def
      assert error.ref == "audit/a"
      assert error.span == nil
    end

    test "a negative form index resolves to no span rather than the last form" do
      source = """
      (ns crm "doc")
      (defn a [] 1)
      """

      error = %Prelude.ValidationError{
        reason: :compile_error,
        message: "synthetic",
        form_index: -1
      }

      assert ErrorSpan.resolve(error, source).span == nil
    end

    test "a successful compile is unaffected by span resolution" do
      assert {:ok, %Prelude{}} = Compiler.compile("(ns crm \"doc\") (defn a [] 1)")
    end
  end
end
