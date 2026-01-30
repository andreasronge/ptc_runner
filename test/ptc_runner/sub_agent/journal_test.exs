defmodule PtcRunner.SubAgent.JournalTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.SubAgentTestHelpers

  alias PtcRunner.SubAgent

  describe "journal threading through SubAgent.run" do
    test "journal accumulates across turns and is returned in step" do
      agent = test_agent(max_turns: 3)

      llm = fn %{turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(task "step-1" (+ 1 2))
```|}

          2 ->
            {:ok, ~S|```clojure
(return (task "step-2" (+ 10 20)))
```|}
        end
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, journal: %{})

      assert step.return == 30
      assert step.journal == %{"step-1" => 3, "step-2" => 30}
    end

    test "pre-populated journal provides cached values" do
      agent = test_agent(max_turns: 2)

      llm = fn %{turn: 1} ->
        # Uses a nonexistent tool in the task body - proves cache hit
        {:ok, ~S|```clojure
(return (task "cached" (tool/nonexistent {})))
```|}
      end

      {:ok, step} = SubAgent.run(agent, llm: llm, journal: %{"cached" => "from_previous_run"})

      assert step.return == "from_previous_run"
      assert step.journal == %{"cached" => "from_previous_run"}
    end

    test "mission log is injected into system prompt when journal is non-empty" do
      agent = test_agent(max_turns: 2)

      llm = fn %{system: system, turn: 1} ->
        # Verify the mission log appears in the system prompt
        assert system =~ "Mission Log (Completed Tasks)"
        assert system =~ "order_1"
        assert system =~ "tx_123"

        {:ok, ~S|```clojure
(return "ok")
```|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, journal: %{"order_1" => "tx_123"})
    end

    test "mission log is not injected when journal is empty" do
      agent = test_agent(max_turns: 2)

      llm = fn %{system: system, turn: 1} ->
        refute system =~ "Mission Log (Completed Tasks)"

        {:ok, ~S|```clojure
(return "ok")
```|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, journal: %{})
    end

    test "re-invocation pattern: second run skips completed tasks" do
      tools = %{"charge" => fn %{"amount" => n} -> "tx_#{n}" end}
      agent = test_agent(max_turns: 2, tools: tools)

      # Run 1: execute the task
      llm1 = fn %{turn: 1} ->
        {:ok, ~S|```clojure
(return (task "charge_100" (tool/charge {:amount 100})))
```|}
      end

      {:ok, step1} = SubAgent.run(agent, llm: llm1, journal: %{})
      assert step1.return == "tx_100"
      assert step1.journal == %{"charge_100" => "tx_100"}

      # Run 2: re-invoke with journal, tool not needed (proves skip)
      agent2 = test_agent(max_turns: 2, tools: %{})

      llm2 = fn %{turn: 1} ->
        {:ok, ~S|```clojure
(return (task "charge_100" (tool/charge {:amount 100})))
```|}
      end

      {:ok, step2} = SubAgent.run(agent2, llm: llm2, journal: step1.journal)
      assert step2.return == "tx_100"
      assert step2.journal == %{"charge_100" => "tx_100"}
    end
  end
end
