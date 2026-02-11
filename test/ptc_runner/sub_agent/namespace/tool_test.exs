defmodule PtcRunner.SubAgent.Namespace.ToolTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.Namespace.Tool

  alias PtcRunner.SubAgent.Namespace.Tool

  defp make_tool(name, signature) do
    %PtcRunner.Tool{name: name, signature: signature, type: :native}
  end

  describe "render/1" do
    test "returns no tools message for empty map" do
      assert Tool.render(%{}) == ";; No tools available"
    end

    test "renders single tool with signature including param types" do
      tools = %{"search" => make_tool("search", "(query :string) -> :string")}
      result = Tool.render(tools)

      assert result ==
               ";; === tools ===\ntool/search(query string) -> string\n;; Example: (tool/search {:query ...})"
    end

    test "renders multiple tools sorted alphabetically with param types" do
      tools = %{
        "zebra-tool" => make_tool("zebra-tool", "-> :map"),
        "apple-tool" => make_tool("apple-tool", "(id :int) -> :string"),
        "mango-tool" => make_tool("mango-tool", "(a :string, b :int) -> :bool")
      }

      result = Tool.render(tools)
      lines = String.split(result, "\n")

      assert Enum.at(lines, 0) == ";; === tools ==="
      assert Enum.at(lines, 1) == "tool/apple-tool(id int) -> string"
      assert Enum.at(lines, 2) == "tool/mango-tool(a string, b int) -> bool"
      assert Enum.at(lines, 3) == "tool/zebra-tool() -> map"
      # Usage example based on first tool with params (apple-tool)
      assert Enum.at(lines, 4) == ";; Example: (tool/apple-tool {:id ...})"
    end

    test "tool without signature uses fallback" do
      tools = %{"dynamic" => make_tool("dynamic", nil)}
      result = Tool.render(tools)

      assert result ==
               ";; === tools ===\ntool/dynamic() -> any\n;; Call with named args: (tool/name {:key value})"
    end

    test "signature with no params renders correctly" do
      tools = %{"get-time" => make_tool("get-time", "-> :map")}
      result = Tool.render(tools)

      assert result ==
               ";; === tools ===\ntool/get-time() -> map\n;; Call with named args: (tool/name {:key value})"
    end

    test "complex signature with multiple params shows all types" do
      tools = %{
        "analyze" =>
          make_tool("analyze", "(data :map, threshold :float, enabled :bool) -> {score :float}")
      }

      result = Tool.render(tools)

      assert result ==
               ";; === tools ===\ntool/analyze(data map, threshold float, enabled bool) -> {score float}\n;; Example: (tool/analyze {:data ... :threshold ... :enabled ...})"
    end

    test "renders list return types correctly with param types" do
      tools = %{"list-items" => make_tool("list-items", "(filter :string) -> [:string]")}
      result = Tool.render(tools)

      assert result ==
               ";; === tools ===\ntool/list-items(filter string) -> [string]\n;; Example: (tool/list-items {:filter ...})"
    end

    test "renders optional return types correctly with param types" do
      tools = %{"find-user" => make_tool("find-user", "(id :int) -> :string?")}
      result = Tool.render(tools)

      assert result ==
               ";; === tools ===\ntool/find-user(id int) -> string?\n;; Example: (tool/find-user {:id ...})"
    end
  end
end
