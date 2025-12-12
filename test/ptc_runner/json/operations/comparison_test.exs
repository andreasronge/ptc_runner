defmodule PtcRunner.Json.Operations.ComparisonTest do
  use ExUnit.Case

  # Eq comparison operation
  test "eq compares field value with literal" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": "travel"}},
        {"op": "eq", "field": "category", "value": "travel"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == false
  end

  test "eq with nil field value" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"category": null}},
        {"op": "eq", "field": "category", "value": "travel"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == false
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == true
  end

  test "gt returns false when field value is not greater" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 50}},
        {"op": "gt", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == true
  end

  test "lt returns false when field value is not less" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"amount": 50}},
        {"op": "lt", "field": "amount", "value": 50}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == false
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == false
  end

  # In operation (membership)
  test "in checks if value is member of list field" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"tags": [1, 2, 3]}},
        {"op": "in", "field": "tags", "value": 2}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == true
  end

  test "in returns false when value is not member of list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"tags": [1, 2, 3]}},
        {"op": "in", "field": "tags", "value": 5}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == false
  end

  test "in checks if value is key in map field" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"metadata": {"a": 1, "b": 2}}},
        {"op": "in", "field": "metadata", "value": "a"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == true
  end

  test "in returns false when key not in map field" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"metadata": {"a": 1, "b": 2}}},
        {"op": "in", "field": "metadata", "value": "c"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == false
  end

  test "in on nil field value returns false" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"data": null}},
        {"op": "in", "field": "data", "value": "foo"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == false
  end

  test "in on other types returns false" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": {"count": 42}},
        {"op": "in", "field": "count", "value": "foo"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == false
  end
end
