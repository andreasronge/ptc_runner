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

    test "memory_strategy defaults to :strict" do
      agent = test_agent()
      assert agent.memory_strategy == :strict
    end

    test "memory_strategy can be set to :rollback" do
      agent = test_agent(memory_strategy: :rollback)
      assert agent.memory_strategy == :rollback
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

  describe "memory_strategy: :rollback" do
    test "feeds error back to LLM and continues loop" do
      tools = %{
        "get-large" => fn %{} ->
          String.duplicate("x", 300)
        end
      }

      agent =
        SubAgent.new(
          prompt: "Store large data then return done",
          tools: tools,
          memory_limit: 200,
          memory_strategy: :rollback,
          max_turns: 3
        )

      llm = fn %{turn: turn, messages: messages} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(def large-data (tool/get-large {}))
```|}

          2 ->
            # Verify the error message was fed back
            last_msg = List.last(messages)
            assert last_msg.content =~ "Memory limit exceeded"
            assert last_msg.content =~ "rolled back"
            {:ok, ~S|```clojure
(return "recovered")
```|}

          _ ->
            {:ok, ~S|(return "fallback")|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == "recovered"
      assert step.usage.turns == 2
    end

    test "memory is rolled back to pre-turn state" do
      tools = %{
        "get-large" => fn %{} ->
          String.duplicate("x", 300)
        end
      }

      agent =
        SubAgent.new(
          prompt: "Test memory rollback",
          tools: tools,
          memory_limit: 200,
          memory_strategy: :rollback,
          max_turns: 3
        )

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            # First store something small that fits
            {:ok, ~S|```clojure
(def small "ok")
```|}

          2 ->
            # Now try to store something large - should exceed limit
            {:ok, ~S|```clojure
(def large-data (tool/get-large {}))
```|}

          3 ->
            # After rollback, small should still be in memory
            {:ok, ~S|```clojure
(return small)
```|}

          _ ->
            {:ok, ~S|(return "unexpected")|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})
      assert step.return == "ok"
    end
  end
end
