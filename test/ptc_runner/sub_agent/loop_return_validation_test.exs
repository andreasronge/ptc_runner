defmodule PtcRunner.SubAgent.LoopReturnValidationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  # Mock LLM that returns predefined responses in sequence
  defp mock_llm(responses) when is_list(responses) do
    agent = Agent.start_link(fn -> responses end) |> elem(1)

    fn %{messages: _} ->
      response =
        Agent.get_and_update(agent, fn
          [h | t] -> {h, t}
          [] -> {"(return :done)", []}
        end)

      {:ok, %{content: response, tokens: %{}}}
    end
  end

  describe "return type validation" do
    test "valid return type terminates loop successfully" do
      agent =
        SubAgent.new(
          prompt: "Return an integer",
          signature: "() -> :int",
          max_turns: 3
        )

      llm = mock_llm(["(return 42)"])

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{})
      assert step.return == 42
    end

    test "invalid return type feeds error back to LLM for retry" do
      agent =
        SubAgent.new(
          prompt: "Return an integer",
          signature: "() -> :int",
          max_turns: 3
        )

      # First try returns string (invalid), second try returns int (valid)
      llm = mock_llm(["(return \"not an int\")", "(return 42)"])

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{}, debug: true)

      # Should succeed on second attempt
      assert step.return == 42

      # Should have used 2 turns
      assert step.usage.turns == 2

      # First trace entry should have validation error feedback (with debug: true)
      [first_trace | _] = step.trace
      assert first_trace.llm_feedback =~ "Return type validation failed"
      assert first_trace.llm_feedback =~ "Expected: :int"
    end

    test "validation error on last turn returns error step" do
      agent =
        SubAgent.new(
          prompt: "Return an integer",
          signature: "() -> :int",
          max_turns: 2
        )

      # Both attempts return invalid type
      llm = mock_llm(["(return \"wrong\")", "(return \"still wrong\")"])

      {:error, step} = SubAgent.run(agent, llm: llm, context: %{})

      # Should fail with max_turns_exceeded (ran out of turns trying to fix)
      assert step.fail.reason == :max_turns_exceeded
    end

    test "no signature skips validation" do
      agent =
        SubAgent.new(
          prompt: "Return anything",
          max_turns: 3
          # No signature - any return type accepted
        )

      llm = mock_llm(["(return \"anything works\")"])

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{})
      assert step.return == "anything works"
    end

    test ":any return type skips validation" do
      agent =
        SubAgent.new(
          prompt: "Return anything",
          signature: "() -> :any",
          max_turns: 3
        )

      llm = mock_llm(["(return {:complex \"data\"})"])

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{})
      assert step.return == %{complex: "data"}
    end

    test "single-shot mode skips validation" do
      agent =
        SubAgent.new(
          prompt: "Return something",
          signature: "() -> :int",
          max_turns: 1
        )

      # Returns string expression which doesn't match signature
      # In single-shot, the expression result is the return value
      llm = mock_llm(["(str \"not\" \" an int\")"])

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{})

      # Should accept without validation (single-shot can't retry anyway)
      assert step.return == "not an int"
    end

    test "nested map validation errors include paths in feedback" do
      agent =
        SubAgent.new(
          prompt: "Return structured data",
          signature: "() -> {count :int, items [:string]}",
          max_turns: 3
        )

      # First: wrong nested type, Second: correct
      llm =
        mock_llm([
          "(return {:count \"not int\" :items [1 2 3]})",
          "(return {:count 5 :items [\"a\" \"b\"]})"
        ])

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{}, debug: true)

      assert step.return == %{count: 5, items: ["a", "b"]}

      # First trace should show path-based errors (with debug: true)
      [first_trace | _] = step.trace
      assert first_trace.llm_feedback =~ "[count]"
      assert first_trace.llm_feedback =~ "[items.0]"
    end

    test "(fail ...) is not validated" do
      agent =
        SubAgent.new(
          prompt: "Might fail",
          signature: "() -> :int",
          max_turns: 3
        )

      # Fail with non-integer reason (should be allowed)
      llm = mock_llm(["(fail {:reason \"something went wrong\"})"])

      {:error, step} = SubAgent.run(agent, llm: llm, context: %{})

      # Should fail with the provided reason, not validation error
      assert step.fail.reason == :failed
    end

    test "LLM can correct type error by converting value" do
      agent =
        SubAgent.new(
          prompt: "Return employee ID",
          signature: "() -> :int",
          max_turns: 4
        )

      # Simulates the benchmark failure scenario:
      # 1. Returns string "54" (wrong type)
      # 2. Gets feedback about type error
      # 3. Corrects by returning integer 54
      llm =
        mock_llm([
          "(return \"54\")",
          "(return 54)"
        ])

      {:ok, step} = SubAgent.run(agent, llm: llm, context: %{})

      assert step.return == 54
      assert step.usage.turns == 2
    end
  end
end
