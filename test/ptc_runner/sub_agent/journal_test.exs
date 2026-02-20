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
      agent = test_agent(max_turns: 2, journaling: true)

      llm = fn %{system: system, turn: 1} ->
        # Verify the mission log appears in the system prompt
        assert system =~ "<mission_log>"
        assert system =~ "order_1"
        assert system =~ "tx_123"

        {:ok, ~S|```clojure
(return "ok")
```|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, journal: %{"order_1" => "tx_123"})
    end

    test "mission log is not injected when journal is empty" do
      agent = test_agent(max_turns: 2, journaling: true)

      llm = fn %{system: system, turn: 1} ->
        refute system =~ "Mission Log (Completed Tasks)"

        {:ok, ~S|```clojure
(return "ok")
```|}
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, journal: %{})
    end

    test "mission log shows completed task results on turn 2" do
      tools = %{"lookup" => fn %{"id" => id} -> "user_#{id}" end}
      agent = test_agent(max_turns: 3, tools: tools, journaling: true)

      llm = fn %{system: system, turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(task "fetch_user_42" (tool/lookup {:id 42}))
```|}

          2 ->
            # Turn 2: verify the LLM sees the completed task in the system prompt
            assert system =~ "[done] fetch_user_42: \"user_42\""

            {:ok, ~S|```clojure
(return "ok")
```|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, journal: %{})
    end

    test "mission log shows multiple completed tasks with correct values" do
      agent = test_agent(max_turns: 3, journaling: true)

      llm = fn %{system: system, turn: turn} ->
        case turn do
          1 ->
            {:ok, ~S|```clojure
(do (task "check_auth" (> 1 0)) (task "fetch_total" (+ 100 50)))
```|}

          2 ->
            # Both tasks should appear in the mission log
            assert system =~ "[done] check_auth: true"
            assert system =~ "[done] fetch_total: 150"

            {:ok, ~S|```clojure
(return "done")
```|}
        end
      end

      {:ok, _step} = SubAgent.run(agent, llm: llm, journal: %{})
    end

    test "re-invocation: mission log shows tasks from previous run" do
      agent = test_agent(max_turns: 2, journaling: true)

      # The LLM sees pre-populated journal entries in the mission log
      # and can use the values in its program
      llm = fn %{system: system, turn: 1} ->
        assert system =~ "[done] prepare_wire: \"hold_abc\""
        assert system =~ "[done] approval: \"approved\""

        {:ok, ~S|```clojure
(return (task "execute_wire" (str (task "prepare_wire" nil) "_sent")))
```|}
      end

      journal = %{"prepare_wire" => "hold_abc", "approval" => "approved"}
      {:ok, step} = SubAgent.run(agent, llm: llm, journal: journal)

      # LLM used cached "hold_abc" from journal and appended "_sent"
      assert step.return == "hold_abc_sent"
      assert step.journal["execute_wire"] == "hold_abc_sent"
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
