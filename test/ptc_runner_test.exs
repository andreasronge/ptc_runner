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

  # Get operation
  test "get with single-element path extracts top-level field" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice", "age": 30}},
        {"op": "get", "path": ["name"]}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == "Alice"
  end

  test "get with multi-element path extracts nested field" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"user": {"profile": {"email": "alice@example.com"}}}},
        {"op": "get", "path": ["user", "profile", "email"]}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == "alice@example.com"
  end

  test "get with empty path returns current value" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice"}},
        {"op": "get", "path": []}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"name" => "Alice"}
  end

  test "get with missing path returns nil" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice"}},
        {"op": "get", "path": ["missing", "field"]}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "get with default returns default when path missing" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice"}},
        {"op": "get", "path": ["age"], "default": 25}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 25
  end

  test "get with default returns value when path exists" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice", "age": 30}},
        {"op": "get", "path": ["age"], "default": 25}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 30
  end

  test "get on non-map returns nil" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 123},
        {"op": "get", "path": ["field"]}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "get within pipe receives piped input" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"x": {"y": 42}}},
        {"op": "get", "path": ["x", "y"]}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 42
  end

  test "get within map accesses current item fields" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"id": 1, "profile": {"email": "alice@example.com"}},
          {"id": 2, "profile": {"email": "bob@example.com"}}
        ]},
        {"op": "map", "expr": {"op": "get", "path": ["profile", "email"]}}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == ["alice@example.com", "bob@example.com"]
  end

  test "get with missing path on map returns nil" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"x": 1}},
        {"op": "get", "path": ["y", "z"]}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "get with missing path returns default value" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"x": 1}},
        {"op": "get", "path": ["y"], "default": 99}
      ]
    })

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 99
  end

  # E2E test demonstrating get with map
  test "extract nested user emails from list of users" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "load", "name": "users"},
        {"op": "map", "expr": {"op": "get", "path": ["profile", "email"]}}
      ]
    })

    context = %{
      "users" => [
        %{"id" => 1, "profile" => %{"email" => "alice@example.com"}},
        %{"id" => 2, "profile" => %{"email" => "bob@example.com"}}
      ]
    }

    {:ok, result, _metrics} = PtcRunner.run(program, context: context)
    assert result == ["alice@example.com", "bob@example.com"]
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

  test "nested unknown operation in pipe raises validation error" do
    program = ~s({"op": "pipe", "steps": [{"op": "unknown_op"}]})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
  end

  test "get operation missing path field raises validation error" do
    program = ~s({"op": "get"})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'get' requires field 'path'"}
  end

  test "get operation with non-array path raises validation error" do
    program = ~s({"op": "get", "path": "not_an_array"})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Field 'path' must be a list"}
  end

  test "get operation with non-string path elements raises validation error" do
    program = ~s({"op": "get", "path": ["valid", 123]})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "All path elements in 'path' must be strings"}
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

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "count requires a list")
  end

  test "sum on non-list raises error" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": "not a list"},
        {"op": "sum", "field": "amount"}
      ]
    })

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "sum requires a list")
  end

  test "filter on non-list raises error" do
    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "filter", "where": {"op": "eq", "field": "x", "value": 1}}
      ]
    })

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "filter requires a list")
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
    assert reason == {:timeout, 0}
  end

  # Memory limit handling
  test "memory limit is enforced" do
    # Pass large data through context - context data counts toward sandbox memory
    # per docs/architecture.md:297-298, making this a valid test approach
    large_list = List.duplicate(%{"data" => String.duplicate("x", 1000)}, 10_000)

    program = ~s({
      "op": "pipe",
      "steps": [
        {"op": "load", "name": "large_data"},
        {"op": "count"}
      ]
    })

    # Use a very small max_heap to trigger the limit
    {:error, reason} =
      PtcRunner.run(program, context: %{"large_data" => large_list}, max_heap: 1000)

    assert {:memory_exceeded, bytes} = reason
    assert is_integer(bytes)
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
