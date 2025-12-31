defmodule PtcRunner.SubAgent.LoopResourceLimitsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Loop

  import PtcRunner.TestSupport.SubAgentTestHelpers

  describe "nesting depth limit (SYS-07)" do
    test "accepts execution at depth 0 (root level)" do
      agent = test_agent(max_depth: 3)
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, _nesting_depth: 0)

      assert step.return == %{value: 42}
    end

    test "accepts execution just under max_depth" do
      agent = test_agent(max_depth: 3)
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, _nesting_depth: 2)

      assert step.return == %{value: 42}
    end

    test "rejects execution at max_depth" do
      agent = test_agent(max_depth: 3)
      llm = simple_return_llm()

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, _nesting_depth: 3)

      assert step.fail.reason == :max_depth_exceeded
      assert step.fail.message =~ "Nesting depth limit exceeded"
      assert step.usage.turns == 0
    end

    test "rejects execution beyond max_depth" do
      agent = test_agent(max_depth: 3)
      llm = simple_return_llm()

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, _nesting_depth: 5)

      assert step.fail.reason == :max_depth_exceeded
      assert step.fail.message =~ "5 >= 3"
    end

    test "uses custom max_depth" do
      agent = test_agent(max_depth: 1)
      llm = simple_return_llm()

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, _nesting_depth: 1)

      assert step.fail.reason == :max_depth_exceeded
    end
  end

  describe "global turn budget (SYS-08)" do
    test "decrements turn budget on each turn" do
      agent = test_agent(max_turns: 5, turn_budget: 20)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          2 -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
        end
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{}, _remaining_turns: 20)

      assert step.return == %{value: 42}
      assert step.usage.turns == 2
    end

    test "rejects when turn budget exhausted before start" do
      agent = test_agent(max_turns: 5, turn_budget: 20)
      llm = simple_return_llm()

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, _remaining_turns: 0)

      assert step.fail.reason == :turn_budget_exhausted
      assert step.fail.message =~ "Turn budget exhausted"
      assert step.usage.turns == 0
    end

    test "stops when turn budget exhausted during execution" do
      agent = test_agent(max_turns: 5, turn_budget: 20)

      llm = fn %{turn: turn} ->
        case turn do
          1 -> {:ok, "```clojure\n(+ 1 2)\n```"}
          _ -> {:ok, ~S|```clojure
(call "return" {:value 42})
```|}
        end
      end

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, _remaining_turns: 1)

      assert step.fail.reason == :turn_budget_exhausted
      assert step.fail.message =~ "Turn budget exhausted"
      # Should complete first turn, then fail on second
      assert step.usage.turns == 1
    end

    test "uses default turn_budget of 20" do
      agent = test_agent()

      assert agent.turn_budget == 20
    end

    test "allows custom turn_budget" do
      agent = test_agent(turn_budget: 50)

      assert agent.turn_budget == 50
    end
  end

  describe "mission timeout (SYS-09)" do
    test "accepts execution when mission timeout not set" do
      agent = test_agent(mission_timeout: nil)
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{value: 42}
    end

    test "accepts execution when mission deadline is in future" do
      agent = test_agent(mission_timeout: 5000)
      llm = simple_return_llm()

      {:ok, step} = Loop.run(agent, llm: llm, context: %{})

      assert step.return == %{value: 42}
    end

    test "rejects when mission deadline exceeded" do
      # Deadline in the past
      past_deadline = DateTime.utc_now() |> DateTime.add(-100, :millisecond)

      agent = test_agent(max_turns: 5)
      llm = simple_return_llm()

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, _mission_deadline: past_deadline)

      assert step.fail.reason == :mission_timeout
      assert step.fail.message =~ "Mission timeout exceeded"
    end

    test "inherits mission deadline from parent" do
      # Deadline in the past
      past_deadline = DateTime.utc_now() |> DateTime.add(-100, :millisecond)

      agent = test_agent()
      llm = simple_return_llm()

      {:error, step} = Loop.run(agent, llm: llm, context: %{}, _mission_deadline: past_deadline)

      assert step.fail.reason == :mission_timeout
      assert step.fail.message =~ "Mission timeout exceeded"
    end
  end
end
