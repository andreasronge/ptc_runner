defmodule PtcRunner.Operations.ToolCallTest do
  use ExUnit.Case

  describe "call operation (tool invocation)" do
    test "call tool with args" do
      tools = %{
        "add" => fn %{"a" => a, "b" => b} -> a + b end
      }

      program = ~s({"program": {
        "op": "call",
        "tool": "add",
        "args": {"a": 5, "b": 3}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program, tools: tools)
      assert result == 8
    end

    test "call tool without args passes empty map" do
      tools = %{
        "get_default" => fn _args -> "default_value" end
      }

      program = ~s({"program": {
        "op": "call",
        "tool": "get_default"
      }})

      {:ok, result, _metrics} = PtcRunner.run(program, tools: tools)
      assert result == "default_value"
    end

    test "call non-existent tool raises execution error" do
      program = ~s({"program": {
        "op": "call",
        "tool": "missing_tool"
      }})

      {:error, {:execution_error, msg}} = PtcRunner.run(program, tools: %{})
      assert String.contains?(msg, "Tool 'missing_tool' not found")
    end

    test "call tool that returns error tuple propagates error" do
      tools = %{
        "failing_tool" => fn _args -> {:error, "Something went wrong"} end
      }

      program = ~s({"program": {
        "op": "call",
        "tool": "failing_tool"
      }})

      {:error, {:execution_error, msg}} = PtcRunner.run(program, tools: tools)
      assert String.contains?(msg, "Tool 'failing_tool' error")
      assert String.contains?(msg, "Something went wrong")
    end

    test "call tool that raises exception catches and converts" do
      tools = %{
        "raising_tool" => fn _args -> raise "Tool crashed" end
      }

      program = ~s({"program": {
        "op": "call",
        "tool": "raising_tool"
      }})

      {:error, {:execution_error, msg}} = PtcRunner.run(program, tools: tools)
      assert String.contains?(msg, "Tool 'raising_tool' raised")
      assert String.contains?(msg, "Tool crashed")
    end

    test "call tool with wrong arity raises error" do
      tools = %{
        "wrong_arity" => fn -> "no args" end
      }

      program = ~s({"program": {
        "op": "call",
        "tool": "wrong_arity"
      }})

      {:error, {:validation_error, msg}} = PtcRunner.run(program, tools: tools)
      assert String.contains?(msg, "Tools must be functions with arity 1")
      assert String.contains?(msg, "wrong_arity")
    end

    test "tool validation catches arity-2 function" do
      tools = %{
        "bad_tool" => fn _a, _b -> "two args" end
      }

      program = ~s({"program": {"op": "literal", "value": 42}})

      {:error, {:validation_error, msg}} = PtcRunner.run(program, tools: tools)
      assert String.contains?(msg, "Tools must be functions with arity 1")
      assert String.contains?(msg, "bad_tool")
    end

    test "tool validation catches non-function values" do
      tools = %{
        "not_a_function" => "string value"
      }

      program = ~s({"program": {"op": "literal", "value": 42}})

      {:error, {:validation_error, msg}} = PtcRunner.run(program, tools: tools)
      assert String.contains?(msg, "Tools must be functions with arity 1")
      assert String.contains?(msg, "not_a_function")
    end

    test "tool validation reports multiple invalid tools" do
      tools = %{
        "tool1" => fn -> "zero args" end,
        "tool2" => "not a function",
        "tool3" => fn _a, _b -> "two args" end,
        "valid_tool" => fn _args -> "valid" end
      }

      program = ~s({"program": {"op": "literal", "value": 42}})

      {:error, {:validation_error, msg}} = PtcRunner.run(program, tools: tools)
      assert String.contains?(msg, "Tools must be functions with arity 1")
      # All three invalid tools should be mentioned
      assert String.contains?(msg, "tool1")
      assert String.contains?(msg, "tool2")
      assert String.contains?(msg, "tool3")
    end

    test "tool validation passes with valid arity-1 functions" do
      tools = %{
        "add" => fn %{"a" => a, "b" => b} -> a + b end,
        "multiply" => fn %{"x" => x, "y" => y} -> x * y end
      }

      program = ~s({"program": {
        "op": "call",
        "tool": "add",
        "args": {"a": 2, "b": 3}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program, tools: tools)
      assert result == 5
    end

    test "tool validation passes with empty tools map" do
      program = ~s({"program": {"op": "literal", "value": 42}})

      {:ok, result, _metrics} = PtcRunner.run(program, tools: %{})
      assert result == 42
    end

    test "missing tool field raises validation error" do
      program = ~s({"program": {
        "op": "call"
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'call' requires field 'tool'"}
    end

    test "args field must be a map raises validation error" do
      program = ~s({"program": {
        "op": "call",
        "tool": "test",
        "args": "not a map"
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Field 'args' must be a map"}
    end

    test "call tool as first step in pipe" do
      tools = %{
        "get_users" => fn _args ->
          [
            %{"id" => 1, "name" => "Alice", "active" => true},
            %{"id" => 2, "name" => "Bob", "active" => false}
          ]
        end
      }

      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "call", "tool": "get_users"},
          {"op": "filter", "where": {"op": "eq", "field": "active", "value": true}},
          {"op": "count"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program, tools: tools)
      assert result == 1
    end

    test "call tool and store result with let binding" do
      tools = %{
        "get_balance" => fn %{"account" => acc} -> acc * 100 end
      }

      program = ~s({"program": {
        "op": "let",
        "name": "balance",
        "value": {"op": "call", "tool": "get_balance", "args": {"account": 5}},
        "in": {"op": "var", "name": "balance"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program, tools: tools)
      assert result == 500
    end
  end
end
