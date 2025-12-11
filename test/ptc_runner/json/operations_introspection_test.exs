defmodule PtcRunner.Json.Operations.IntrospectionTest do
  use ExUnit.Case

  # Keys operation tests

  test "keys returns sorted keys of a map" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"name": "Alice", "age": 30, "city": "NYC"}},
        {"op": "keys"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == ["age", "city", "name"]
  end

  test "keys returns empty list for empty map" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {}},
        {"op": "keys"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == []
  end

  test "keys returns execution error for list input" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "keys"}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "keys requires a map")
  end

  test "keys returns execution error for string input" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": "hello"},
        {"op": "keys"}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "keys requires a map")
  end

  test "keys returns execution error for number input" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "keys"}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "keys requires a map")
  end

  test "keys returns execution error for null input" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": null},
        {"op": "keys"}
      ]
    }})

    {:error, {:execution_error, message}} = PtcRunner.Json.run(program)
    assert String.contains?(message, "keys requires a map")
  end

  # Typeof operation tests

  test "typeof returns 'object' for maps" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"a": 1}},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "object"
  end

  test "typeof returns 'list' for lists" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3]},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "list"
  end

  test "typeof returns 'string' for strings" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": "hello"},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "string"
  end

  test "typeof returns 'number' for numbers" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 42},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "number"
  end

  test "typeof returns 'number' for floats" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": 3.14},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "number"
  end

  test "typeof returns 'boolean' for true" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": true},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "boolean"
  end

  test "typeof returns 'boolean' for false" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": false},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "boolean"
  end

  test "typeof returns 'null' for null value" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": null},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "null"
  end

  # E2E tests demonstrating nested exploration patterns

  test "E2E: explore list item structure with first + keys" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [
          {"id": 1, "name": "Alice", "price": 50},
          {"id": 2, "name": "Bob", "price": 75}
        ]},
        {"op": "first"},
        {"op": "keys"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == ["id", "name", "price"]
  end

  test "E2E: check type of loaded data" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "load", "name": "products"},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} =
      PtcRunner.Json.run(program, context: %{"products" => [1, 2, 3]})

    assert result == "list"
  end

  test "E2E: explore nested object structure with get + keys" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {
          "user": {"name": "Alice", "age": 30},
          "address": {"street": "Main St", "city": "NYC", "zip": "10001"}
        }},
        {"op": "get", "path": ["address"]},
        {"op": "keys"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == ["city", "street", "zip"]
  end

  test "E2E: check nested field type with get + typeof" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {
          "user": {"name": "Alice", "age": 30},
          "address": {"street": "Main St", "city": "NYC"}
        }},
        {"op": "get", "path": ["address"]},
        {"op": "typeof"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == "object"
  end

  test "E2E: multi-turn exploration pattern - first check type, then get keys" do
    # Simulating a multi-turn conversation where first turn checks type
    program1 = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [{"id": 1, "name": "Alice"}]},
        {"op": "typeof"}
      ]
    }})

    {:ok, type_result, _memory_delta, _new_memory} = PtcRunner.Json.run(program1)
    assert type_result == "list"

    # Second turn explores structure
    program2 = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [{"id": 1, "name": "Alice"}]},
        {"op": "first"},
        {"op": "keys"}
      ]
    }})

    {:ok, keys_result, _memory_delta, _new_memory} = PtcRunner.Json.run(program2)
    assert keys_result == ["id", "name"]
  end
end
