defmodule PtcRunner.MetaPlannerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.MetaPlanner
  alias PtcRunner.Plan

  describe "plan/2" do
    test "generates plan from mission with available tools" do
      mock_llm = fn _input ->
        {:ok, ~s({
          "tasks": [
            {"id": "search_info", "agent": "researcher", "input": "Search for AAPL stock info"},
            {"id": "summarize", "agent": "writer", "input": "Summarize findings", "depends_on": ["search_info"]}
          ],
          "agents": {
            "researcher": {"prompt": "You research topics", "tools": ["search"]},
            "writer": {"prompt": "You write summaries", "tools": []}
          }
        })}
      end

      {:ok, plan} =
        MetaPlanner.plan("Research AAPL stock",
          llm: mock_llm,
          available_tools: %{
            "search" => "Search the web for information"
          }
        )

      assert %Plan{} = plan
      assert length(plan.tasks) == 2

      task_ids = Enum.map(plan.tasks, & &1.id)
      assert "search_info" in task_ids
      assert "summarize" in task_ids
    end

    test "generates plan without tools" do
      mock_llm = fn _input ->
        {:ok, ~s({
          "tasks": [
            {"id": "process", "input": "Process the data"}
          ]
        })}
      end

      {:ok, plan} = MetaPlanner.plan("Process data", llm: mock_llm)

      assert length(plan.tasks) == 1
      assert hd(plan.tasks).id == "process"
    end

    test "returns error on LLM failure" do
      mock_llm = fn _input ->
        {:error, "LLM unavailable"}
      end

      {:error, reason} = MetaPlanner.plan("Test", llm: mock_llm)
      assert {:generation_error, _} = reason
    end

    test "returns error on invalid JSON" do
      mock_llm = fn _input ->
        {:ok, "not valid json"}
      end

      {:error, reason} = MetaPlanner.plan("Test", llm: mock_llm)
      # SubAgent catches invalid JSON first (since output: :text), returning generation_error
      assert {:generation_error, _} = reason
    end
  end

  describe "format_trial_history/1" do
    test "returns empty string for empty list" do
      assert MetaPlanner.format_trial_history([]) == ""
    end

    test "formats single attempt" do
      history = [
        %{
          attempt: 1,
          task_id: "fetch_prices",
          approach: "Agent: researcher\nTools: search\nTask: Search for prices",
          output: ~s({"items": []}),
          diagnosis: "Expected at least 5 items, got 0"
        }
      ]

      result = MetaPlanner.format_trial_history(history)

      assert result =~ "Trial & Error History"
      assert result =~ "DO NOT repeat these failed approaches"
      assert result =~ ~s(Attempt 1 - Task "fetch_prices")
      assert result =~ "Agent: researcher"
      assert result =~ ~s({"items": []})
      assert result =~ "Expected at least 5 items"
    end

    test "includes self-reflection section" do
      history = [
        %{
          attempt: 1,
          task_id: "test",
          approach: "test approach",
          output: "test output",
          diagnosis: "test diagnosis"
        }
      ]

      result = MetaPlanner.format_trial_history(history)

      assert result =~ "Self-Reflection Required"
      assert result =~ "Pattern Recognition"
      assert result =~ "Root Cause Analysis"
      assert result =~ "Strategy Shift"
      assert result =~ "MUST address the root cause"
    end

    test "formats multiple attempts with separators" do
      history = [
        %{
          attempt: 1,
          task_id: "task1",
          approach: "first approach",
          output: "first output",
          diagnosis: "first failure"
        },
        %{
          attempt: 2,
          task_id: "task1",
          approach: "second approach",
          output: "second output",
          diagnosis: "second failure"
        }
      ]

      result = MetaPlanner.format_trial_history(history)

      assert result =~ "Attempt 1"
      assert result =~ "Attempt 2"
      assert result =~ "first approach"
      assert result =~ "second approach"
      # Separator between attempts
      assert result =~ "---"
    end

    test "handles missing optional fields gracefully" do
      history = [
        %{
          attempt: 1,
          task_id: "task1"
          # Missing approach, output, diagnosis
        }
      ]

      result = MetaPlanner.format_trial_history(history)

      assert result =~ "Attempt 1"
      assert result =~ "(not recorded)"
    end
  end

  describe "replan/4 with trial_history" do
    test "includes trial history in prompt when provided" do
      captured_prompt = Agent.start_link(fn -> nil end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        Agent.update(captured_prompt, fn _ -> prompt end)

        {:ok, ~s({
          "tasks": [
            {"id": "fixed_task", "input": "Fixed version"}
          ]
        })}
      end

      trial_history = [
        %{
          attempt: 1,
          task_id: "broken_task",
          approach: "Agent: worker\nTools: search\nTask: Search for data",
          output: ~s({"items": []}),
          diagnosis: "Empty result"
        }
      ]

      failure_context = %{
        task_id: "broken_task",
        task_output: %{items: []},
        diagnosis: "Still failing"
      }

      {:ok, _plan} =
        MetaPlanner.replan("Test mission", %{}, failure_context,
          llm: mock_llm,
          trial_history: trial_history
        )

      prompt = Agent.get(captured_prompt, & &1)
      Agent.stop(captured_prompt)

      # Verify trial history is included
      assert prompt =~ "Trial & Error History"
      assert prompt =~ "Attempt 1"
      assert prompt =~ "Agent: worker"
      assert prompt =~ "Self-Reflection Required"
    end

    test "does not include trial history section when empty" do
      captured_prompt = Agent.start_link(fn -> nil end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        Agent.update(captured_prompt, fn _ -> prompt end)

        {:ok, ~s({
          "tasks": [
            {"id": "fixed_task", "input": "Fixed version"}
          ]
        })}
      end

      failure_context = %{
        task_id: "broken_task",
        task_output: %{},
        diagnosis: "Task failed"
      }

      {:ok, _plan} =
        MetaPlanner.replan("Test mission", %{}, failure_context,
          llm: mock_llm,
          trial_history: []
        )

      prompt = Agent.get(captured_prompt, & &1)
      Agent.stop(captured_prompt)

      # Should not include trial history section when empty
      refute prompt =~ "Trial & Error History"
    end
  end

  describe "replan/4 with validation_errors" do
    test "includes validation errors in prompt for self-correction" do
      captured_prompt = Agent.start_link(fn -> nil end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        Agent.update(captured_prompt, fn _ -> prompt end)

        {:ok, ~s({
          "tasks": [
            {"id": "fixed_task", "input": "Fixed version"}
          ]
        })}
      end

      validation_errors = [
        %{
          category: :cycle_detected,
          message: "Circular dependency: a -> b -> a",
          severity: :error
        }
      ]

      failure_context = %{
        task_id: "broken_task",
        task_output: %{},
        diagnosis: "Task failed"
      }

      {:ok, _plan} =
        MetaPlanner.replan("Test mission", %{}, failure_context,
          llm: mock_llm,
          validation_errors: validation_errors
        )

      prompt = Agent.get(captured_prompt, & &1)
      Agent.stop(captured_prompt)

      # Verify validation errors are included in prompt
      assert prompt =~ "Previous Plan Had Validation Errors"
      assert prompt =~ "cycle_detected"
      assert prompt =~ "Circular dependency"
    end
  end
end
