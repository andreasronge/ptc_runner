defmodule PtcRunner.SubAgent.SingleShotUnwrappingTest do
  use ExUnit.Case, async: true
  alias PtcRunner.SubAgent

  describe "single-shot sentinel unwrapping" do
    test "unwraps {:__ptc_return__, value} into raw value" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      # Simulating an LLM that explicitly uses (return ...)
      llm = fn _ -> {:ok, "```clojure\n(return 42)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 42
    end

    test "converts {:__ptc_fail__, value} into error step" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      # Simulating an LLM that explicitly uses (fail ...)
      llm = fn _ -> {:ok, "```clojure\n(fail \"oops\")\n```"} end

      {:error, step} = SubAgent.run(agent, llm: llm)
      assert step.return == nil
      assert step.fail.reason == :failed
      assert step.fail.message == "\"oops\""
    end

    test "handles structured fail results correctly" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _ -> {:ok, "```clojure\n(fail {:reason :not_found :message \"No data\"})\n```"} end

      {:error, step} = SubAgent.run(agent, llm: llm)
      assert step.fail.reason == :not_found
      assert step.fail.message == "No data"
    end

    test "handles normal values without unwrapping (identity)" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)
      llm = fn _ -> {:ok, "```clojure\n42\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 42
    end

    test "preserves multi-turn sentinels (no accidental unwrapping in loop mode)" do
      # Note: SubAgent.run delegates to Loop.run which doesn't use the unwrapping logic
      # But it's good to be sure.
      agent = SubAgent.new(prompt: "Test", max_turns: 2)
      # Loop handler should catch this and terminate
      llm = fn _ -> {:ok, "```clojure\n(return 42)\n```"} end

      {:ok, step} = SubAgent.run(agent, llm: llm)
      assert step.return == 42
      # The loop handler also unwraps it, but via a different code path
      # We just want to ensure we didn't break things.
    end
  end
end
