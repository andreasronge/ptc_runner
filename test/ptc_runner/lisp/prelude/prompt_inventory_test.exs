defmodule PtcRunner.Lisp.Prelude.PromptInventoryTest do
  @moduledoc """
  P5 (plan §9): the deterministic, bounded prompt-inventory renderer.

  The renderer is fed by the SAME `%Export{}` records the analyzer, evaluator,
  and discovery forms consult — no separate registry. It emits prompt-visible
  namespace summaries, prompt-visible export names + short docs + signature,
  effect hints, a discovery hint for omitted `:discoverable` exports, and a
  compact existing-ledger summary. Per-namespace export rendering is capped
  (~5) with a "more via (ns-publics 'ns)" hint; the cap is PINNED here.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.Lisp.Prelude.PromptInventory

  @crm_source """
  (ns crm
    "CRM helpers."
    {:visibility :prompt})

  (defn- normalize-id
    "Trim and lowercase a raw id."
    [raw]
    (str "norm:" raw))

  (defn get-user
    "Return a CRM user by id."
    [id]
    (tool/call {:server "crm" :tool "get_user" :args {:id (normalize-id id)}}))

  (defn list-users
    "List CRM users."
    {:visibility :discoverable}
    []
    (tool/call {:server "crm" :tool "list_users" :args {}}))
  """

  setup do
    {:ok, prelude} = Compiler.compile(@crm_source)
    %{prelude: prelude}
  end

  describe "render/2" do
    test "emits a compact :prompt entry for crm/get-user", %{prelude: prelude} do
      out = PromptInventory.render(prelude)

      assert is_binary(out)
      # The prompt-visible export name with its signature.
      assert out =~ "crm/get-user"
      assert out =~ "(get-user id)"
      # Its short doc.
      assert out =~ "Return a CRM user by id."
      # Its resolved effect hint (literal tool/call inference -> :read).
      assert out =~ "read"
    end

    test "renders the [read] hint but omits [unknown]" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns mix
          "Mixed effects."
          {:visibility :prompt})

        (defn fetch
          "Reads upstream."
          [id]
          (tool/call {:server "svc" :tool "get" :args {:id id}}))

        (defn area
          "Pure local computation."
          [w h]
          (* w h))
        """)

      out = PromptInventory.render(prelude)

      # The inferred-read export keeps its hint...
      assert out =~ "mix/fetch"
      assert out =~ "(fetch id)"
      assert out =~ "[read]"
      # ...but the pure (:unknown) export renders no effect bracket.
      assert out =~ "mix/area"
      assert out =~ "(area w h)"
      refute out =~ "[unknown]"
    end

    test "renders required params before the variadic marker" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns mix "Mixed exports." {:visibility :prompt})

        (defn foo
          "Join values."
          [a b & rest]
          (str a b rest))
        """)

      out = PromptInventory.render(prelude)

      assert out =~ "(foo a b & rest)"
      refute out =~ "(foo & args)"
    end

    test "falls back to synthetic names for destructuring params" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns mix "Mixed exports." {:visibility :prompt})

        (defn pull
          "Pull from a map."
          [{:keys [id]}]
          id)
        """)

      assert PromptInventory.render(prelude) =~ "(pull arg1)"
    end

    test "renders a namespace summary with the namespace docstring", %{prelude: prelude} do
      out = PromptInventory.render(prelude)
      assert out =~ "crm"
      assert out =~ "CRM helpers."
    end

    test "omits the :discoverable export detail but hints discovery", %{prelude: prelude} do
      out = PromptInventory.render(prelude)

      # The :discoverable export (list-users) is NOT detailed in the inventory.
      refute out =~ "List CRM users."
      # But the inventory hints that more is discoverable via ns-publics/doc.
      assert out =~ "ns-publics"
      # ...and that `source` renders an export's defining form (issue #1095).
      assert out =~ "(source 'ns/name)"
    end

    test "the private helper never appears", %{prelude: prelude} do
      out = PromptInventory.render(prelude)
      refute out =~ "normalize-id"
    end

    test "renders a compact ledger summary when provided", %{prelude: prelude} do
      out = PromptInventory.render(prelude, ledger: %{tool_calls: 3, tool_errors: 1})

      assert out =~ "Tool calls made: 3"
      assert out =~ "Tool call errors: 1"
    end

    test "accepts a raw tool_calls list and counts errors", %{prelude: prelude} do
      tool_calls = [
        %{name: "call", error: nil},
        %{name: "call", error: "boom"},
        %{name: "call", error: nil}
      ]

      out = PromptInventory.render(prelude, ledger: tool_calls)

      assert out =~ "Tool calls made: 3"
      assert out =~ "Tool call errors: 1"
    end

    test "no ledger summary when not provided", %{prelude: prelude} do
      out = PromptInventory.render(prelude)
      refute out =~ "Tool calls made:"
    end

    test "renders nil for an absent prelude" do
      assert PromptInventory.render(nil) == nil
    end

    test "renders nil when there are no prompt-visible exports" do
      source = """
      (ns hidden "Hidden ns." {:visibility :discoverable})
      (defn only-discoverable "Hidden export." [] 1)
      """

      {:ok, prelude} = Compiler.compile(source)
      # No :prompt exports -> nothing to render in the prompt inventory.
      assert PromptInventory.render(prelude) == nil
    end
  end

  describe "per-namespace export cap is bounded and pinned" do
    test "caps the rendered exports at ~5 and adds a 'more via (ns-publics 'ns)' hint" do
      # 8 prompt-visible exports in one namespace: only the cap should render in
      # detail; the rest are summarized with a discovery hint.
      defs =
        for i <- 1..8 do
          "(defn export-#{i} \"Doc #{i}.\" [] #{i})"
        end
        |> Enum.join("\n")

      source = "(ns big \"Many exports.\" {:visibility :prompt})\n" <> defs
      {:ok, prelude} = Compiler.compile(source)

      out = PromptInventory.render(prelude)

      cap = PromptInventory.per_namespace_cap()
      assert cap == 5

      rendered_count =
        1..8
        |> Enum.count(fn i -> out =~ "(export-#{i})" end)

      assert rendered_count == cap

      # The "more via" hint names the namespace and ns-publics.
      assert out =~ "(ns-publics 'big)"
      # It states how many more exports exist (8 total - 5 shown = 3 more).
      assert out =~ "3 more"
    end
  end
end
