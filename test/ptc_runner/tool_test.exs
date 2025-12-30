defmodule PtcRunner.ToolTest do
  use ExUnit.Case, async: true

  describe "Tool.new/2" do
    test "creates tool from bare function reference" do
      {:ok, tool} = PtcRunner.Tool.new("get_time", fn _args -> DateTime.utc_now() end)

      assert tool.name == "get_time"
      assert is_function(tool.function)
      assert tool.signature == nil
      assert tool.description == nil
      assert tool.type == :native
    end

    test "creates tool from function with explicit signature string" do
      signature = "(query :string, limit :int) -> [{id :int}]"
      {:ok, tool} = PtcRunner.Tool.new("search", {fn _args -> [] end, signature})

      assert tool.name == "search"
      assert is_function(tool.function)
      assert tool.signature == signature
      assert tool.description == nil
      assert tool.type == :native
    end

    test "creates tool from function with :skip validation" do
      {:ok, tool} = PtcRunner.Tool.new("dynamic", {fn _args -> nil end, :skip})

      assert tool.name == "dynamic"
      assert is_function(tool.function)
      assert tool.signature == nil
      assert tool.description == nil
      assert tool.type == :native
    end

    test "creates tool from function with keyword options (signature and description)" do
      options = [
        signature: "(data :map) -> {score :float}",
        description: "Analyze data and return anomaly score"
      ]

      {:ok, tool} = PtcRunner.Tool.new("analyze", {fn _args -> %{} end, options})

      assert tool.name == "analyze"
      assert is_function(tool.function)
      assert tool.signature == "(data :map) -> {score :float}"
      assert tool.description == "Analyze data and return anomaly score"
      assert tool.type == :native
    end

    test "creates tool from function with keyword options (partial options)" do
      options = [signature: "(x :int) -> :int"]
      {:ok, tool} = PtcRunner.Tool.new("double", {fn _args -> 0 end, options})

      assert tool.name == "double"
      assert tool.signature == "(x :int) -> :int"
      assert tool.description == nil
      assert tool.type == :native
    end

    test "returns error when format is not a function or valid tuple" do
      assert {:error, :invalid_tool_format} = PtcRunner.Tool.new("bad", "not_a_function")
      assert {:error, :invalid_tool_format} = PtcRunner.Tool.new("bad", 123)
      assert {:error, :invalid_tool_format} = PtcRunner.Tool.new("bad", nil)
    end

    test "returns error when tuple has non-function first element" do
      assert {:error, :invalid_tool_format} = PtcRunner.Tool.new("bad", {"not_a_function", "()"})
      assert {:error, :invalid_tool_format} = PtcRunner.Tool.new("bad", {123, :skip})
    end

    test "returns error when tuple has non-string signature" do
      assert {:error, :invalid_tool_format} =
               PtcRunner.Tool.new("bad", {fn _args -> nil end, 123})
    end

    test "returns error when tuple has non-list non-string non-skip second element" do
      assert {:error, :invalid_tool_format} = PtcRunner.Tool.new("bad", {fn _args -> nil end, {}})
    end
  end
end
