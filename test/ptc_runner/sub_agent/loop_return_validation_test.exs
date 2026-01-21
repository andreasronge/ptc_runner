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
      assert step.return == %{"complex" => "data"}
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
