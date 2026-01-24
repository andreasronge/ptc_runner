defmodule PtcRunner.TurnTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Turn

  doctest PtcRunner.Turn

  describe "Turn.success/5" do
    test "creates turn with success? set to true" do
      turn = Turn.success(1, "raw", "(+ 1 2)", 3)

      assert turn.success? == true
    end

    test "sets all fields correctly" do
      tool_calls = [%{name: "search", args: %{q: "test"}, result: []}]
      memory = %{x: 10, y: 20}

      turn =
        Turn.success(
          3,
          "```ptc-lisp\n(+ x y)\n```",
          "(+ x y)",
          30,
          %{prints: ["hello", "world"], tool_calls: tool_calls, memory: memory}
        )

      assert turn.number == 3
      assert turn.raw_response == "```ptc-lisp\n(+ x y)\n```"
      assert turn.program == "(+ x y)"
      assert turn.result == 30
      assert turn.prints == ["hello", "world"]
      assert turn.tool_calls == tool_calls
      assert turn.memory == memory
      assert turn.success? == true
    end

    test "allows nil program for parse failures in success context" do
      turn = Turn.success(1, "raw", nil, nil)

      assert turn.program == nil
      assert turn.success? == true
    end

    test "uses default values when params not provided" do
      turn = Turn.success(1, "raw", "(+ 1 2)", 3)

      assert turn.prints == []
      assert turn.tool_calls == []
      assert turn.memory == %{}
      assert turn.messages == nil
    end
  end

  describe "Turn.failure/5" do
    test "creates turn with success? set to false" do
      error = %{reason: :timeout, message: "Execution timed out"}
      turn = Turn.failure(1, "raw", "(infinite-loop)", error)

      assert turn.success? == false
    end

    test "sets all fields correctly" do
      error = %{reason: :eval_error, message: "division by zero"}
      tool_calls = [%{name: "get_data", args: %{}, result: 100}]
      memory = %{divisor: 0}

      turn =
        Turn.failure(
          2,
          "Let me divide by zero",
          "(/ 100 divisor)",
          error,
          %{prints: ["debug: divisor is 0"], tool_calls: tool_calls, memory: memory}
        )

      assert turn.number == 2
      assert turn.raw_response == "Let me divide by zero"
      assert turn.program == "(/ 100 divisor)"
      assert turn.result == error
      assert turn.prints == ["debug: divisor is 0"]
      assert turn.tool_calls == tool_calls
      assert turn.memory == memory
      assert turn.success? == false
    end

    test "allows nil program for parse failures" do
      error = %{reason: :parse_error, message: "Invalid syntax"}
      turn = Turn.failure(1, "invalid code", nil, error)

      assert turn.program == nil
      assert turn.result == error
      assert turn.success? == false
    end

    test "uses default values when params not provided" do
      error = %{reason: :timeout, message: "timeout"}
      turn = Turn.failure(1, "raw", "(bad)", error)

      assert turn.prints == []
      assert turn.tool_calls == []
      assert turn.memory == %{}
      assert turn.messages == nil
    end
  end

  describe "struct immutability" do
    test "all fields are accessible via dot notation" do
      turn = Turn.success(1, "raw", "program", :result, %{prints: ["print"], memory: %{a: 1}})

      assert turn.number == 1
      assert turn.raw_response == "raw"
      assert turn.program == "program"
      assert turn.result == :result
      assert turn.prints == ["print"]
      assert turn.tool_calls == []
      assert turn.memory == %{a: 1}
      assert turn.success? == true
    end

    test "supports pattern matching" do
      turn = Turn.success(5, "response", "(return 42)", 42)

      assert %Turn{number: n, result: r, success?: s} = turn
      assert n == 5
      assert r == 42
      assert s == true
    end

    test "pattern match on failure" do
      turn = Turn.failure(1, "resp", nil, :error)

      assert %Turn{success?: false, result: :error} = turn
    end
  end
end
