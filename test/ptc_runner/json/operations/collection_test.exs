defmodule PtcRunner.Json.Operations.CollectionTest do
  use ExUnit.Case

  # Pipe operation
  test "pipe chains operations" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "count"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == 3
  end

  test "empty pipe returns nil" do
    program = ~s({"program": {"op": "pipe", "steps": []}})
    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == nil
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"a" => 10, "b" => 2}
  end

  test "merge with empty objects list" do
    program = ~s({"program": {
      "op": "merge",
      "objects": []
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{}
  end

  test "merge with single object" do
    program = ~s({"program": {
      "op": "merge",
      "objects": [
        {"op": "literal", "value": {"a": 1}}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"a" => 1, "b" => 2}
  end

  test "merge fails on non-map input" do
    program = ~s({"program": {
      "op": "merge",
      "objects": [
        {"op": "literal", "value": [1, 2, 3]}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "merge requires map values")
  end

  test "merge validation fails when objects field is missing" do
    program = ~s({"program": {
      "op": "merge"
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "requires field 'objects'")
  end

  test "merge validation fails when objects is not a list" do
    program = ~s({"program": {
      "op": "merge",
      "objects": 42
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [1, 2, 3, 4]
  end

  test "concat with empty lists list" do
    program = ~s({"program": {
      "op": "concat",
      "lists": []
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "concat with single list" do
    program = ~s({"program": {
      "op": "concat",
      "lists": [
        {"op": "literal", "value": [1, 2, 3]}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [1, 2, 3, 4]
  end

  test "concat fails on non-list input" do
    program = ~s({"program": {
      "op": "concat",
      "lists": [
        {"op": "literal", "value": {"a": 1}}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "concat requires list values")
  end

  test "concat validation fails when lists field is missing" do
    program = ~s({"program": {
      "op": "concat"
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "requires field 'lists'")
  end

  test "concat validation fails when lists is not a list" do
    program = ~s({"program": {
      "op": "concat",
      "lists": "not a list"
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == [[1, "a"], [2, "b"]]
  end

  test "zip with empty lists list" do
    program = ~s({"program": {
      "op": "zip",
      "lists": []
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "zip with single list" do
    program = ~s({"program": {
      "op": "zip",
      "lists": [
        {"op": "literal", "value": [1, 2, 3]}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "zip fails on non-list input" do
    program = ~s({"program": {
      "op": "zip",
      "lists": [
        {"op": "literal", "value": 42}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "zip requires list values")
  end

  test "zip validation fails when lists field is missing" do
    program = ~s({"program": {
      "op": "zip"
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "requires field 'lists'")
  end

  test "zip validation fails when lists is not a list" do
    program = ~s({"program": {
      "op": "zip",
      "lists": {"a": 1}
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"id" => 1, "name" => "Alice", "total" => 100, "status" => "shipped"}
  end

  # Filter operation
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == [
             %{"item" => "book", "price" => 50},
             %{"item" => "laptop", "price" => 1000}
           ]
  end

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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == [
             %{"name" => "Alice", "age" => 30},
             %{"name" => "Bob", "age" => 25}
           ]
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == []
  end

  # E2E test with filter/reject and access operations
  test "E2E: filter/reject work in realistic data processing pipeline" do
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == %{"item" => "book", "price" => 50}
  end

  # Object operation - construct maps with evaluated values
  test "object with all literal values" do
    program = ~s({"program": {
      "op": "object",
      "fields": {"a": 1, "b": "test", "c": true}
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"a" => 1, "b" => "test", "c" => true}
  end

  test "object with expression values" do
    program = ~s({"program": {
      "op": "object",
      "fields": {
        "count": {"op": "literal", "value": 42},
        "name": "test"
      }
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"count" => 42, "name" => "test"}
  end

  test "object with mixed literal and expression values" do
    program = ~s({"program": {
      "op": "object",
      "fields": {
        "x": {"op": "literal", "value": 10},
        "y": 20,
        "z": {"op": "literal", "value": "hello"}
      }
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"x" => 10, "y" => 20, "z" => "hello"}
  end

  test "object with nested object operation" do
    program = ~s({"program": {
      "op": "object",
      "fields": {
        "nested": {
          "op": "object",
          "fields": {"inner": 42}
        }
      }
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"nested" => %{"inner" => 42}}
  end

  test "object with var reference to memory" do
    program = ~s({"program": {
      "op": "let",
      "name": "x",
      "value": {"op": "literal", "value": 100},
      "in": {
        "op": "object",
        "fields": {"stored": {"op": "var", "name": "x"}}
      }
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"stored" => 100}
  end

  test "object with empty fields" do
    program = ~s({"program": {
      "op": "object",
      "fields": {}
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{}
  end

  test "object with undefined var returns nil" do
    program = ~s({"program": {
      "op": "object",
      "fields": {
        "a": 1,
        "b": {"op": "var", "name": "undefined_var"}
      }
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == %{"a" => 1, "b" => nil}
  end

  test "E2E: object for memory contract - store and retrieve" do
    # First turn: compute and store
    program1 = ~s({"program": {
      "op": "let",
      "name": "cnt",
      "value": {"op": "literal", "value": 42},
      "in": {
        "op": "object",
        "fields": {
          "stored-count": {"op": "var", "name": "cnt"},
          "result": {"op": "var", "name": "cnt"}
        }
      }
    }})

    {:ok, result1, memory_delta1, new_memory1} = PtcRunner.Json.run(program1)
    # object returns the full map, not just "result"
    assert result1 == %{"stored-count" => 42, "result" => 42}
    # Memory is updated with the keys from the returned map (the object result)
    assert memory_delta1 == %{"stored-count" => 42, "result" => 42}

    # Second turn: retrieve from memory
    program2 = ~s({"program": {"op": "var", "name": "stored-count"}})

    {:ok, result2, _memory_delta2, _new_memory2} =
      PtcRunner.Json.run(program2, memory: new_memory1)

    assert result2 == 42
  end

  test "object with error in field expression propagates error" do
    program = ~s({"program": {
      "op": "object",
      "fields": {
        "a": 1,
        "b": {"op": "invalid_op"}
      }
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "invalid_op")
  end

  test "object validation fails when fields is missing" do
    program = ~s({"program": {
      "op": "object"
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "requires field 'fields'")
  end

  test "object validation fails when fields is not a map" do
    program = ~s({"program": {
      "op": "object",
      "fields": [1, 2, 3]
    }})

    {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "must be a map")
  end

  # Filter_in operation (membership filtering)
  test "filter_in keeps items where field value is in list set" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"status": "active", "count": 1},
          {"status": "pending", "count": 2},
          {"status": "inactive", "count": 3},
          {"status": "active", "count": 4}
        ]},
        {"op": "filter_in", "field": "status", "value": ["active", "pending"]}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == [
             %{"status" => "active", "count" => 1},
             %{"status" => "pending", "count" => 2},
             %{"status" => "active", "count" => 4}
           ]
  end

  test "filter_in on empty list returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": []},
        {"op": "filter_in", "field": "status", "value": ["active"]}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "filter_in with no matching items returns empty list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"status": "active", "count": 1},
          {"status": "active", "count": 2}
        ]},
        {"op": "filter_in", "field": "status", "value": ["inactive"]}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "filter_in with string field value and map set" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"role": "admin"},
          {"role": "viewer"},
          {"role": "admin"}
        ]},
        {"op": "filter_in", "field": "role", "value": {"admin": 1, "editor": 2}}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == [
             %{"role" => "admin"},
             %{"role" => "admin"}
           ]
  end

  test "filter_in skips non-map items in collection" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"status": "active"},
          "not a map",
          {"status": "pending"}
        ]},
        {"op": "filter_in", "field": "status", "value": ["active", "pending"]}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == [
             %{"status" => "active"},
             %{"status" => "pending"}
           ]
  end

  test "filter_in with numeric values in list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"priority": 1},
          {"priority": 2},
          {"priority": 3},
          {"priority": 1}
        ]},
        {"op": "filter_in", "field": "priority", "value": [1, 3]}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == [
             %{"priority" => 1},
             %{"priority" => 3},
             %{"priority" => 1}
           ]
  end

  test "filter_in with value as var expression" do
    program = ~s({"program": {
      "op": "let",
      "name": "allowed_statuses",
      "value": {"op": "literal", "value": ["active", "pending"]},
      "in": {
        "op": "pipe",
        "steps": [
          {"op": "literal", "value": [
            {"status": "active", "count": 1},
            {"status": "inactive", "count": 2},
            {"status": "pending", "count": 3}
          ]},
          {"op": "filter_in", "field": "status", "value": {"op": "var", "name": "allowed_statuses"}}
        ]
      }
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == [
             %{"status" => "active", "count" => 1},
             %{"status" => "pending", "count" => 3}
           ]
  end
end
