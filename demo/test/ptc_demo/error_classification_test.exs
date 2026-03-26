defmodule PtcDemo.ErrorClassificationTest do
  use ExUnit.Case, async: true

  alias PtcDemo.ErrorClassification

  describe "classify/1 with structured atom reasons" do
    test "parse_error from step.fail" do
      result = result_with_fail(:parse_error, "unexpected token")

      c = ErrorClassification.classify(result)

      assert c.category == :parse_error
      assert c.subtype == nil
      assert c.phase == :execution
      assert c.raw_reason == "unexpected token"
      assert c.normalized_reason == "parse_error"
    end

    test "no_code_found" do
      c = classify_atom(:no_code_found)
      assert c.category == :no_code_found
      assert c.phase == :execution
    end

    test "multiple_code_blocks" do
      c = classify_atom(:multiple_code_blocks)
      assert c.category == :multiple_code_blocks
    end

    test "analysis_error maps to static_analysis_error" do
      c = classify_atom(:analysis_error)
      assert c.category == :static_analysis_error
      assert c.subtype == nil
    end

    test "invalid_arity maps to static_analysis_error with subtype" do
      c = classify_atom(:invalid_arity)
      assert c.category == :static_analysis_error
      assert c.subtype == :invalid_arity
    end

    test "eval_error maps to runtime_error" do
      c = classify_atom(:eval_error)
      assert c.category == :runtime_error
      assert c.subtype == :eval_error
    end

    test "type_error maps to runtime_error" do
      c = classify_atom(:type_error)
      assert c.category == :runtime_error
      assert c.subtype == :type_error
    end

    test "failed maps to runtime_error with explicit_fail subtype" do
      c = classify_atom(:failed)
      assert c.category == :runtime_error
      assert c.subtype == :explicit_fail
    end

    test "tool_error" do
      c = classify_atom(:tool_error)
      assert c.category == :tool_error
      assert c.subtype == nil
    end

    test "unknown_tool maps to tool_error" do
      c = classify_atom(:unknown_tool)
      assert c.category == :tool_error
      assert c.subtype == :unknown_tool
    end

    test "validation_error from core" do
      c = classify_atom(:validation_error)
      assert c.category == :validation_error
      assert c.subtype == nil
      assert c.phase == :execution
    end

    test "timeout" do
      c = classify_atom(:timeout)
      assert c.category == :timeout
    end

    test "mission_timeout maps to timeout with subtype" do
      c = classify_atom(:mission_timeout)
      assert c.category == :timeout
      assert c.subtype == :mission_timeout
    end

    test "memory_exceeded maps to resource_error" do
      c = classify_atom(:memory_exceeded)
      assert c.category == :resource_error
      assert c.subtype == :memory_exceeded
    end

    test "max_turns_exceeded maps to budget_exhausted" do
      c = classify_atom(:max_turns_exceeded)
      assert c.category == :budget_exhausted
    end

    test "turn_budget_exhausted maps to budget_exhausted" do
      c = classify_atom(:turn_budget_exhausted)
      assert c.category == :budget_exhausted
    end

    test "llm_error maps to unknown_error" do
      c = classify_atom(:llm_error)
      assert c.category == :unknown_error
      assert c.subtype == :llm_error
    end

    test "unrecognized atom maps to unknown_error" do
      c = classify_atom(:something_new)
      assert c.category == :unknown_error
      assert c.subtype == nil
      assert c.phase == :execution
    end
  end

  describe "classify/1 with validation error strings" do
    test "wrong type" do
      result = %{step: nil, error: "Wrong type: got \"hello\" (:string), expected :integer"}

      c = ErrorClassification.classify(result)

      assert c.category == :validation_error
      assert c.subtype == :wrong_type
      assert c.phase == :validation
      assert c.raw_reason == result.error
    end

    test "constraint: eq" do
      c = classify_string("Expected 500, got 499")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "constraint: gt" do
      c = classify_string("Expected > 5, got 3")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "constraint: gte" do
      c = classify_string("Expected >= 5, got 3")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "constraint: lt" do
      c = classify_string("Expected < 10, got 15")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "constraint: between" do
      c = classify_string("Expected between 1-100, got 101")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "constraint: length" do
      c = classify_string("Expected length 5, got 3")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "constraint: gt_length" do
      c = classify_string("Expected length > 3, got 1")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "constraint: starts_with" do
      c = classify_string("Expected to start with 'foo', got 'bar'")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "constraint: one_of" do
      c = classify_string("Expected one of [:a, :b, :c], got :d")
      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "missing keys" do
      c = classify_string("Expected keys [:a, :b], missing [:b]")
      assert c.category == :validation_error
      assert c.subtype == :missing_keys
    end

    test "no result returned" do
      c = classify_string("No result returned")
      assert c.category == :no_code_found
      assert c.subtype == :no_result
      assert c.phase == :validation
    end

    test "query failed" do
      c = classify_string("Query failed: :timeout")
      assert c.category == :unknown_error
      assert c.subtype == :query_failed
    end

    test "unknown string" do
      c = classify_string("Something completely unexpected")
      assert c.category == :unknown_error
      assert c.subtype == nil
      assert c.phase == :validation
    end
  end

  describe "classify/1 precedence" do
    test "structured atom takes precedence over error string" do
      result = %{
        step: %PtcRunner.Step{fail: %{reason: :timeout, message: "exceeded 1000ms"}},
        error: "Wrong type: got nil, expected :integer"
      }

      c = ErrorClassification.classify(result)

      assert c.category == :timeout
      assert c.phase == :execution
    end

    test "falls back to string when step is nil" do
      result = %{step: nil, error: "Expected 500, got 499"}

      c = ErrorClassification.classify(result)

      assert c.category == :validation_error
      assert c.phase == :validation
    end

    test "falls back to last failed turn when step.fail is nil" do
      result = %{
        step: %PtcRunner.Step{
          fail: nil,
          turns: [
            PtcRunner.Turn.failure(1, "raw", nil, %{reason: :parse_error, message: "bad syntax"}),
            PtcRunner.Turn.success(2, "raw", "(+ 1 2)", 3),
            PtcRunner.Turn.failure(3, "raw", "(/ 1 0)", %{reason: :eval_error, message: "div/0"})
          ]
        },
        error: "Expected > 5, got 3"
      }

      c = ErrorClassification.classify(result)

      # Uses last failed turn (turn 3), not the string fallback
      assert c.category == :runtime_error
      assert c.subtype == :eval_error
      assert c.phase == :execution
    end

    test "falls back to string when step has no fail and no failed turns" do
      result = %{
        step: %PtcRunner.Step{
          fail: nil,
          turns: [PtcRunner.Turn.success(1, "raw", "(+ 1 2)", 3)]
        },
        error: "Expected > 5, got 3"
      }

      c = ErrorClassification.classify(result)

      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "falls back to string when step has no fail and empty turns" do
      result = %{step: %PtcRunner.Step{fail: nil, turns: []}, error: "Expected > 5, got 3"}

      c = ErrorClassification.classify(result)

      assert c.category == :validation_error
      assert c.subtype == :constraint_failed
    end

    test "query_failed uses turn reason when available" do
      result = %{
        step: %PtcRunner.Step{
          fail: nil,
          turns: [
            PtcRunner.Turn.failure(1, "raw", nil, %{reason: :timeout, message: "exceeded 1000ms"})
          ]
        },
        error: "Query failed: :timeout"
      }

      c = ErrorClassification.classify(result)

      # Resolves through turn, not string fallback
      assert c.category == :timeout
      assert c.phase == :execution
    end

    test "handles missing step key" do
      result = %{error: "Wrong type: got 42 (:integer), expected :string"}

      c = ErrorClassification.classify(result)

      assert c.category == :validation_error
      assert c.subtype == :wrong_type
    end

    test "handles missing error key with no step" do
      result = %{step: nil}

      c = ErrorClassification.classify(result)

      assert c.category == :unknown_error
      assert c.raw_reason == "Unknown error"
    end
  end

  describe "classify_turns/1" do
    test "classifies each failed turn with structured reason" do
      step = %PtcRunner.Step{
        turns: [
          PtcRunner.Turn.failure(1, "raw", nil, %{reason: :parse_error, message: "bad"}),
          PtcRunner.Turn.success(2, "raw", "(+ 1 2)", 3),
          PtcRunner.Turn.failure(3, "raw", "(/ 1 0)", %{reason: :eval_error, message: "div/0"})
        ]
      }

      result = ErrorClassification.classify_turns(step)

      assert [{1, c1}, {3, c3}] = result
      assert c1.category == :parse_error
      assert c1.phase == :execution
      assert c3.category == :runtime_error
      assert c3.subtype == :eval_error
    end

    test "skips failed turns without structured reason" do
      step = %PtcRunner.Step{
        turns: [
          PtcRunner.Turn.failure(1, "raw", nil, "plain string error"),
          PtcRunner.Turn.failure(2, "raw", nil, %{reason: :parse_error, message: "bad"})
        ]
      }

      result = ErrorClassification.classify_turns(step)

      assert [{2, c}] = result
      assert c.category == :parse_error
    end

    test "empty list for nil turns" do
      assert ErrorClassification.classify_turns(%PtcRunner.Step{turns: nil}) == []
    end

    test "empty list for empty turns" do
      assert ErrorClassification.classify_turns(%PtcRunner.Step{turns: []}) == []
    end

    test "empty list when all turns succeed" do
      step = %PtcRunner.Step{
        turns: [PtcRunner.Turn.success(1, "raw", "(+ 1 2)", 3)]
      }

      assert ErrorClassification.classify_turns(step) == []
    end
  end

  # Helpers

  defp result_with_fail(reason, message) do
    %{
      step: %PtcRunner.Step{fail: %{reason: reason, message: message}},
      error: "some error string"
    }
  end

  defp classify_atom(reason) do
    result_with_fail(reason, to_string(reason))
    |> ErrorClassification.classify()
  end

  defp classify_string(error) do
    %{step: nil, error: error}
    |> ErrorClassification.classify()
  end
end
