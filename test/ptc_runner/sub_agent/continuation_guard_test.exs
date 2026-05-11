defmodule PtcRunner.SubAgent.ContinuationGuardTest do
  use ExUnit.Case, async: true

  alias PtcRunner.{Step, SubAgent}

  test "continuation_guard can stop before the next LLM turn" do
    llm = fn _ -> {:ok, "(+ 40 2)"} end

    guard = fn turn, _state, _next_state ->
      assert turn.result == 42
      {:stop, {:error, Step.error(:partial_side_effects, "guarded", %{})}}
    end

    agent = SubAgent.new(prompt: "Compute", max_turns: 2)

    assert {:error, step} = SubAgent.run(agent, llm: llm, continuation_guard: guard)
    assert step.fail.reason == :partial_side_effects
    assert step.fail.message == "guarded"
  end

  test "explicit single-shot loop path uses llm stored on agent" do
    llm = fn _ -> {:ok, "(return 42)"} end
    agent = SubAgent.new(prompt: "Compute", max_turns: 1, completion_mode: :explicit, llm: llm)

    assert {:ok, step} = SubAgent.run(agent)
    assert step.return == 42
  end
end
