defmodule PtcRunner.Json.Operations.FilterTest do
  use ExUnit.Case

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
