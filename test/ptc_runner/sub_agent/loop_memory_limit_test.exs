defmodule PtcRunner.SubAgent.LoopMemoryLimitTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  describe "memory limit configuration" do
    test "memory_limit field can be set" do
      agent = test_agent(memory_limit: 1000)

      assert agent.memory_limit == 1000
    end

    test "memory_limit defaults to 1MB" do
      agent = test_agent()

      assert agent.memory_limit == 1_048_576
    end

    test "memory_limit can be nil" do
      agent = test_agent(memory_limit: nil)

      assert agent.memory_limit == nil
    end

    test "memory_limit is enforced during execution" do
      turn_counter = :counters.new(1, [:atomics])

      tools = %{
        "get-large" => fn %{} ->
          # Return a large string that will exceed 200 bytes when stored via def
          "this is a very long string designed to exceed the memory limit when stored in memory along with the erlang encoding overhead so we can test that the memory limit enforcement is working correctly"
        end
      }

      agent =
        SubAgent.new(
          prompt: "Store large data",
          tools: tools,
          memory_limit: 200,
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        :counters.put(turn_counter, 1, turn)

        case turn do
          1 ->
            # V2: Use def to explicitly store data in memory
            # This will exceed the memory limit
            {:ok, ~S|```clojure
(def large-data (tool/get-large {}))
```|}

          _ ->
            {:ok, "Should not reach here"}
        end
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.fail.reason == :memory_limit_exceeded
      assert step.fail.message =~ "Memory limit exceeded"
      assert step.usage.turns == 1
    end
  end
end
