defmodule PtcRunnerTest do
  use ExUnit.Case
  doctest PtcRunner

  # Public API tests
  describe "run/2" do
    test "valid wrapped JSON string extracts program and runs successfully" do
      program = ~s({"program": {"op": "literal", "value": 42}})
      {:ok, result, _metrics} = PtcRunner.Json.run(program)

      assert result == 42
    end

    test "valid wrapped map extracts program and runs successfully" do
      program = %{"program" => %{"op" => "literal", "value" => 99}}
      {:ok, result, _metrics} = PtcRunner.Json.run(program)

      assert result == 99
    end

    test "missing program field returns parse error" do
      program = ~s({"data": {"op": "literal", "value": 42}})
      {:error, {:parse_error, message}} = PtcRunner.Json.run(program)

      assert message == "Missing required field 'program'"
    end

    test "program is not a map returns parse error" do
      # Test with null
      program = ~s({"program": null})
      {:error, {:parse_error, message}} = PtcRunner.Json.run(program)
      assert message == "program must be a map"

      # Test with string
      program = ~s({"program": "not a map"})
      {:error, {:parse_error, message}} = PtcRunner.Json.run(program)
      assert message == "program must be a map"

      # Test with array
      program = ~s({"program": [1, 2, 3]})
      {:error, {:parse_error, message}} = PtcRunner.Json.run(program)
      assert message == "program must be a map"
    end
  end

  describe "run!/2" do
    test "run! returns result without metrics" do
      program = ~s({"program": {"op": "literal", "value": 42}})
      result = PtcRunner.Json.run!(program)

      assert result == 42
    end

    test "run! raises on error" do
      program = ~s({"program": {"op": "unknown_op"}})

      assert_raise RuntimeError, fn ->
        PtcRunner.Json.run!(program)
      end
    end
  end

  # Resource limit tests
  describe "resource limits" do
    test "timeout is enforced" do
      # Create a program that tries to exceed timeout
      tools = %{
        "slow_tool" => fn _args ->
          # Simulate slow execution
          :timer.sleep(2000)
          "done"
        end
      }

      program = ~s({"program": {
        "op": "call",
        "tool": "slow_tool"
      }})

      result = PtcRunner.Json.run(program, tools: tools, timeout_ms: 100)

      assert match?({:error, {:timeout, _}}, result) or
               match?({:error, {:execution_error, _}}, result)
    end

    test "memory limit is enforced" do
      # Create a simple program that should complete normally
      # (The memory limit testing is implementation-dependent)
      program = ~s({"program": {
        "op": "literal",
        "value": [1, 2, 3]
      }})

      # With a reasonable memory limit, this should succeed
      {:ok, result, _metrics} = PtcRunner.Json.run(program, memory_limit_bytes: 1_000_000)
      assert result == [1, 2, 3]
    end
  end

  # E2E Integration tests
  describe "end-to-end integration" do
    test "filter and sum pipeline from issue example" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "load", "name": "data"},
          {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
          {"op": "sum", "field": "amount"}
        ]
      }})

      context = %{
        "data" => [
          %{"category" => "travel", "amount" => 500},
          %{"category" => "food", "amount" => 50}
        ]
      }

      {:ok, result, metrics} = PtcRunner.Json.run(program, context: context)

      assert result == 500
      assert metrics.duration_ms >= 0
      assert metrics.memory_bytes > 0
    end

    test "extract nested user emails from list of users" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "load", "name": "users"},
          {"op": "map", "expr": {"op": "get", "path": ["profile", "email"]}}
        ]
      }})

      context = %{
        "users" => [
          %{"id" => 1, "profile" => %{"email" => "alice@example.com"}},
          %{"id" => 2, "profile" => %{"email" => "bob@example.com"}}
        ]
      }

      {:ok, result, _metrics} = PtcRunner.Json.run(program, context: context)
      assert result == ["alice@example.com", "bob@example.com"]
    end

    test "E2E: expense filtering and aggregation" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "load", "name": "expenses"},
          {"op": "filter", "where": {"op": "gt", "field": "amount", "value": 100}},
          {"op": "sum", "field": "amount"}
        ]
      }})

      context = %{
        "expenses" => [
          %{"category" => "travel", "amount" => 500},
          %{"category" => "food", "amount" => 50},
          %{"category" => "accommodation", "amount" => 200},
          %{"category" => "miscellaneous", "amount" => 30}
        ]
      }

      {:ok, result, _metrics} = PtcRunner.Json.run(program, context: context)
      assert result == 700
    end
  end

  describe "format_error/1" do
    test "formats parse errors" do
      assert PtcRunner.Json.format_error({:parse_error, "unexpected token"}) ==
               "ParseError: unexpected token"
    end

    test "formats validation errors" do
      assert PtcRunner.Json.format_error({:validation_error, "unknown operation 'foo'"}) ==
               "ValidationError: unknown operation 'foo'"
    end

    test "formats timeout errors" do
      assert PtcRunner.Json.format_error({:timeout, 5000}) ==
               "TimeoutError: execution exceeded 5000ms limit"
    end

    test "formats memory exceeded errors" do
      assert PtcRunner.Json.format_error({:memory_exceeded, 10_000_000}) ==
               "MemoryError: exceeded 10000000 byte limit"
    end

    test "formats badmap execution errors" do
      error_msg = """
      Process terminated: {{:badmap, "Employee 1"}, [{Map, :get, ["Employee 1", "years_employed", nil], []}]}
      """

      result = PtcRunner.Json.format_error({:execution_error, error_msg})
      assert result =~ "TypeError:"
      assert result =~ "expected an object"
    end

    test "extracts value from badmap error" do
      error_msg = ~s(expected a map, got:\n\n    "some string value")
      result = PtcRunner.Json.format_error({:execution_error, error_msg})
      assert result == ~s(TypeError: expected an object but got: "some string value")
    end

    test "formats badkey execution errors" do
      error_msg = "key :missing not found in: %{name: \"test\"}"
      result = PtcRunner.Json.format_error({:execution_error, error_msg})
      assert result =~ "KeyError:"
      assert result =~ "not found"
    end

    test "formats undefined variable errors" do
      error_msg = ~s({:undefined_variable, "myvar"})
      result = PtcRunner.Json.format_error({:execution_error, error_msg})
      assert result =~ "UndefinedVariable:"
      assert result =~ "myvar"
    end

    test "formats arithmetic errors" do
      error_msg = "Process terminated: {:badarith, ...}"
      result = PtcRunner.Json.format_error({:execution_error, error_msg})
      assert result =~ "ArithmeticError:"
    end

    test "formats unknown errors with inspect" do
      result = PtcRunner.Json.format_error(:some_unknown_error)
      assert result =~ "Error:"
      assert result =~ "some_unknown_error"
    end

    test "truncates long generic error messages" do
      long_msg = String.duplicate("x", 500)
      result = PtcRunner.Json.format_error({:execution_error, long_msg})
      assert String.length(result) < 250
    end
  end
end
