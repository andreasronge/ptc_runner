defmodule PtcRunner.Lisp.Prelude.CompilerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude
  alias PtcRunner.Lisp.Prelude.Compiler
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
  end

  # ============================================================
  # requires / backing inference
  # ============================================================

  describe "compile/1 backing inference" do
    test "literal tool/call infers a requires/provider_ref backing id" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn get-user
        "Return a CRM user by id."
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports

      assert export.requires == ["upstream:crm/get_user"]
      assert export.provider_ref == "upstream:crm/get_user"
      assert export.effect == :read
    end

    test "dynamic server/tool yields :unknown effect and no requires" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn proxy
        "Dynamic call."
        [server tool]
        (tool/call {:server server :tool tool :args {}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports

      assert export.effect == :unknown
      assert export.requires == []
      assert export.provider_ref == nil
    end

    test "explicit prelude metadata overrides inferred backing" do
      source = """
      (ns crm "CRM helpers." {:visibility :prompt})

      (defn get-user
        "Return a CRM user by id."
        {:provider-ref "upstream:crm/get_user" :effect :read :requires ["upstream:crm/get_user"]}
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports

      assert export.provider_ref == "upstream:crm/get_user"
      assert export.requires == ["upstream:crm/get_user"]
      assert export.effect == :read
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
  # Rejections
  # ============================================================

  describe "compile/1 rejections" do
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
    test "kebab-case :provider-ref keyword normalizes to a string-backed field" do
      source = """
      (ns crm "doc" {:visibility :prompt})
      (defn get-user
        "doc"
        {:provider-ref "upstream:crm/get_user" :effect :read}
        [id]
        (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
      """

      {:ok, prelude} = Compiler.compile(source)
      [export] = prelude.exports
      assert export.provider_ref == "upstream:crm/get_user"
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
end
