defmodule PtcRunner.Json.Operations.ErrorHandlingTest do
  use ExUnit.Case

  # Validation errors
  test "missing 'op' field raises validation error" do
    program = ~s({"program": {"value": 42}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Missing required field 'op'"}
  end

  test "unknown operation raises validation error" do
    program = ~s({"program": {"op": "unknown_op"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
  end

  test "typo in operation suggests closest match" do
    program = ~s({"program": {"op": "filer"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Unknown operation 'filer'. Did you mean 'filter'?"}
  end

  test "missing letter typo suggests closest match" do
    program = ~s({"program": {"op": "selct"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Unknown operation 'selct'. Did you mean 'select'?"}
  end

  test "extra letter typo suggests closest match" do
    program = ~s({"program": {"op": "filtter"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Unknown operation 'filtter'. Did you mean 'filter'?"}
  end

  test "case insensitive typo suggestion" do
    program = ~s({"program": {"op": "FILTER"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Unknown operation 'FILTER'. Did you mean 'filter'?"}
  end

  test "very different operation name has no suggestion" do
    program = ~s({"program": {"op": "xyz"}})
    {:error, reason} = PtcRunner.Json.run(program)

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
    {:error, {:validation_error, msg}} = PtcRunner.Json.run(program)
    assert msg =~ "Did you mean 'filter'?"
  end

  test "missing required field in operation raises validation error" do
    program = ~s({"program": {"op": "literal"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Operation 'literal' requires field 'value'"}
  end

  test "literal with no value field raises validation error" do
    program = ~s({"program": {"op": "load"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Operation 'load' requires field 'name'"}
  end

  test "nested unknown operation in pipe raises validation error" do
    program = ~s({"program": {"op": "pipe", "steps": [{"op": "unknown_op"}]}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
  end

  test "get operation missing field and path raises validation error" do
    program = ~s({"program": {"op": "get"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Operation 'get' requires either 'field' or 'path'"}
  end

  test "get operation with non-array path raises validation error" do
    program = ~s({"program": {"op": "get", "path": "not_an_array"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Field 'path' must be a list"}
  end

  test "get operation with non-string path elements raises validation error" do
    program = ~s({"program": {"op": "get", "path": ["valid", 123]}})
    {:error, reason} = PtcRunner.Json.run(program)

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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:validation_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
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

    {:error, {:execution_error, msg}} = PtcRunner.Json.run(program)
    assert String.contains?(msg, "contains requires a map")
  end

  # Validation errors for new operations
  test "nth missing index field raises validation error" do
    program = ~s({"program": {"op": "nth"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Operation 'nth' requires field 'index'"}
  end

  test "nth with negative index in validation raises validation error" do
    program = ~s({"program": {"op": "nth", "index": -1}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Operation 'nth' index must be non-negative, got -1"}
  end

  test "nth with non-integer index in validation raises validation error" do
    program = ~s({"program": {"op": "nth", "index": "not_an_integer"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Operation 'nth' field 'index' must be an integer"}
  end

  test "reject missing where field raises validation error" do
    program = ~s({"program": {"op": "reject"}})
    {:error, reason} = PtcRunner.Json.run(program)

    assert reason == {:validation_error, "Operation 'reject' requires field 'where'"}
  end

  # Parse errors
  test "malformed JSON raises parse error" do
    program = "{invalid json"
    {:error, {:parse_error, message}} = PtcRunner.Json.run(program)

    assert String.contains?(message, "JSON decode error")
  end

  test "valid wrapped JSON string extracts program and runs successfully" do
    program = ~s({"program": {"op": "literal", "value": 42}})
    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == 42
  end

  test "valid wrapped map extracts program and runs successfully" do
    program = %{"program" => %{"op" => "literal", "value" => 99}}
    {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)

    assert result == 99
  end

  test "missing program field returns parse error" do
    program = ~s({"data": {"op": "literal", "value": 42}})
    {:error, {:parse_error, message}} = PtcRunner.Json.run(program)

    assert message == "Missing required field 'program'"
  end

  test "program is not a map returns parse error" do
    # Test with null
    program = ~s({"program": null})
    {:error, {:parse_error, message}} = PtcRunner.Json.run(program)
    assert message == "program must be a map"

    # Test with string
    program = ~s({"program": "not a map"})
    {:error, {:parse_error, message}} = PtcRunner.Json.run(program)
    assert message == "program must be a map"

    # Test with array
    program = ~s({"program": [1, 2, 3]})
    {:error, {:parse_error, message}} = PtcRunner.Json.run(program)
    assert message == "program must be a map"
  end

  describe "operations without piped input" do
    test "operations requiring piped input return error when input unavailable" do
      operations_without_input = [
        {~s({"program": {"op": "get", "path": ["x"]}}), "get"},
        {~s({"program": {"op": "filter", "where": {"op": "eq", "field": "x", "value": 1}}}),
         "filter"},
        {~s({"program": {"op": "map", "expr": {"op": "literal", "value": "x"}}}), "map"},
        {~s({"program": {"op": "count"}}), "count"},
        {~s({"program": {"op": "sum", "field": "amount"}}), "sum"},
        {~s({"program": {"op": "select", "fields": ["name"]}}), "select"},
        {~s({"program": {"op": "eq", "field": "x", "value": 1}}), "eq"},
        {~s({"program": {"op": "neq", "field": "x", "value": 1}}), "neq"},
        {~s({"program": {"op": "gt", "field": "x", "value": 1}}), "gt"},
        {~s({"program": {"op": "gte", "field": "x", "value": 1}}), "gte"},
        {~s({"program": {"op": "lt", "field": "x", "value": 1}}), "lt"},
        {~s({"program": {"op": "lte", "field": "x", "value": 1}}), "lte"},
        {~s({"program": {"op": "first"}}), "first"},
        {~s({"program": {"op": "last"}}), "last"},
        {~s({"program": {"op": "nth", "index": 0}}), "nth"},
        {~s({"program": {"op": "reject", "where": {"op": "eq", "field": "x", "value": 1}}}),
         "reject"}
      ]

      for {program, _op_name} <- operations_without_input do
        {:error, reason} = PtcRunner.Json.run(program)
        assert reason == {:execution_error, "No input available"}
      end
    end
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

      {:error, reason} = PtcRunner.Json.run(program)
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

      {:error, reason} = PtcRunner.Json.run(program)
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

      {:error, reason} = PtcRunner.Json.run(program)
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

      {:error, reason} = PtcRunner.Json.run(program)
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

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Operation 'max' requires field 'field'"}
    end

    test "let missing name field raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "value": {"op": "literal", "value": 5},
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Operation 'let' requires field 'name'"}
    end

    test "let with non-string name raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": 42,
        "value": {"op": "literal", "value": 5},
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Field 'name' must be a string"}
    end

    test "let missing value field raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Operation 'let' requires field 'value'"}
    end

    test "let missing in field raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Operation 'let' requires field 'in'"}
    end

    test "let with invalid nested value expression raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "unknown_op"},
        "in": {"op": "var", "name": "x"}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
    end

    test "let with invalid nested in expression raises validation error" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5},
        "in": {"op": "unknown_op"}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert reason == {:validation_error, "Unknown operation 'unknown_op'"}
    end
  end
end
