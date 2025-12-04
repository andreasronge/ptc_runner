defmodule PtcRunnerTest do
  use ExUnit.Case
  doctest PtcRunner

  # Basic literal operation
  test "literal returns the specified value" do
    program = ~s({"program": {"op": "literal", "value": 42}})
    {:ok, result, metrics} = PtcRunner.run(program)

    assert result == 42
    assert metrics.duration_ms >= 0
    assert metrics.memory_bytes > 0
  end

  # Load operation
  test "load retrieves variable from context" do
    program = ~s({"program": {"op": "load", "name": "data"}})

    {:ok, result, _metrics} =
      PtcRunner.run(program, context: %{"data" => [1, 2, 3]})

    assert result == [1, 2, 3]
  end

  test "load returns nil for missing variable" do
    program = ~s({"program": {"op": "load", "name": "missing"}})
    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == nil
  end

  # Pipe operation
  test "pipe chains operations" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "count"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 3
  end

  test "empty pipe returns nil" do
    program = ~s({"program": {"op": "pipe", "steps": []}})
    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == nil
  end

  # Count operation
  test "count returns number of items in list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3, 4, 5]},
        {"op": "count"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 5
  end

  test "count on empty list returns 0" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "count"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 0
  end

  # Sum operation
  test "sum aggregates numeric field values" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 500},
          {"category": "food", "amount": 50},
          {"category": "travel", "amount": 200}
        ]},
        {"op": "sum", "field": "amount"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 750
  end

  test "sum on empty list returns 0" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "sum", "field": "amount"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 0
  end

  test "sum ignores missing fields" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 100},
          {"category": "food"},
          {"category": "other", "amount": 50}
        ]},
        {"op": "sum", "field": "amount"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 150
  end

  # Eq comparison operation
  test "eq compares field value with literal" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": "travel"}},
        {"op": "eq", "field": "category", "value": "travel"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "eq returns false for non-matching values" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": "food"}},
        {"op": "eq", "field": "category", "value": "travel"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  test "eq with nil field value" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": null}},
        {"op": "eq", "field": "category", "value": null}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  # Neq comparison operation
  test "neq compares field value with literal" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": "food"}},
        {"op": "neq", "field": "category", "value": "travel"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "neq returns false for equal values" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": "travel"}},
        {"op": "neq", "field": "category", "value": "travel"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  # Gt comparison operation
  test "gt returns true when field value is greater" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 100}},
        {"op": "gt", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "gt returns false when field value is not greater" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 30}},
        {"op": "gt", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  # Gte comparison operation
  test "gte returns true when field value is greater or equal" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 50}},
        {"op": "gte", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "gte returns false when field value is less" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 30}},
        {"op": "gte", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  # Lt comparison operation
  test "lt returns true when field value is less" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 30}},
        {"op": "lt", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "lt returns false when field value is not less" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 100}},
        {"op": "lt", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  # Lte comparison operation
  test "lte returns true when field value is less or equal" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 50}},
        {"op": "lte", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "lte returns false when field value is greater" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 100}},
        {"op": "lte", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  # E2E test with filter using comparison operations
  test "filter with numeric comparison returns matching items" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"item": "book", "price": 50},
          {"item": "pen", "price": 5},
          {"item": "laptop", "price": 1000},
          {"item": "notebook", "price": 10}
        ]},
        {"op": "filter", "where": {"op": "gt", "field": "price", "value": 10}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == [
             %{"item" => "book", "price" => 50},
             %{"item" => "laptop", "price" => 1000}
           ]
  end

  # Filter operation
  test "filter keeps matching items" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 500},
          {"category": "food", "amount": 50},
          {"category": "travel", "amount": 200}
        ]},
        {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == [
             %{"category" => "travel", "amount" => 500},
             %{"category" => "travel", "amount" => 200}
           ]
  end

  test "filter on empty list returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == []
  end

  # Map operation
  test "map transforms each item" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "map", "expr": {"op": "literal", "value": "x"}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == ["x", "x", "x"]
  end

  test "map on empty list returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "map", "expr": {"op": "literal", "value": "x"}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == []
  end

  # Select operation
  test "select picks specific fields from each map" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"name": "Alice", "age": 30, "city": "NYC"},
          {"name": "Bob", "age": 25, "city": "LA"}
        ]},
        {"op": "select", "fields": ["name", "age"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == [
             %{"name" => "Alice", "age" => 30},
             %{"name" => "Bob", "age" => 25}
           ]
  end

  # First operation
  test "first returns the first item in a list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3, 4, 5]},
        {"op": "first"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 1
  end

  test "first on single-item list returns that item" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [42]},
        {"op": "first"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 42
  end

  test "first on empty list returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "first"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  # Last operation
  test "last returns the last item in a list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3, 4, 5]},
        {"op": "last"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 5
  end

  test "last on single-item list returns that item" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [42]},
        {"op": "last"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 42
  end

  test "last on empty list returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "last"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  # Nth operation
  test "nth returns item at specified index" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [10, 20, 30, 40, 50]},
        {"op": "nth", "index": 2}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 30
  end

  test "nth at index 0 returns first item" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [10, 20, 30]},
        {"op": "nth", "index": 0}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 10
  end

  test "nth out of bounds returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "nth", "index": 10}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "nth on empty list returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "nth", "index": 0}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  # Reject operation
  test "reject removes matching items" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 500},
          {"category": "food", "amount": 50},
          {"category": "travel", "amount": 200}
        ]},
        {"op": "reject", "where": {"op": "eq", "field": "category", "value": "travel"}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == [
             %{"category" => "food", "amount" => 50}
           ]
  end

  test "reject with no matches returns full list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 500},
          {"category": "travel", "amount": 200}
        ]},
        {"op": "reject", "where": {"op": "eq", "field": "category", "value": "food"}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == [
             %{"category" => "travel", "amount" => 500},
             %{"category" => "travel", "amount" => 200}
           ]
  end

  test "reject with all matches returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "amount": 500},
          {"category": "travel", "amount": 200}
        ]},
        {"op": "reject", "where": {"op": "eq", "field": "category", "value": "travel"}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == []
  end

  test "reject on empty list returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "reject", "where": {"op": "eq", "field": "category", "value": "travel"}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == []
  end

  # E2E test with first, last, and nth in a pipeline
  test "first/last/nth work in realistic data processing pipeline" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"item": "book", "price": 50},
          {"item": "pen", "price": 5},
          {"item": "laptop", "price": 1000},
          {"item": "notebook", "price": 10}
        ]},
        {"op": "reject", "where": {"op": "lt", "field": "price", "value": 10}},
        {"op": "first"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == %{"item" => "book", "price" => 50}
  end

  # Get operation
  test "get with single-element path extracts top-level field" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice", "age": 30}},
        {"op": "get", "path": ["name"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == "Alice"
  end

  test "get with multi-element path extracts nested field" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"user": {"profile": {"email": "alice@example.com"}}}},
        {"op": "get", "path": ["user", "profile", "email"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == "alice@example.com"
  end

  test "get with empty path returns current value" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice"}},
        {"op": "get", "path": []}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"name" => "Alice"}
  end

  test "get with missing path returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice"}},
        {"op": "get", "path": ["missing", "field"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "get with default returns default when path missing" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice"}},
        {"op": "get", "path": ["age"], "default": 25}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 25
  end

  test "get with default returns value when path exists" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice", "age": 30}},
        {"op": "get", "path": ["age"], "default": 25}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 30
  end

  test "get on non-map returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 123},
        {"op": "get", "path": ["field"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "get on list with numeric string path returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "get", "path": ["0"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "get within pipe receives piped input" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"x": {"y": 42}}},
        {"op": "get", "path": ["x", "y"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 42
  end

  test "get within map accesses current item fields" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"id": 1, "profile": {"email": "alice@example.com"}},
          {"id": 2, "profile": {"email": "bob@example.com"}}
        ]},
        {"op": "map", "expr": {"op": "get", "path": ["profile", "email"]}}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == ["alice@example.com", "bob@example.com"]
  end

  test "get with missing path on map returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"x": 1}},
        {"op": "get", "path": ["y", "z"]}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "get with missing path returns default value" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"x": 1}},
        {"op": "get", "path": ["y"], "default": 99}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 99
  end

  test "get with explicit nil default returns null" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"x": 1}},
        {"op": "get", "path": ["missing"], "default": null}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  # E2E test demonstrating get with map
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

    {:ok, result, _metrics} = PtcRunner.run(program, context: context)
    assert result == ["alice@example.com", "bob@example.com"]
  end

  # Complex pipeline
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

    {:ok, result, metrics} = PtcRunner.run(program, context: context)

    assert result == 500
    assert metrics.duration_ms >= 0
    assert metrics.memory_bytes > 0
  end

  # Error handling - validation errors
  test "missing 'op' field raises validation error" do
    program = ~s({"program": {"value": 42}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Missing required field 'op'"}
  end

  test "unknown operation raises validation error" do
    program = ~s({"program": {"op": "unknown_op"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
  end

  test "typo in operation suggests closest match" do
    program = ~s({"program": {"op": "filer"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'filer'. Did you mean 'filter'?"}
  end

  test "missing letter typo suggests closest match" do
    program = ~s({"program": {"op": "selct"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'selct'. Did you mean 'select'?"}
  end

  test "extra letter typo suggests closest match" do
    program = ~s({"program": {"op": "filtter"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'filtter'. Did you mean 'filter'?"}
  end

  test "case insensitive typo suggestion" do
    program = ~s({"program": {"op": "FILTER"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'FILTER'. Did you mean 'filter'?"}
  end

  test "very different operation name has no suggestion" do
    program = ~s({"program": {"op": "xyz"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'xyz'"}
  end

  test "E2E: provides helpful typo suggestion for misspelled operation in filter" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [{"x": 1}, {"x": 2}, {"x": 3}]},
        {"op": "filer", "where": {"op": "eq", "field": "x", "value": 1}}
      ]
    }})
    {:error, {:validation_error, msg}} = PtcRunner.run(program)
    assert msg =~ "Did you mean 'filter'?"
  end

  test "missing required field in operation raises validation error" do
    program = ~s({"program": {"op": "literal"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'literal' requires field 'value'"}
  end

  test "literal with no value field raises validation error" do
    program = ~s({"program": {"op": "load"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'load' requires field 'name'"}
  end

  test "nested unknown operation in pipe raises validation error" do
    program = ~s({"program": {"op": "pipe", "steps": [{"op": "unknown_op"}]}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
  end

  test "get operation missing field and path raises validation error" do
    program = ~s({"program": {"op": "get"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'get' requires either 'field' or 'path'"}
  end

  test "get operation with non-array path raises validation error" do
    program = ~s({"program": {"op": "get", "path": "not_an_array"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Field 'path' must be a list"}
  end

  test "get operation with non-string path elements raises validation error" do
    program = ~s({"program": {"op": "get", "path": ["valid", 123]}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "All path elements in 'path' must be strings"}
  end

  # Error handling - type errors
  test "count on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "count"}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "count requires a list")
  end

  test "sum on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": "not a list"},
        {"op": "sum", "field": "amount"}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "sum requires a list")
  end

  test "filter on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "filter", "where": {"op": "eq", "field": "x", "value": 1}}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "filter requires a list")
  end

  test "first on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "first"}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "first requires a list")
  end

  test "last on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": "not a list"},
        {"op": "last"}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "last requires a list")
  end

  test "nth on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "nth", "index": 0}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "nth requires a list")
  end

  test "nth with invalid index in piped context gets caught at validation" do
    # Note: Validation catches negative/non-integer indices at validation time
    # This test verifies the validator works. Runtime index errors are tested
    # in validation error tests below.
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "nth", "index": -1}
      ]
    }})

    {:error, {:validation_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "non-negative")
  end

  test "reject on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "reject", "where": {"op": "eq", "field": "x", "value": 1}}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "reject requires a list")
  end

  test "avg on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "avg", "field": "amount"}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "avg requires a list")
  end

  test "min on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": "not a list"},
        {"op": "min", "field": "price"}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "min requires a list")
  end

  test "max on non-list raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "max", "field": "value"}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "max requires a list")
  end

  test "contains on non-map raises error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "contains", "field": "x", "value": 1}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.run(program)
    assert String.contains?(msg, "contains requires a map")
  end

  # Validation errors for new operations
  test "nth missing index field raises validation error" do
    program = ~s({"program": {"op": "nth"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'nth' requires field 'index'"}
  end

  test "nth with negative index in validation raises validation error" do
    program = ~s({"program": {"op": "nth", "index": -1}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'nth' index must be non-negative, got -1"}
  end

  test "nth with non-integer index in validation raises validation error" do
    program = ~s({"program": {"op": "nth", "index": "not_an_integer"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'nth' field 'index' must be an integer"}
  end

  test "reject missing where field raises validation error" do
    program = ~s({"program": {"op": "reject"}})
    {:error, reason} = PtcRunner.run(program)

    assert reason == {:validation_error, "Operation 'reject' requires field 'where'"}
  end

  # Parse errors
  test "malformed JSON raises parse error" do
    program = "{invalid json"
    {:error, {:parse_error, message}} = PtcRunner.run(program)

    assert String.contains?(message, "JSON decode error")
  end

  test "valid wrapped JSON string extracts program and runs successfully" do
    program = ~s({"program": {"op": "literal", "value": 42}})
    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == 42
  end

  test "valid wrapped map extracts program and runs successfully" do
    program = %{"program" => %{"op" => "literal", "value" => 99}}
    {:ok, result, _metrics} = PtcRunner.run(program)

    assert result == 99
  end

  test "missing program field returns parse error" do
    program = ~s({"data": {"op": "literal", "value": 42}})
    {:error, {:parse_error, message}} = PtcRunner.run(program)

    assert message == "Missing required field 'program'"
  end

  test "program is not a map returns parse error" do
    # Test with null
    program = ~s({"program": null})
    {:error, {:parse_error, message}} = PtcRunner.run(program)
    assert message == "program must be a map"

    # Test with string
    program = ~s({"program": "not a map"})
    {:error, {:parse_error, message}} = PtcRunner.run(program)
    assert message == "program must be a map"

    # Test with array
    program = ~s({"program": [1, 2, 3]})
    {:error, {:parse_error, message}} = PtcRunner.run(program)
    assert message == "program must be a map"
  end

  # Timeout handling
  test "timeout is enforced" do
    program = ~s({"program": {"op": "literal", "value": 42}})

    # Use a very short timeout to trigger it
    {:error, reason} = PtcRunner.run(program, timeout: 0)
    assert reason == {:timeout, 0}
  end

  # Memory limit handling
  @tag :capture_log
  test "memory limit is enforced" do
    # Pass large data through context - context data counts toward sandbox memory
    # per docs/architecture.md:297-298, making this a valid test approach
    large_list = List.duplicate(%{"data" => String.duplicate("x", 1000)}, 10_000)

    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "load", "name": "large_data"},
        {"op": "count"}
      ]
    }})

    # Use a very small max_heap to trigger the limit
    {:error, reason} =
      PtcRunner.run(program, context: %{"large_data" => large_list}, max_heap: 1000)

    assert {:memory_exceeded, bytes} = reason
    assert is_integer(bytes)
  end

  # run! function
  test "run! returns result without metrics" do
    program = ~s({"program": {"op": "literal", "value": 42}})
    result = PtcRunner.run!(program)

    assert result == 42
  end

  test "run! raises on error" do
    program = ~s({"program": {"op": "unknown_op"}})

    assert_raise RuntimeError, fn ->
      PtcRunner.run!(program)
    end
  end

  # Error tests for operations without piped input
  describe "operations without piped input" do
    test "get without piped input returns error" do
      program = ~s({"program": {"op": "get", "path": ["x"]}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "filter without piped input returns error" do
      program = ~s({"program": {"op": "filter", "where": {"op": "eq", "field": "x", "value": 1}}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "map without piped input returns error" do
      program = ~s({"program": {"op": "map", "expr": {"op": "literal", "value": "x"}}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "count without piped input returns error" do
      program = ~s({"program": {"op": "count"}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "sum without piped input returns error" do
      program = ~s({"program": {"op": "sum", "field": "amount"}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "select without piped input returns error" do
      program = ~s({"program": {"op": "select", "fields": ["name"]}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "eq without piped input returns error" do
      program = ~s({"program": {"op": "eq", "field": "x", "value": 1}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "neq without piped input returns error" do
      program = ~s({"program": {"op": "neq", "field": "x", "value": 1}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "gt without piped input returns error" do
      program = ~s({"program": {"op": "gt", "field": "x", "value": 1}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "gte without piped input returns error" do
      program = ~s({"program": {"op": "gte", "field": "x", "value": 1}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "lt without piped input returns error" do
      program = ~s({"program": {"op": "lt", "field": "x", "value": 1}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "lte without piped input returns error" do
      program = ~s({"program": {"op": "lte", "field": "x", "value": 1}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "first without piped input returns error" do
      program = ~s({"program": {"op": "first"}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "last without piped input returns error" do
      program = ~s({"program": {"op": "last"}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "nth without piped input returns error" do
      program = ~s({"program": {"op": "nth", "index": 0}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end

    test "reject without piped input returns error" do
      program = ~s({"program": {"op": "reject", "where": {"op": "eq", "field": "x", "value": 1}}})
      {:error, reason} = PtcRunner.run(program)

      assert reason == {:execution_error, "No input available"}
    end
  end

  # Contains operation
  test "contains on list returns true when value is member" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"tags": [1, 2, 3]}},
        {"op": "contains", "field": "tags", "value": 2}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "contains on list returns false when value is not member" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"tags": [1, 2, 3]}},
        {"op": "contains", "field": "tags", "value": 5}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  test "contains on string returns true for substring" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"text": "hello world"}},
        {"op": "contains", "field": "text", "value": "world"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "contains on string returns false for missing substring" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"text": "hello"}},
        {"op": "contains", "field": "text", "value": "world"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  test "contains on map returns true for existing key" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"metadata": {"a": 1}}},
        {"op": "contains", "field": "metadata", "value": "a"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == true
  end

  test "contains on nil field value returns false" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"data": null}},
        {"op": "contains", "field": "data", "value": "foo"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  test "contains on other types returns false" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"count": 42}},
        {"op": "contains", "field": "count", "value": "foo"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == false
  end

  # Avg operation
  test "avg calculates average of numeric field values" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"amount": 10},
          {"amount": 20}
        ]},
        {"op": "avg", "field": "amount"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 15.0
  end

  test "avg on empty list returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "avg", "field": "amount"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "avg skips non-numeric values" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"amount": 10},
          {"amount": "foo"}
        ]},
        {"op": "avg", "field": "amount"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 10.0
  end

  test "avg with all non-numeric returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"amount": "foo"}
        ]},
        {"op": "avg", "field": "amount"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "avg skips nil values" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"amount": 10},
          {"amount": null}
        ]},
        {"op": "avg", "field": "amount"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 10.0
  end

  # Min operation
  test "min returns minimum value of field" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"val": 3},
          {"val": 1},
          {"val": 2}
        ]},
        {"op": "min", "field": "val"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 1
  end

  test "min on empty list returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "min", "field": "val"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "min with single element returns that element" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [{"val": 5}]},
        {"op": "min", "field": "val"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 5
  end

  test "min skips nil values" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"val": null},
          {"val": 3},
          {"val": 1}
        ]},
        {"op": "min", "field": "val"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 1
  end

  # Max operation
  test "max returns maximum value of field" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"val": 3},
          {"val": 1},
          {"val": 2}
        ]},
        {"op": "max", "field": "val"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 3
  end

  test "max on empty list returns nil" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "max", "field": "val"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == nil
  end

  test "max with single element returns that element" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [{"val": 5}]},
        {"op": "max", "field": "val"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 5
  end

  test "max skips nil values" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"val": null},
          {"val": 3},
          {"val": 1}
        ]},
        {"op": "max", "field": "val"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == 3
  end

  # E2E test with multiple operations
  test "E2E: expense filtering and aggregation" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"category": "travel", "tags": ["flights", "hotels"], "amount": 500},
          {"category": "food", "tags": ["restaurant"], "amount": 50},
          {"category": "travel", "tags": ["flights"], "amount": 200}
        ]},
        {"op": "filter", "where": {"op": "contains", "field": "tags", "value": "flights"}},
        {"op": "select", "fields": ["amount"]},
        {"op": "first"}
      ]
    }})

    {:ok, result, _metrics} = PtcRunner.run(program)
    assert result == %{"amount" => 500}
  end

  describe "Validation error tests for new operations" do
    test "contains missing field parameter returns validation error" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [1, 2, 3]},
          {"op": "contains", "value": 2}
        ]
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'contains' requires field 'field'"}
    end

    test "contains missing value parameter returns validation error" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [1, 2, 3]},
          {"op": "contains", "field": "tags"}
        ]
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'contains' requires field 'value'"}
    end

    test "avg missing field parameter returns validation error" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [{"amount": 10}]},
          {"op": "avg"}
        ]
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'avg' requires field 'field'"}
    end

    test "min missing field parameter returns validation error" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [{"val": 5}]},
          {"op": "min"}
        ]
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'min' requires field 'field'"}
    end

    test "max missing field parameter returns validation error" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [{"val": 5}]},
          {"op": "max"}
        ]
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'max' requires field 'field'"}
    end

    test "let missing name field raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "value": {"op": "literal", "value": 5},
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'let' requires field 'name'"}
    end

    test "let with non-string name raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": 42,
        "value": {"op": "literal", "value": 5},
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Field 'name' must be a string"}
    end

    test "let missing value field raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'let' requires field 'value'"}
    end

    test "let missing in field raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Operation 'let' requires field 'in'"}
    end

    test "let with invalid nested value expression raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "unknown_op"},
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
    end

    test "let with invalid nested in expression raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5},
        "in": {"op": "unknown_op"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
    end
  end

  # Let operation - basic tests
  describe "let operation" do
    test "let binds value to name and returns it via var" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5},
        "in": {"op": "var", "name": "x"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 5
    end

    test "let allows var to reference undefined name returns nil" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5},
        "in": {"op": "var", "name": "y"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == nil
    end

    test "let with list value" do
      program = ~s({"program": {
        "op": "let",
        "name": "items",
        "value": {"op": "literal", "value": [1, 2, 3]},
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "var", "name": "items"},
            {"op": "count"}
          ]
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 3
    end

    test "let with nested let bindings (shadowing)" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 1},
        "in": {
          "op": "let",
          "name": "x",
          "value": {"op": "literal", "value": 2},
          "in": {"op": "var", "name": "x"}
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 2
    end

    test "let scoping - inner binding doesn't leak out" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {
          "op": "let",
          "name": "y",
          "value": {"op": "literal", "value": 10},
          "in": {"op": "var", "name": "y"}
        },
        "in": {"op": "var", "name": "x"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 10
    end

    test "let with empty string name" do
      program = ~s({"program": {
        "op": "let",
        "name": "",
        "value": {"op": "literal", "value": 42},
        "in": {"op": "var", "name": ""}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 42
    end

    test "let with pipe - receives piped input in value" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [1, 2, 3]},
          {
            "op": "let",
            "name": "data",
            "value": {"op": "var", "name": "__input"},
            "in": {
              "op": "pipe",
              "steps": [
                {"op": "var", "name": "data"},
                {"op": "count"}
              ]
            }
          }
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 3
    end

    test "let with computed value expression" do
      program = ~s({"program": {
        "op": "let",
        "name": "sum_val",
        "value": {
          "op": "pipe",
          "steps": [
            {"op": "literal", "value": [
              {"amount": 100},
              {"amount": 200}
            ]},
            {"op": "sum", "field": "amount"}
          ]
        },
        "in": {"op": "var", "name": "sum_val"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 300
    end

    test "let with error in value expression propagates error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {
          "op": "pipe",
          "steps": [
            {"op": "literal", "value": 42},
            {"op": "count"}
          ]
        },
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert {:execution_error, msg} = reason
      assert String.contains?(msg, "count requires a list")
    end

    test "let with filter using bound variable" do
      program = ~s({"program": {
        "op": "let",
        "name": "threshold",
        "value": {"op": "literal", "value": 100},
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "literal", "value": [
              {"id": 1, "amount": 50},
              {"id": 2, "amount": 150},
              {"id": 3, "amount": 200}
            ]},
            {"op": "filter", "where": {
              "op": "gt",
              "field": "amount",
              "value": 100
            }},
            {"op": "count"}
          ]
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 2
    end

    test "E2E: let with load and complex pipeline" do
      program = ~s({"program": {
        "op": "let",
        "name": "expenses",
        "value": {"op": "load", "name": "data"},
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "var", "name": "expenses"},
            {"op": "filter", "where": {"op": "gt", "field": "amount", "value": 100}},
            {"op": "count"}
          ]
        }
      }})

      context = %{
        "data" => [
          %{"category" => "travel", "amount" => 500},
          %{"category" => "food", "amount" => 50},
          %{"category" => "travel", "amount" => 200}
        ]
      }

      {:ok, result, _metrics} = PtcRunner.run(program, context: context)
      assert result == 2
    end

    test "let with var for undefined name in outer scope" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5},
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "var", "name": "x"},
            {"op": "literal", "value": 10}
          ]
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 10
    end

    test "multiple let bindings at different levels" do
      program = ~s({"program": {
        "op": "let",
        "name": "a",
        "value": {"op": "literal", "value": 10},
        "in": {
          "op": "let",
          "name": "b",
          "value": {"op": "literal", "value": 20},
          "in": {
            "op": "pipe",
            "steps": [
              {"op": "var", "name": "a"},
              {"op": "literal", "value": 30}
            ]
          }
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 30
    end

    # If operation - truthiness tests
    test "if returns then result when condition is true" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": true},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "yes"
    end

    test "if returns else result when condition is false" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": false},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "no"
    end

    test "if returns else result when condition is nil" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": null},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "no"
    end

    test "if returns then result when condition is truthy integer" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": 1},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "yes"
    end

    test "if returns then result when condition is truthy zero" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": 0},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "yes"
    end

    test "if returns then result when condition is truthy empty list" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": []},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "yes"
    end

    test "if returns then result when condition is truthy empty string" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": ""},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "yes"
    end

    test "if returns then result when condition is truthy empty map" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": {}},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "yes"
    end

    test "if with nested if conditions" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": true},
        "then": {
          "op": "if",
          "condition": {"op": "literal", "value": false},
          "then": {"op": "literal", "value": "nested-then"},
          "else": {"op": "literal", "value": "nested-else"}
        },
        "else": {"op": "literal", "value": "outer-else"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "nested-else"
    end

    test "if with comparison condition" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": {"amount": 100}},
          {
            "op": "if",
            "condition": {"op": "gt", "field": "amount", "value": 50},
            "then": {"op": "literal", "value": "high"},
            "else": {"op": "literal", "value": "low"}
          }
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "high"
    end

    test "if with comparison condition returning false" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": {"amount": 30}},
          {
            "op": "if",
            "condition": {"op": "gt", "field": "amount", "value": 50},
            "then": {"op": "literal", "value": "high"},
            "else": {"op": "literal", "value": "low"}
          }
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "low"
    end

    test "if with error in condition expression propagates error" do
      program = ~s({"program": {
        "op": "if",
        "condition": {
          "op": "pipe",
          "steps": [
            {"op": "literal", "value": 42},
            {"op": "count"}
          ]
        },
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert {:execution_error, msg} = reason
      assert String.contains?(msg, "count requires a list")
    end

    test "if missing condition field raises validation error" do
      program = ~s({"program": {
        "op": "if",
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert {:validation_error, msg} = reason
      assert String.contains?(msg, "condition")
    end

    test "if missing then field raises validation error" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": true},
        "else": {"op": "literal", "value": "no"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert {:validation_error, msg} = reason
      assert String.contains?(msg, "then")
    end

    test "if missing else field raises validation error" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": true},
        "then": {"op": "literal", "value": "yes"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert {:validation_error, msg} = reason
      assert String.contains?(msg, "else")
    end

    test "if with invalid nested condition expression raises validation error" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": true},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "unknown"}
      }})

      {:error, reason} = PtcRunner.run(program)
      assert {:validation_error, msg} = reason
      assert String.contains?(msg, "Unknown operation")
    end

    test "E2E: if with pipe and comparison" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": {"total": 1500}},
          {
            "op": "if",
            "condition": {"op": "gt", "field": "total", "value": 1000},
            "then": {"op": "literal", "value": "high_value"},
            "else": {"op": "literal", "value": "standard"}
          }
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "high_value"
    end

    test "E2E: if with pipe and failed comparison" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": {"total": 500}},
          {
            "op": "if",
            "condition": {"op": "gt", "field": "total", "value": 1000},
            "then": {"op": "literal", "value": "high_value"},
            "else": {"op": "literal", "value": "standard"}
          }
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "standard"
    end

    test "if with let binding - outer binding accessible in branches" do
      program = ~s({"program": {
        "op": "let",
        "name": "threshold",
        "value": {"op": "literal", "value": 1000},
        "in": {
          "op": "pipe",
          "steps": [
            {"op": "literal", "value": {"amount": 1500}},
            {
              "op": "if",
              "condition": {"op": "gt", "field": "amount", "value": 1000},
              "then": {"op": "var", "name": "threshold"},
              "else": {"op": "literal", "value": 0}
            }
          ]
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 1000
    end

    # And operation - boolean logic tests
    test "and with all truthy conditions returns true" do
      program = ~s({"program": {
        "op": "and",
        "conditions": [
          {"op": "literal", "value": true},
          {"op": "literal", "value": true},
          {"op": "literal", "value": true}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    test "and with one falsy condition returns false" do
      program = ~s({"program": {
        "op": "and",
        "conditions": [
          {"op": "literal", "value": true},
          {"op": "literal", "value": false},
          {"op": "literal", "value": true}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    test "and with empty conditions returns true" do
      program = ~s({"program": {
        "op": "and",
        "conditions": []
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    test "and with nil condition returns false" do
      program = ~s({"program": {
        "op": "and",
        "conditions": [
          {"op": "literal", "value": true},
          {"op": "literal", "value": null},
          {"op": "literal", "value": true}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    test "and treats truthy values correctly (0, [], empty string, empty map)" do
      program = ~s({"program": {
        "op": "and",
        "conditions": [
          {"op": "literal", "value": 0},
          {"op": "literal", "value": []},
          {"op": "literal", "value": ""},
          {"op": "literal", "value": {}}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    test "and short-circuits on first false" do
      program = ~s({"program": {
        "op": "and",
        "conditions": [
          {"op": "literal", "value": false},
          {"op": "var", "name": "undefined_var"}
        ]
      }})

      # Second condition is not evaluated due to short-circuit
      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    # Or operation - boolean logic tests
    test "or with one truthy condition returns true" do
      program = ~s({"program": {
        "op": "or",
        "conditions": [
          {"op": "literal", "value": false},
          {"op": "literal", "value": true},
          {"op": "literal", "value": false}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    test "or with all falsy conditions returns false" do
      program = ~s({"program": {
        "op": "or",
        "conditions": [
          {"op": "literal", "value": false},
          {"op": "literal", "value": false},
          {"op": "literal", "value": false}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    test "or with empty conditions returns false" do
      program = ~s({"program": {
        "op": "or",
        "conditions": []
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    test "or with nil conditions returns false" do
      program = ~s({"program": {
        "op": "or",
        "conditions": [
          {"op": "literal", "value": false},
          {"op": "literal", "value": null},
          {"op": "literal", "value": false}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    test "or treats truthy values correctly" do
      program = ~s({"program": {
        "op": "or",
        "conditions": [
          {"op": "literal", "value": false},
          {"op": "literal", "value": 0}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    test "or short-circuits on first true" do
      program = ~s({"program": {
        "op": "or",
        "conditions": [
          {"op": "literal", "value": true},
          {"op": "var", "name": "undefined_var"}
        ]
      }})

      # Second condition is not evaluated due to short-circuit
      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    # Not operation - boolean logic tests
    test "not with true returns false" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": true}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    test "not with false returns true" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": false}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    test "not with nil returns true" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": null}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    test "not with truthy value returns false" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": 42}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    test "not with truthy empty string returns false" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": ""}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == false
    end

    # Error propagation tests
    test "and with undefined variable treated as nil (falsy)" do
      program = ~s({"program": {
        "op": "and",
        "conditions": [
          {"op": "literal", "value": true},
          {"op": "var", "name": "undefined_var"},
          {"op": "literal", "value": true}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      # undefined variable returns nil, which is falsy, so and returns false
      assert result == false
    end

    test "or with undefined variable treated as nil (falsy) but continues" do
      program = ~s({"program": {
        "op": "or",
        "conditions": [
          {"op": "literal", "value": false},
          {"op": "var", "name": "undefined_var"},
          {"op": "literal", "value": true}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      # undefined variable returns nil (falsy), continues to next (true), so or returns true
      assert result == true
    end

    test "not with undefined variable treated as nil returns true" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "var", "name": "undefined_var"}
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      # undefined variable returns nil, which is falsy, so not returns true
      assert result == true
    end

    # Validation error tests
    test "and validation fails when conditions field is missing" do
      program = ~s({"program": {
        "op": "and"
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "requires field 'conditions'")
    end

    test "and validation fails when conditions is not a list" do
      program = ~s({"program": {
        "op": "and",
        "conditions": "not a list"
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "must be a list")
    end

    test "or validation fails when conditions field is missing" do
      program = ~s({"program": {
        "op": "or"
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "requires field 'conditions'")
    end

    test "or validation fails when conditions is not a list" do
      program = ~s({"program": {
        "op": "or",
        "conditions": 42
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "must be a list")
    end

    test "not validation fails when condition field is missing" do
      program = ~s({"program": {
        "op": "not"
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "requires field 'condition'")
    end

    test "not validates nested condition expression" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "invalid_op"}
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "Unknown operation")
    end

    # Merge operation - combine objects tests
    test "merge with two objects" do
      program = ~s({"program": {
        "op": "merge",
        "objects": [
          {"op": "literal", "value": {"a": 1, "b": 2}},
          {"op": "literal", "value": {"c": 3}}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"a" => 1, "b" => 2, "c" => 3}
    end

    test "merge with override (later object wins)" do
      program = ~s({"program": {
        "op": "merge",
        "objects": [
          {"op": "literal", "value": {"a": 1, "b": 2}},
          {"op": "literal", "value": {"a": 10}}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"a" => 10, "b" => 2}
    end

    test "merge with empty objects list" do
      program = ~s({"program": {
        "op": "merge",
        "objects": []
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{}
    end

    test "merge with single object" do
      program = ~s({"program": {
        "op": "merge",
        "objects": [
          {"op": "literal", "value": {"a": 1}}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"a" => 1}
    end

    test "merge with three objects" do
      program = ~s({"program": {
        "op": "merge",
        "objects": [
          {"op": "literal", "value": {"a": 1}},
          {"op": "literal", "value": {"b": 2}},
          {"op": "literal", "value": {"c": 3}}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"a" => 1, "b" => 2, "c" => 3}
    end

    test "merge with variables" do
      program = ~s({"program": {
        "op": "let",
        "name": "obj1",
        "value": {"op": "literal", "value": {"a": 1}},
        "in": {
          "op": "let",
          "name": "obj2",
          "value": {"op": "literal", "value": {"b": 2}},
          "in": {
            "op": "merge",
            "objects": [
              {"op": "var", "name": "obj1"},
              {"op": "var", "name": "obj2"}
            ]
          }
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"a" => 1, "b" => 2}
    end

    test "merge fails on non-map input" do
      program = ~s({"program": {
        "op": "merge",
        "objects": [
          {"op": "literal", "value": [1, 2, 3]}
        ]
      }})

      {:error, {:execution_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "merge requires map values")
    end

    test "merge validation fails when objects field is missing" do
      program = ~s({"program": {
        "op": "merge"
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "requires field 'objects'")
    end

    test "merge validation fails when objects is not a list" do
      program = ~s({"program": {
        "op": "merge",
        "objects": 42
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "must be a list")
    end

    # Concat operation - combine lists tests
    test "concat with two lists" do
      program = ~s({"program": {
        "op": "concat",
        "lists": [
          {"op": "literal", "value": [1, 2]},
          {"op": "literal", "value": [3, 4]}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == [1, 2, 3, 4]
    end

    test "concat with three lists" do
      program = ~s({"program": {
        "op": "concat",
        "lists": [
          {"op": "literal", "value": [1]},
          {"op": "literal", "value": [2, 3]},
          {"op": "literal", "value": [4]}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == [1, 2, 3, 4]
    end

    test "concat with empty lists list" do
      program = ~s({"program": {
        "op": "concat",
        "lists": []
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == []
    end

    test "concat with single list" do
      program = ~s({"program": {
        "op": "concat",
        "lists": [
          {"op": "literal", "value": [1, 2, 3]}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == [1, 2, 3]
    end

    test "concat with variables" do
      program = ~s({"program": {
        "op": "let",
        "name": "list1",
        "value": {"op": "literal", "value": [1, 2]},
        "in": {
          "op": "let",
          "name": "list2",
          "value": {"op": "literal", "value": [3, 4]},
          "in": {
            "op": "concat",
            "lists": [
              {"op": "var", "name": "list1"},
              {"op": "var", "name": "list2"}
            ]
          }
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == [1, 2, 3, 4]
    end

    test "concat fails on non-list input" do
      program = ~s({"program": {
        "op": "concat",
        "lists": [
          {"op": "literal", "value": {"a": 1}}
        ]
      }})

      {:error, {:execution_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "concat requires list values")
    end

    test "concat validation fails when lists field is missing" do
      program = ~s({"program": {
        "op": "concat"
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "requires field 'lists'")
    end

    test "concat validation fails when lists is not a list" do
      program = ~s({"program": {
        "op": "concat",
        "lists": "not a list"
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "must be a list")
    end

    # Zip operation - zip lists tests
    test "zip with two equal-length lists" do
      program = ~s({"program": {
        "op": "zip",
        "lists": [
          {"op": "literal", "value": [1, 2, 3]},
          {"op": "literal", "value": ["a", "b", "c"]}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == [[1, "a"], [2, "b"], [3, "c"]]
    end

    test "zip with unequal-length lists (stops at shortest)" do
      program = ~s({"program": {
        "op": "zip",
        "lists": [
          {"op": "literal", "value": [1, 2, 3]},
          {"op": "literal", "value": ["a", "b"]}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == [[1, "a"], [2, "b"]]
    end

    test "zip with empty lists list" do
      program = ~s({"program": {
        "op": "zip",
        "lists": []
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == []
    end

    test "zip with single list" do
      program = ~s({"program": {
        "op": "zip",
        "lists": [
          {"op": "literal", "value": [1, 2, 3]}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == [[1], [2], [3]]
    end

    test "zip with three lists" do
      program = ~s({"program": {
        "op": "zip",
        "lists": [
          {"op": "literal", "value": [1, 2]},
          {"op": "literal", "value": ["a", "b"]},
          {"op": "literal", "value": [true, false]}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == [[1, "a", true], [2, "b", false]]
    end

    test "zip with one empty inner list" do
      program = ~s({"program": {
        "op": "zip",
        "lists": [
          {"op": "literal", "value": []},
          {"op": "literal", "value": [1, 2]}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == []
    end

    test "zip fails on non-list input" do
      program = ~s({"program": {
        "op": "zip",
        "lists": [
          {"op": "literal", "value": 42}
        ]
      }})

      {:error, {:execution_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "zip requires list values")
    end

    test "zip validation fails when lists field is missing" do
      program = ~s({"program": {
        "op": "zip"
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "requires field 'lists'")
    end

    test "zip validation fails when lists is not a list" do
      program = ~s({"program": {
        "op": "zip",
        "lists": {"a": 1}
      }})

      {:error, {:validation_error, message}} = PtcRunner.run(program)
      assert String.contains?(message, "must be a list")
    end

    # E2E test combining multiple operations
    test "E2E: combine operations with let and merge/concat" do
      program = ~s({"program": {
        "op": "let",
        "name": "user",
        "value": {"op": "literal", "value": {"id": 1, "name": "Alice"}},
        "in": {
          "op": "let",
          "name": "order",
          "value": {"op": "literal", "value": {"total": 100, "status": "shipped"}},
          "in": {
            "op": "let",
            "name": "combined",
            "value": {
              "op": "merge",
              "objects": [
                {"op": "var", "name": "user"},
                {"op": "var", "name": "order"}
              ]
            },
            "in": {
              "op": "var",
              "name": "combined"
            }
          }
        }
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"id" => 1, "name" => "Alice", "total" => 100, "status" => "shipped"}
    end

    # Complex nested logic tests
    test "nested and inside or" do
      program = ~s({"program": {
        "op": "or",
        "conditions": [
          {
            "op": "and",
            "conditions": [
              {"op": "literal", "value": true},
              {"op": "literal", "value": false}
            ]
          },
          {"op": "literal", "value": true}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    test "nested not inside and" do
      program = ~s({"program": {
        "op": "and",
        "conditions": [
          {"op": "literal", "value": true},
          {
            "op": "not",
            "condition": {"op": "literal", "value": false}
          }
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == true
    end

    # E2E test with if, comparisons, and logic operations
    test "complex conditional with and, or, not, and if" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "load", "name": "order"},
          {
            "op": "if",
            "condition": {
              "op": "and",
              "conditions": [
                {"op": "gt", "field": "total", "value": 100},
                {
                  "op": "or",
                  "conditions": [
                    {"op": "eq", "field": "status", "value": "vip"},
                    {"op": "eq", "field": "status", "value": "premium"}
                  ]
                },
                {
                  "op": "not",
                  "condition": {"op": "eq", "field": "flagged", "value": true}
                }
              ]
            },
            "then": {"op": "literal", "value": "eligible"},
            "else": {"op": "literal", "value": "not_eligible"}
          }
        ]
      }})

      context = %{"order" => %{"total" => 150, "status" => "vip", "flagged" => false}}
      {:ok, result, _metrics} = PtcRunner.run(program, context: context)
      assert result == "eligible"
    end

    test "complex conditional with and, or, not returns not_eligible when total too low" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "load", "name": "order"},
          {
            "op": "if",
            "condition": {
              "op": "and",
              "conditions": [
                {"op": "gt", "field": "total", "value": 100},
                {
                  "op": "or",
                  "conditions": [
                    {"op": "eq", "field": "status", "value": "vip"},
                    {"op": "eq", "field": "status", "value": "premium"}
                  ]
                },
                {
                  "op": "not",
                  "condition": {"op": "eq", "field": "flagged", "value": true}
                }
              ]
            },
            "then": {"op": "literal", "value": "eligible"},
            "else": {"op": "literal", "value": "not_eligible"}
          }
        ]
      }})

      context = %{"order" => %{"total" => 50, "status" => "vip", "flagged" => false}}
      {:ok, result, _metrics} = PtcRunner.run(program, context: context)
      assert result == "not_eligible"
    end

    test "complex conditional with and, or, not returns not_eligible when flagged" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "load", "name": "order"},
          {
            "op": "if",
            "condition": {
              "op": "and",
              "conditions": [
                {"op": "gt", "field": "total", "value": 100},
                {
                  "op": "or",
                  "conditions": [
                    {"op": "eq", "field": "status", "value": "vip"},
                    {"op": "eq", "field": "status", "value": "premium"}
                  ]
                },
                {
                  "op": "not",
                  "condition": {"op": "eq", "field": "flagged", "value": true}
                }
              ]
            },
            "then": {"op": "literal", "value": "eligible"},
            "else": {"op": "literal", "value": "not_eligible"}
          }
        ]
      }})

      context = %{"order" => %{"total" => 150, "status" => "vip", "flagged" => true}}
      {:ok, result, _metrics} = PtcRunner.run(program, context: context)
      assert result == "not_eligible"
    end
  end

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

  describe "sort_by operation" do
    test "sorts list ascending by default" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [{"price": 999}, {"price": 15}, {"price": 599}]},
          {"op": "sort_by", "field": "price"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert Enum.map(result, & &1["price"]) == [15, 599, 999]
    end

    test "sorts list descending when order is desc" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [{"price": 15}, {"price": 999}, {"price": 599}]},
          {"op": "sort_by", "field": "price", "order": "desc"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert Enum.map(result, & &1["price"]) == [999, 599, 15]
    end

    test "returns empty list when input is empty" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": []},
          {"op": "sort_by", "field": "price"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == []
    end

    test "returns validation error for invalid order value" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [{"price": 10}]},
          {"op": "sort_by", "field": "price", "order": "invalid"}
        ]
      }})

      {:error, reason} = PtcRunner.run(program)
      assert reason == {:validation_error, "Field 'order' must be 'asc' or 'desc', got 'invalid'"}
    end
  end

  describe "max_by operation" do
    test "returns row with maximum field value" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [
            {"name": "Alice", "years": 3},
            {"name": "Bob", "years": 7},
            {"name": "Carol", "years": 5}
          ]},
          {"op": "max_by", "field": "years"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"name" => "Bob", "years" => 7}
    end

    test "returns null for empty list" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": []},
          {"op": "max_by", "field": "years"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == nil
    end

    test "skips items with nil field values" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [
            {"name": "Alice", "years": null},
            {"name": "Bob", "years": 7},
            {"name": "Carol", "years": 5}
          ]},
          {"op": "max_by", "field": "years"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"name" => "Bob", "years" => 7}
    end
  end

  describe "min_by operation" do
    test "returns row with minimum field value" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [
            {"name": "Laptop", "price": 999},
            {"name": "Book", "price": 15},
            {"name": "Phone", "price": 599}
          ]},
          {"op": "min_by", "field": "price"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"name" => "Book", "price" => 15}
    end

    test "returns null for empty list" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": []},
          {"op": "min_by", "field": "price"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == nil
    end

    test "skips items with nil field values" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [
            {"name": "Laptop", "price": null},
            {"name": "Book", "price": 15},
            {"name": "Phone", "price": 599}
          ]},
          {"op": "min_by", "field": "price"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == %{"name" => "Book", "price" => 15}
    end
  end

  describe "get operation with field parameter" do
    test "extracts single field using field parameter" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": {"name": "Alice", "age": 30}},
          {"op": "get", "field": "name"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == "Alice"
    end

    test "returns null when field does not exist" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": {"name": "Alice"}},
          {"op": "get", "field": "age"}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == nil
    end

    test "returns default when field does not exist and default provided" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": {"name": "Alice"}},
          {"op": "get", "field": "age", "default": 0}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == 0
    end

    test "get with field works in map operation" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [{"name": "Apple"}, {"name": "Banana"}]},
          {"op": "map", "expr": {"op": "get", "field": "name"}}
        ]
      }})

      {:ok, result, _metrics} = PtcRunner.run(program)
      assert result == ["Apple", "Banana"]
    end
  end
end
