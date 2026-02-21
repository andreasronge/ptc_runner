defmodule PtcRunner.SubAgent.ToolSchemaTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.ToolSchema

  describe "to_tool_definitions/1" do
    test "converts tool with signature to correct schema" do
      tools = %{
        "search" =>
          {fn _ -> [] end,
           signature: "(query :string, limit :int) -> [{id :int}]",
           description: "Search for items"}
      }

      [defn] = ToolSchema.to_tool_definitions(tools)

      assert defn["type"] == "function"
      assert defn["function"]["name"] == "search"
      assert defn["function"]["description"] == "Search for items"

      params = defn["function"]["parameters"]
      assert params["type"] == "object"
      assert params["properties"]["query"] == %{"type" => "string"}
      assert params["properties"]["limit"] == %{"type" => "integer"}
      assert "query" in params["required"]
      assert "limit" in params["required"]
    end

    test "handles optional parameters" do
      tools = %{
        "find" => {fn _ -> [] end, signature: "(name :string, age :int?) -> :string"}
      }

      [defn] = ToolSchema.to_tool_definitions(tools)
      params = defn["function"]["parameters"]
      assert "name" in params["required"]
      refute "age" in params["required"]
      assert params["properties"]["age"] == %{"type" => "integer"}
    end

    test "handles tool without signature" do
      tools = %{"simple" => fn _ -> :ok end}

      [defn] = ToolSchema.to_tool_definitions(tools)
      assert defn["function"]["name"] == "simple"
      assert defn["function"]["parameters"] == %{"type" => "object", "properties" => %{}}
    end

    test "handles nested map parameters" do
      tools = %{
        "create" => {fn _ -> :ok end, signature: "(config {host :string, port :int}) -> :bool"}
      }

      [defn] = ToolSchema.to_tool_definitions(tools)
      params = defn["function"]["parameters"]
      config_schema = params["properties"]["config"]
      assert config_schema["type"] == "object"
      assert config_schema["properties"]["host"] == %{"type" => "string"}
      assert config_schema["properties"]["port"] == %{"type" => "integer"}
    end

    test "handles list parameters" do
      tools = %{
        "process" => {fn _ -> :ok end, signature: "(items [:string]) -> :int"}
      }

      [defn] = ToolSchema.to_tool_definitions(tools)
      params = defn["function"]["parameters"]

      assert params["properties"]["items"] == %{
               "type" => "array",
               "items" => %{"type" => "string"}
             }
    end

    test "description flows through" do
      tools = %{
        "greet" =>
          {fn _ -> "hi" end,
           signature: "(name :string) -> :string", description: "Greet a user by name"}
      }

      [defn] = ToolSchema.to_tool_definitions(tools)
      assert defn["function"]["description"] == "Greet a user by name"
    end

    test "multiple tools return list of definitions" do
      tools = %{
        "a" => fn _ -> :ok end,
        "b" => fn _ -> :ok end,
        "c" => fn _ -> :ok end
      }

      defs = ToolSchema.to_tool_definitions(tools)
      assert length(defs) == 3
      names = Enum.map(defs, & &1["function"]["name"]) |> Enum.sort()
      assert names == ["a", "b", "c"]
    end
  end

  describe "to_tool_definition/1" do
    test "converts a single Tool struct" do
      {:ok, tool} =
        PtcRunner.Tool.new(
          "test",
          {fn _ -> :ok end, signature: "(x :int) -> :string", description: "Test tool"}
        )

      defn = ToolSchema.to_tool_definition(tool)
      assert defn["type"] == "function"
      assert defn["function"]["name"] == "test"
      assert defn["function"]["description"] == "Test tool"
      assert defn["function"]["parameters"]["properties"]["x"] == %{"type" => "integer"}
    end
  end
end
