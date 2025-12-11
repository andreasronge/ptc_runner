defmodule PtcRunner.Json.Operations.AggregationTest do
  use ExUnit.Case

  # Count operation
  test "count returns number of items in list" do
    program = ~s({"program": {
      "op": "pipe",
      "steps": [
        {"op": "literal", "value": [1, 2, 3, 4, 5]},
        {"op": "count"}
      ]
    }})

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == 150
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
    assert result == 3
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == %{"name" => "Book", "price" => 15}
    end
  end
end
