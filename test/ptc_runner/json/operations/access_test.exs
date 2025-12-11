defmodule PtcRunner.Json.Operations.AccessTest do
  use ExUnit.Case

  # First operation
  test "first returns the first item in a list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3, 4, 5]},
        {"op": "first"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == nil
  end

  # Take operation
  test "take returns first N elements from list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3, 4, 5]},
        {"op": "take", "count": 3}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [1, 2, 3]
  end

  test "take with count=0 returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "take", "count": 0}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "take with count > length returns entire list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "take", "count": 10}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [1, 2, 3]
  end

  test "take on empty list returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "take", "count": 5}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "take requires count parameter" do
    program = ~s({"program": {"op": "take"}})
    {:error, {:validation_error, msg}} = PtcRunner.Json.run(program)
    assert String.contains?(msg, "count")
  end

  test "take rejects negative count" do
    program = ~s({"program": {"op": "take", "count": -1}})
    {:error, {:validation_error, msg}} = PtcRunner.Json.run(program)
    assert String.contains?(msg, "non-negative")
  end

  test "take on non-list raises execution error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "take", "count": 1}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
    assert String.contains?(msg, "take requires a list")
  end

  # Drop operation
  test "drop skips first N elements from list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3, 4, 5]},
        {"op": "drop", "count": 2}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [3, 4, 5]
  end

  test "drop with count=0 returns entire list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "drop", "count": 0}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [1, 2, 3]
  end

  test "drop with count > length returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "drop", "count": 10}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "drop on empty list returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "drop", "count": 5}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "drop requires count parameter" do
    program = ~s({"program": {"op": "drop"}})
    {:error, {:validation_error, msg}} = PtcRunner.Json.run(program)
    assert String.contains?(msg, "count")
  end

  test "drop rejects negative count" do
    program = ~s({"program": {"op": "drop", "count": -1}})
    {:error, {:validation_error, msg}} = PtcRunner.Json.run(program)
    assert String.contains?(msg, "non-negative")
  end

  test "drop on non-list raises execution error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": "string"},
        {"op": "drop", "count": 1}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
    assert String.contains?(msg, "drop requires a list")
  end

  # Distinct operation
  test "distinct removes duplicate values from list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 2, 3, 1, 4]},
        {"op": "distinct"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [1, 2, 3, 4]
  end

  test "distinct preserves first occurrence order" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [3, 1, 2, 1, 3, 2]},
        {"op": "distinct"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [3, 1, 2]
  end

  test "distinct with no duplicates returns same list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "distinct"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [1, 2, 3]
  end

  test "distinct with strings removes duplicates" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": ["apple", "banana", "apple", "cherry"]},
        {"op": "distinct"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == ["apple", "banana", "cherry"]
  end

  test "distinct on empty list returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "distinct"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "distinct with objects uses structural equality" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"id": 1, "name": "Alice"},
          {"id": 2, "name": "Bob"},
          {"id": 1, "name": "Alice"}
        ]},
        {"op": "distinct"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == [
             %{"id" => 1, "name" => "Alice"},
             %{"id" => 2, "name" => "Bob"}
           ]
  end

  test "distinct on non-list raises execution error" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "distinct"}
      ]
    }})

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
    assert String.contains?(msg, "distinct requires a list")
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program, context: context)
    assert result == ["alice@example.com", "bob@example.com"]
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Field 'order' must be 'asc' or 'desc', got 'invalid'"}
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "Alice"
    end

    test "returns default for missing field" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": {"name": "Alice"}},
          {"op": "get", "field": "missing", "default": "N/A"}
        ]
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "N/A"
    end

    test "field parameter can extract from nested map within pipe" do
      program = ~s({"program": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [
            {"id": 1, "profile": {"email": "alice@example.com"}},
            {"id": 2, "profile": {"email": "bob@example.com"}}
          ]},
          {"op": "map", "expr": {"op": "get", "field": "id"}}
        ]
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == [1, 2]
    end

    test "validates that field and path cannot both be specified" do
      program = ~s({"program": {
        "op": "get",
        "field": "name",
        "path": ["user", "name"]
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Operation 'get' accepts 'field' or 'path', not both"}
    end
  end
end
