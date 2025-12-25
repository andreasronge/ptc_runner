defmodule PtcRunner.Json.Operations.TransformTest do
  use ExUnit.Case

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
end
