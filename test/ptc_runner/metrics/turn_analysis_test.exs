defmodule PtcRunner.Metrics.TurnAnalysisTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Metrics.TurnAnalysis
  alias PtcRunner.{Step, Turn}

  describe "first_turn_valid?/1" do
    test "true when turn 1 succeeds" do
      step = %Step{turns: [Turn.success(1, "raw", "(+ 1 2)", 3)]}
      assert TurnAnalysis.first_turn_valid?(step)
    end

    test "false when turn 1 has no parseable code" do
      step = %Step{
        turns: [
          Turn.failure(1, "raw", nil, %{reason: :no_code_found, message: "no code"})
        ]
      }

      refute TurnAnalysis.first_turn_valid?(step)
    end

    test "true when turn 1 has program but failed at runtime" do
      step = %Step{
        turns: [
          Turn.failure(1, "raw", "(bad-fn)", %{reason: :eval_error, message: "error"})
        ]
      }

      assert TurnAnalysis.first_turn_valid?(step)
    end

    test "false for nil turns" do
      refute TurnAnalysis.first_turn_valid?(%Step{turns: nil})
    end

    test "false for empty turns" do
      refute TurnAnalysis.first_turn_valid?(%Step{turns: []})
    end
  end

  describe "parse_failure_rate/1" do
    test "0.0 for all successful turns" do
      step = %Step{
        turns: [
          Turn.success(1, "raw", "(+ 1 2)", 3),
          Turn.success(2, "raw", "(+ 3 4)", 7)
        ]
      }

      assert TurnAnalysis.parse_failure_rate(step) == 0.0
    end

    test "correct fraction for mixed turns" do
      step = %Step{
        turns: [
          Turn.failure(1, "raw", nil, %{reason: :parse_error, message: "bad"}),
          Turn.success(2, "raw", "(+ 1 2)", 3),
          Turn.failure(3, "raw", nil, %{reason: :parse_error, message: "bad"}),
          Turn.success(4, "raw", "(+ 3 4)", 7)
        ]
      }

      assert TurnAnalysis.parse_failure_rate(step) == 0.5
    end

    test "0.0 for nil turns" do
      assert TurnAnalysis.parse_failure_rate(%Step{turns: nil}) == 0.0
    end

    test "0.0 for empty turns" do
      assert TurnAnalysis.parse_failure_rate(%Step{turns: []}) == 0.0
    end
  end

  describe "no_code_rate/1" do
    test "correct fraction with no_code_found errors" do
      step = %Step{
        turns: [
          Turn.failure(1, "raw", nil, %{reason: :no_code_found, message: "none"}),
          Turn.success(2, "raw", "(+ 1 2)", 3),
          Turn.success(3, "raw", "(+ 3 4)", 7)
        ]
      }

      assert_in_delta TurnAnalysis.no_code_rate(step), 1 / 3, 0.001
    end

    test "0.0 when no :no_code_found errors" do
      step = %Step{turns: [Turn.success(1, "raw", "(+ 1 2)", 3)]}
      assert TurnAnalysis.no_code_rate(step) == 0.0
    end
  end

  describe "multi_code_block_rate/1" do
    test "correct fraction with multiple_code_blocks errors" do
      step = %Step{
        turns: [
          Turn.failure(1, "raw", nil, %{reason: :multiple_code_blocks, message: "2 blocks"}),
          Turn.failure(2, "raw", nil, %{reason: :multiple_code_blocks, message: "3 blocks"}),
          Turn.success(3, "raw", "(+ 1 2)", 3),
          Turn.success(4, "raw", "(+ 3 4)", 7)
        ]
      }

      assert TurnAnalysis.multi_code_block_rate(step) == 0.5
    end

    test "0.0 when no multiple_code_blocks errors" do
      step = %Step{turns: [Turn.success(1, "raw", "(+ 1 2)", 3)]}
      assert TurnAnalysis.multi_code_block_rate(step) == 0.0
    end
  end

  describe "turns_to_first_tool_call/1" do
    test "finds correct turn number" do
      step = %Step{
        turns: [
          Turn.success(1, "raw", "(+ 1 2)", 3),
          Turn.success(2, "raw", "(search \"q\")", :ok, %{
            tool_calls: [%{name: "search", args: %{q: "q"}, result: "found"}]
          }),
          Turn.success(3, "raw", "(return 42)", 42)
        ]
      }

      assert TurnAnalysis.turns_to_first_tool_call(step) == 2
    end

    test "nil when no tool calls" do
      step = %Step{
        turns: [
          Turn.success(1, "raw", "(+ 1 2)", 3),
          Turn.success(2, "raw", "(return 42)", 42)
        ]
      }

      assert TurnAnalysis.turns_to_first_tool_call(step) == nil
    end

    test "nil for nil turns" do
      assert TurnAnalysis.turns_to_first_tool_call(%Step{turns: nil}) == nil
    end

    test "nil for empty turns" do
      assert TurnAnalysis.turns_to_first_tool_call(%Step{turns: []}) == nil
    end
  end

  describe "budget_exhausted?/1" do
    test "true for :max_turns_exceeded" do
      step = %Step{fail: %{reason: :max_turns_exceeded, message: "exceeded"}}
      assert TurnAnalysis.budget_exhausted?(step)
    end

    test "true for :turn_budget_exhausted" do
      step = %Step{fail: %{reason: :turn_budget_exhausted, message: "exhausted"}}
      assert TurnAnalysis.budget_exhausted?(step)
    end

    test "true for :budget_exhausted" do
      step = %Step{fail: %{reason: :budget_exhausted, message: "exhausted"}}
      assert TurnAnalysis.budget_exhausted?(step)
    end

    test "false for successful step" do
      step = %Step{return: 42}
      refute TurnAnalysis.budget_exhausted?(step)
    end

    test "false for other failure reasons" do
      step = %Step{fail: %{reason: :timeout, message: "timed out"}}
      refute TurnAnalysis.budget_exhausted?(step)
    end
  end

  describe "turn_count/1" do
    test "correct count" do
      step = %Step{
        turns: [
          Turn.success(1, "raw", "(+ 1 2)", 3),
          Turn.success(2, "raw", "(return 42)", 42)
        ]
      }

      assert TurnAnalysis.turn_count(step) == 2
    end

    test "0 for nil turns" do
      assert TurnAnalysis.turn_count(%Step{turns: nil}) == 0
    end

    test "0 for empty turns" do
      assert TurnAnalysis.turn_count(%Step{turns: []}) == 0
    end
  end

  describe "analyze/2" do
    test "returns complete map with all metrics" do
      step = %Step{
        turns: [
          Turn.failure(1, "raw", nil, %{reason: :parse_error, message: "bad"}),
          Turn.success(2, "raw", "(search \"q\")", :ok, %{
            tool_calls: [%{name: "search", args: %{}, result: "found"}]
          }),
          Turn.success(3, "raw", "(return 42)", 42)
        ]
      }

      result = TurnAnalysis.analyze(step, passed?: true)

      refute result.first_turn_valid?
      assert_in_delta result.parse_failure_rate, 1 / 3, 0.001
      assert result.no_code_rate == 0.0
      assert result.multi_code_block_rate == 0.0
      assert result.turns_to_first_tool_call == 2
      refute result.budget_exhausted?
      assert result.has_failed_turn?
      assert result.turn_count == 3
      assert result.passed? == true
    end

    test "passed? defaults to nil when not provided" do
      step = %Step{turns: [Turn.success(1, "raw", "(+ 1 2)", 3)]}
      result = TurnAnalysis.analyze(step)
      assert result.passed? == nil
    end
  end

  describe "aggregate/1" do
    test "correct summary stats" do
      metrics = [
        %{
          first_turn_valid?: true,
          parse_failure_rate: 0.0,
          no_code_rate: 0.0,
          multi_code_block_rate: 0.0,
          turns_to_first_tool_call: 1,
          budget_exhausted?: false,
          has_failed_turn?: false,
          turn_count: 2,
          input_tokens: 100,
          output_tokens: 50,
          total_tokens: 150,
          passed?: true
        },
        %{
          first_turn_valid?: false,
          parse_failure_rate: 0.5,
          no_code_rate: 0.0,
          multi_code_block_rate: 0.0,
          turns_to_first_tool_call: 2,
          budget_exhausted?: true,
          has_failed_turn?: true,
          turn_count: 4,
          input_tokens: 400,
          output_tokens: 200,
          total_tokens: 600,
          passed?: false
        }
      ]

      result = TurnAnalysis.aggregate(metrics)

      assert result.first_turn_validity_rate == 0.5
      assert result.mean_parse_failure_rate == 0.25
      assert result.mean_no_code_rate == 0.0
      assert result.mean_multi_code_block_rate == 0.0
      assert result.mean_turns_on_pass == 2.0
      # 1 run with failed turns, 0 passed => 0.0
      assert result.recoverable_error_salvage_rate == 0.0
      assert result.budget_exhausted_rate == 0.5
      assert result.pass_rate == 0.5
      assert result.mean_input_tokens == 250.0
      assert result.mean_output_tokens == 125.0
      assert result.mean_total_tokens == 375.0
      assert result.mean_total_tokens_on_pass == 150.0
    end

    test "handles empty list" do
      result = TurnAnalysis.aggregate([])

      assert result.first_turn_validity_rate == 0.0
      assert result.mean_parse_failure_rate == 0.0
      assert result.mean_no_code_rate == 0.0
      assert result.mean_multi_code_block_rate == 0.0
      assert result.mean_turns_on_pass == nil
      assert result.recoverable_error_salvage_rate == 0.0
      assert result.budget_exhausted_rate == 0.0
      assert result.pass_rate == 0.0
    end

    test "mean_turns_on_pass is nil when no passes" do
      metrics = [
        %{
          first_turn_valid?: false,
          parse_failure_rate: 1.0,
          no_code_rate: 0.0,
          multi_code_block_rate: 0.0,
          turns_to_first_tool_call: nil,
          budget_exhausted?: true,
          has_failed_turn?: true,
          turn_count: 5,
          passed?: false
        }
      ]

      result = TurnAnalysis.aggregate(metrics)
      assert result.mean_turns_on_pass == nil
    end

    test "recoverable_error_salvage_rate when errors are salvaged" do
      metrics = [
        # Run with failed turns that still passed
        %{
          first_turn_valid?: false,
          parse_failure_rate: 0.5,
          no_code_rate: 0.0,
          multi_code_block_rate: 0.0,
          turns_to_first_tool_call: 2,
          budget_exhausted?: false,
          has_failed_turn?: true,
          turn_count: 4,
          passed?: true
        },
        # Run with failed turns that failed overall
        %{
          first_turn_valid?: false,
          parse_failure_rate: 0.0,
          no_code_rate: 0.5,
          multi_code_block_rate: 0.0,
          turns_to_first_tool_call: nil,
          budget_exhausted?: true,
          has_failed_turn?: true,
          turn_count: 4,
          passed?: false
        },
        # Clean run that passed (no failed turns)
        %{
          first_turn_valid?: true,
          parse_failure_rate: 0.0,
          no_code_rate: 0.0,
          multi_code_block_rate: 0.0,
          turns_to_first_tool_call: 1,
          budget_exhausted?: false,
          has_failed_turn?: false,
          turn_count: 1,
          passed?: true
        }
      ]

      result = TurnAnalysis.aggregate(metrics)
      # 2 runs with failed turns, 1 of them passed => 0.5
      assert result.recoverable_error_salvage_rate == 0.5
    end

    test "salvage rate includes runtime failures, not just parse errors" do
      metrics = [
        # Run with runtime error (tool_not_found) that still passed
        %{
          first_turn_valid?: true,
          parse_failure_rate: 0.0,
          no_code_rate: 0.0,
          multi_code_block_rate: 0.0,
          turns_to_first_tool_call: 2,
          budget_exhausted?: false,
          has_failed_turn?: true,
          turn_count: 3,
          passed?: true
        }
      ]

      result = TurnAnalysis.aggregate(metrics)
      # 1 run with failed turns, 1 passed => 1.0
      assert result.recoverable_error_salvage_rate == 1.0
    end
  end
end
