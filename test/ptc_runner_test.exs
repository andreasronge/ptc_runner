defmodule PtcRunnerTest do
  use ExUnit.Case
  doctest PtcRunner

  # Basic literal operation
  test "literal returns the specified value" do
    program = ~s({"op": "literal", "value": 42})
    {:ok, result, metrics} = PtcRunner.run(program)

    assert result == 42
    assert metrics.duration_ms >= 0
    assert metrics.memory_bytes > 0
  end

  # Load operation
  test "load retrieves variable from context" do
    program = ~s({"op": "load", "name": "data"})

    {:ok, result, _metrics} =
      PtcRunner.run(program, context: %{"data" => [1, 2, 3]})

    assert result == [1, 2, 3]
  end

  test "load returns nil for missing variable" do
    program = ~s({"op": "load", "name": "missing"})
    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == nil
  end

  # Pipe operation
  test "pipe chains operations" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "count"}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 3
  end

  test "empty pipe returns nil" do
    program = ~s({"op": "pipe", "steps": []})
    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == nil
  end

  # Count operation
  test "count returns number of items in list" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3, 4, 5]},
        {"op": "count"}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 5
  end

  test "count on empty list returns 0" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "count"}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 0
  end

  # Sum operation
  test "sum aggregates numeric field values" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 500},
          {"category": "food", "amount": 50},
          {"category": "travel", "amount": 200}
        ]},
        {"op": "sum", "field": "amount"}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 750
  end

  test "sum on empty list returns 0" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "sum", "field": "amount"}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 0
  end

  test "sum ignores missing fields" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 100},
          {"category": "food"},
          {"category": "other", "amount": 50}
        ]},
        {"op": "sum", "field": "amount"}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 150
  end

  # Eq comparison operation
  test "eq compares field value with literal" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": "travel"}},
        {"op": "eq", "field": "category", "value": "travel"}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "eq returns false for non-matching values" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": "food"}},
        {"op": "eq", "field": "category", "value": "travel"}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  # Filter operation
  test "filter keeps matching items" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 500},
          {"category": "food", "amount": 50},
          {"category": "travel", "amount": 200}
        ]},
        {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == [
             %{"category" => "travel", "amount" => 500},
             %{"category" => "travel", "amount" => 200}
           ]
  end

  test "filter on empty list returns empty list" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == []
  end

  # Map operation
  test "map transforms each item" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "map", "expr": {"op": "literal", "value": "x"}}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == ["x", "x", "x"]
  end

  test "map on empty list returns empty list" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "map", "expr": {"op": "literal", "value": "x"}}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == []
  end

  # Select operation
  test "select picks specific fields from each map" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"name": "Alice", "age": 30, "city": "NYC"},
          {"name": "Bob", "age": 25, "city": "LA"}
        ]},
        {"op": "select", "fields": ["name", "age"]}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == [
             %{"name" => "Alice", "age" => 30},
             %{"name" => "Bob", "age" => 25}
           ]
  end

  # Complex pipeline
  test "filter and sum pipeline from issue example" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "load", "name": "data"},
        {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
        {"op": "sum", "field": "amount"}
      ]
    })

    context = %{
      "data" => [
        %{"category" => "travel", "amount" => 500},
        %{"category" => "food", "amount" => 50}
      ]
    }

    {:ok, result, metrics} = PtcRunner.run(program, context: context)

    assert result == 500
    assert metrics.duration_ms >= 0
    assert metrics.memory_bytes > 0
  end

  # Error handling - validation errors
  test "missing 'op' field raises validation error" do
    program = ~s({"value": 42})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Missing required field 'op'"}
  end

  test "unknown operation raises validation error" do
    program = ~s({"op": "unknown_op"})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
  end

  test "missing required field in operation raises validation error" do
    program = ~s({"op": "literal"})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'literal' requires field 'value'"}
  end

  test "literal with no value field raises validation error" do
    program = ~s({"op": "load"})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'load' requires field 'name'"}
  end

  # Error handling - type errors
  test "count on non-list raises error" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "count"}
      ]
    })

    {:error, reason} = PtcRunner.run(program)
    assert String.contains?(reason, "count requires a list")
  end

  test "sum on non-list raises error" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": "not a list"},
        {"op": "sum", "field": "amount"}
      ]
    })

    {:error, reason} = PtcRunner.run(program)
    assert String.contains?(reason, "sum requires a list")
  end

  test "filter on non-list raises error" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "filter", "where": {"op": "eq", "field": "x", "value": 1}}
      ]
    })

    {:error, reason} = PtcRunner.run(program)
    assert String.contains?(reason, "filter requires a list")
  end

  # Parse errors
  test "malformed JSON raises parse error" do
    program = "{invalid json"
    {:error, {:parse_error, message}} = PtcRunner.run(program)

    assert String.contains?(message, "JSON decode error")
  end

  # Timeout handling
  test "timeout is enforced" do
    program = ~s({"op": "literal", "value": 42})

    # Use a very short timeout to trigger it
    {:error, reason} = PtcRunner.run(program, timeout: 0)
    assert reason == :timeout
  end

  # run! function
  test "run! returns result without metrics" do
    program = ~s({"op": "literal", "value": 42})
    result = PtcRunner.run!(program)

    assert result == 42
  end

  test "run! raises on error" do
    program = ~s({"op": "unknown_op"})

    assert_raise RuntimeError, fn ->
      PtcRunner.run!(program)
    end
  end
end
