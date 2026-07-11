defmodule PtcRunner.SymbolInventoryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Prelude.Compiler
  alias PtcRunner.SymbolInventory

  describe "project/1" do
    test "projects typed prelude functions and constants into the rendered inventory" do
      source = """
      (ns typed "Typed helpers." {:visibility :prompt})
      (defn lookup "Look up one item." {:signature "(id
        :string)   ->   {id :string}"} [id]
        {"id" id})
      (def retry-limit "Maximum retries." {:type "  :int\n"} 3)
      """

      assert {:ok, prelude} = Compiler.compile(source)
      facts = SymbolInventory.project(prelude: prelude)

      assert %{signature: "(id :string) -> {id :string}"} =
               Enum.find(facts, &(&1.ref == "typed/lookup"))

      assert %{type: ":int"} = Enum.find(facts, &(&1.ref == "typed/retry-limit"))

      {:ok, rendered, _meta} = SymbolInventory.render(facts)
      assert rendered =~ "(id :string) -> {id :string}"
      assert rendered =~ "value :int"
    end

    test "projects data entries as values with bounded samples and direct usage" do
      facts = SymbolInventory.project(data: %{numbers: [2, 4, 6, 8]})

      assert [
               %{
                 ref: "data/numbers",
                 kind: :value,
                 source: :data,
                 type: "list[4]",
                 sample: "[2 4 6 ...] (3/4)",
                 usage: "data/numbers"
               }
             ] = facts

      {:ok, rendered, _meta} = SymbolInventory.render(facts)
      assert rendered =~ "data/numbers"
      assert rendered =~ "value list[4]"
      assert rendered =~ "use: data/numbers"
      refute rendered =~ "(data/numbers"
    end

    test "suppresses samples for secret-like data keys by default" do
      facts =
        SymbolInventory.project(data: %{"api_key" => "sk-secret", password: "p", safe: "visible"})

      api_key = Enum.find(facts, &(&1.ref == "data/api_key"))
      password = Enum.find(facts, &(&1.ref == "data/password"))
      safe = Enum.find(facts, &(&1.ref == "data/safe"))

      refute Map.has_key?(api_key, :sample)
      refute Map.has_key?(password, :sample)
      assert safe.sample == ~s|"visible"|

      {:ok, rendered, _meta} = SymbolInventory.render(facts)
      refute rendered =~ "sk-secret"
      refute rendered =~ "sample: \"p\""
      assert rendered =~ "data/api_key"
    end

    test "projects public mission tools as functions and excludes private/kernel tools" do
      tools = %{
        "search" =>
          {fn _ -> :ok end,
           signature: "(query :string, limit :int) -> :map", description: "Search records."},
        "hidden" => {fn _ -> :ok end, visibility: :private, description: "Do not show."},
        "eval-program" => {fn _ -> :ok end, description: "Kernel private name."}
      }

      facts = SymbolInventory.project(tools: tools)

      assert [%{ref: "tool/search", kind: :function, params: ["query", "limit"]} = fact] = facts
      assert fact.usage == "(tool/search {:query query :limit limit})"
      assert fact.doc == "Search records."
      refute Enum.any?(facts, &(&1.ref == "tool/hidden"))
      refute Enum.any?(facts, &(&1.ref == "tool/eval-program"))

      parent = self()

      tool = fn args ->
        send(parent, {:tool_args, args})
        :ok
      end

      program = ~s|(let [query "q" limit 2] #{fact.usage})|

      assert {:ok, _step} =
               PtcRunner.Lisp.run(program,
                 tools: %{"search" => {tool, signature: "(query :string, limit :int) -> :any"}}
               )

      assert_received {:tool_args, %{"query" => "q", "limit" => 2}}
    end

    test "projects only memory_summary entries without closure internals" do
      summary = %{
        "entries" => [
          %{"name" => "total", "kind" => "value", "preview" => "42"},
          %{
            "name" => "double",
            "kind" => "function",
            "preview" => "{:closure, [x], body, %{secret: true}}"
          }
        ]
      }

      facts = SymbolInventory.project(memory_summary: summary)

      assert %{ref: "total", kind: :value, sample: "42", usage: "total"} =
               Enum.find(facts, &(&1.ref == "total"))

      assert %{ref: "double", kind: :function, usage: "(double)"} =
               Enum.find(facts, &(&1.ref == "double"))

      {:ok, rendered, _meta} = SymbolInventory.render(facts)
      refute rendered =~ "secret"
      refute rendered =~ "closure"
    end

    test "normalizes prelude constant/function exports by kind" do
      {:ok, prelude} =
        Compiler.compile("""
        (ns cfg "Config." {:visibility :prompt})
        (def default-limit "Default page limit." 25)
        (defn cap "Cap n." [n] (min n default-limit))
        (defn hidden "Hidden." {:visibility :discoverable} [] 1)
        """)

      facts = SymbolInventory.project(prelude: prelude)

      assert %{ref: "cfg/default-limit", kind: :value, usage: "cfg/default-limit"} =
               Enum.find(facts, &(&1.ref == "cfg/default-limit"))

      assert %{ref: "cfg/cap", kind: :function, usage: "(cfg/cap n)"} =
               Enum.find(facts, &(&1.ref == "cfg/cap"))

      refute Enum.any?(facts, &(&1.ref == "cfg/hidden"))
    end
  end

  describe "render/3" do
    test "is deterministic, sorted, capped, and reports omissions" do
      facts =
        SymbolInventory.project(data: %{c: 3, a: 1, b: 2})

      {:ok, first, meta} = SymbolInventory.render(facts, :default, cap: 2)
      {:ok, second, ^meta} = SymbolInventory.render(Enum.reverse(facts), :default, cap: 2)

      assert first == second
      assert first =~ "data/a"
      assert first =~ "data/b"
      refute first =~ "data/c"
      assert first =~ "+1 more symbols omitted"
      assert meta["renderer_id"] == "default_v1"
      assert meta["fact_count"] == 3
      assert meta["omitted_count"] == 1
    end

    test "supports an alternate renderer without changing facts" do
      facts = SymbolInventory.project(data: %{n: 1})

      {:ok, default_text, default_meta} = SymbolInventory.render(facts, :default)
      {:ok, reference_text, reference_meta} = SymbolInventory.render(facts, :reference)

      assert default_text != reference_text
      assert default_meta["renderer_id"] == "default_v1"
      assert reference_meta["renderer_id"] == "reference_v1"
      assert default_meta["fact_count"] == reference_meta["fact_count"]
    end

    test "unknown renderer fails closed" do
      assert {:error, %{reason: "invalid_symbol_inventory_renderer"}} =
               SymbolInventory.render([], :unknown_renderer)
    end
  end
end
