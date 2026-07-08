defmodule PtcRunner.Lisp.Prelude.PromptInventoryTest do
  @moduledoc """
  Prelude prompt inventory compatibility wrapper over the shared sanitized
  symbol inventory renderer.
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
      # The prompt-visible export name with full usage shape.
      assert out =~ "crm/get-user"
      assert out =~ "use: (crm/get-user id)"
      # Its short doc.
      assert out =~ "Return a CRM user by id."
      # Its resolved effect hint (literal tool/call inference -> :read).
      assert out =~ "read"
    end

    test "honors a presentation export mask without changing the prelude" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns base "Base helpers." {:visibility :prompt})
        (defn helper "Used helper." [x] x)
        (defn unused "Debug helper." [x] x)
        """)

      out = PromptInventory.render(prelude, export_mask: %{"base" => ["base/helper"]})

      assert out =~ "base/helper"
      refute out =~ "base/unused"
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
      assert out =~ "use: (mix/fetch id)"
      assert out =~ "[read]"
      # ...but the pure (:unknown) export renders no effect bracket.
      assert out =~ "mix/area"
      assert out =~ "use: (mix/area w h)"
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

      assert out =~ "use: (mix/foo a b & rest)"
      refute out =~ "(mix/foo & args)"
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

      assert PromptInventory.render(prelude) =~ "use: (mix/pull arg1)"
    end

    test "renders prelude def constants as values and defn exports as functions" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns cfg "Config." {:visibility :prompt})
        (def default-limit "Default page limit." 25)
        (defn cap "Cap n." [n] (min n default-limit))
        """)

      out = PromptInventory.render(prelude)

      assert out =~ "cfg/default-limit"
      assert out =~ "; value"
      assert out =~ "use: cfg/default-limit"
      refute out =~ "(cfg/default-limit"

      assert out =~ "cfg/cap [n]"
      assert out =~ "; function"
      assert out =~ "use: (cfg/cap n)"
      assert out =~ "Default page limit."
    end

    test "renders the shared symbol-inventory header", %{prelude: prelude} do
      out = PromptInventory.render(prelude)
      assert out =~ ";; === available symbols ==="
      assert out =~ "Use value symbols directly"
    end

    test "omits the :discoverable export detail and source hint", %{prelude: prelude} do
      out = PromptInventory.render(prelude)

      # The :discoverable export (list-users) is NOT detailed in the inventory.
      refute out =~ "List CRM users."
      assert out =~ "ns-publics"
      assert out =~ "apropos"
      refute out =~ "(source"
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
    test "caps the rendered exports at ~5 and reports omitted count" do
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
        |> Enum.count(fn i -> out =~ "big/export-#{i}" end)

      assert rendered_count == cap

      # It states how many more exports exist (8 total - 5 shown = 3 more).
      assert out =~ "+3 more symbols omitted"
    end

    test "applies the cap per prelude namespace, not globally" do
      defs = fn prefix ->
        Enum.map_join(1..6, "\n", fn i -> "(defn #{prefix}-#{i} \"Doc #{i}.\" [] #{i})" end)
      end

      source = """
      (ns alpha "Alpha." {:visibility :prompt})
      #{defs.("a")}
      (ns beta "Beta." {:visibility :prompt})
      #{defs.("b")}
      """

      {:ok, prelude} = Compiler.compile(source)
      out = PromptInventory.render(prelude)

      assert out =~ "alpha/a-1"
      assert out =~ "alpha/a-5"
      refute out =~ "alpha/a-6"
      assert out =~ "beta/b-1"
      assert out =~ "beta/b-5"
      refute out =~ "beta/b-6"
      assert out =~ "+2 more symbols omitted"
    end
  end
end
