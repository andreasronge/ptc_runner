defmodule PtcRunner.Json.Operations.ControlFlowTest do
  use ExUnit.Case

  describe "let operation" do
    test "let binds value to name and returns it via var" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5},
        "in": {"op": "var", "name": "x"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 5
    end

    test "let allows var to reference undefined name returns nil" do
      program = ~s({"program": {
        "op": "let",
        "name": "x",
        "value": {"op": "literal", "value": 5},
        "in": {"op": "var", "name": "y"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == 10
    end

    test "let with empty string name" do
      program = ~s({"program": {
        "op": "let",
        "name": "",
        "value": {"op": "literal", "value": 42},
        "in": {"op": "var", "name": ""}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:error, reason} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program, context: context)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "yes"
    end

    test "if returns else result when condition is false" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": false},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "no"
    end

    test "if returns else result when condition is nil" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": null},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "no"
    end

    test "if returns then result when condition is truthy integer" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": 1},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "yes"
    end

    test "if returns then result when condition is truthy zero" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": 0},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "yes"
    end

    test "if returns then result when condition is truthy empty list" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": []},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "yes"
    end

    test "if returns then result when condition is truthy empty string" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": ""},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == "yes"
    end

    test "if returns then result when condition is truthy empty map" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": {}},
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:error, reason} = PtcRunner.Json.run(program)
      assert {:execution_error, msg} = reason
      assert String.contains?(msg, "count requires a list")
    end

    test "if missing condition field raises validation error" do
      program = ~s({"program": {
        "op": "if",
        "then": {"op": "literal", "value": "yes"},
        "else": {"op": "literal", "value": "no"}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert {:validation_error, msg} = reason
      assert String.contains?(msg, "condition")
    end

    test "if missing then field raises validation error" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": true},
        "else": {"op": "literal", "value": "no"}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
      assert {:validation_error, msg} = reason
      assert String.contains?(msg, "then")
    end

    test "if missing else field raises validation error" do
      program = ~s({"program": {
        "op": "if",
        "condition": {"op": "literal", "value": true},
        "then": {"op": "literal", "value": "yes"}
      }})

      {:error, reason} = PtcRunner.Json.run(program)
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

      {:error, reason} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == false
    end

    test "and with empty conditions returns true" do
      program = ~s({"program": {
        "op": "and",
        "conditions": []
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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
      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == false
    end

    test "or with empty conditions returns false" do
      program = ~s({"program": {
        "op": "or",
        "conditions": []
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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
      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == true
    end

    # Not operation - boolean logic tests
    test "not with true returns false" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": true}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == false
    end

    test "not with false returns true" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": false}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == true
    end

    test "not with nil returns true" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": null}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == true
    end

    test "not with truthy value returns false" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": 42}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      assert result == false
    end

    test "not with truthy empty string returns false" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "literal", "value": ""}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      # undefined variable returns nil (falsy), continues to next (true), so or returns true
      assert result == true
    end

    test "not with undefined variable treated as nil returns true" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "var", "name": "undefined_var"}
      }})

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
      # undefined variable returns nil, which is falsy, so not returns true
      assert result == true
    end

    # Validation error tests
    test "and validation fails when conditions field is missing" do
      program = ~s({"program": {
        "op": "and"
      }})

      {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
      assert String.contains?(message, "requires field 'conditions'")
    end

    test "and validation fails when conditions is not a list" do
      program = ~s({"program": {
        "op": "and",
        "conditions": "not a list"
      }})

      {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
      assert String.contains?(message, "must be a list")
    end

    test "or validation fails when conditions field is missing" do
      program = ~s({"program": {
        "op": "or"
      }})

      {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
      assert String.contains?(message, "requires field 'conditions'")
    end

    test "or validation fails when conditions is not a list" do
      program = ~s({"program": {
        "op": "or",
        "conditions": 42
      }})

      {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
      assert String.contains?(message, "must be a list")
    end

    test "not validation fails when condition field is missing" do
      program = ~s({"program": {
        "op": "not"
      }})

      {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
      assert String.contains?(message, "requires field 'condition'")
    end

    test "not validates nested condition expression" do
      program = ~s({"program": {
        "op": "not",
        "condition": {"op": "invalid_op"}
      }})

      {:error, {:validation_error, message}} = PtcRunner.Json.run(program)
      assert String.contains?(message, "Unknown operation")
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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

      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program)
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
      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program, context: context)
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
      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program, context: context)
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
      {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program, context: context)
      assert result == "not_eligible"
    end
  end
end
