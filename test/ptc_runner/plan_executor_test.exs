defmodule PtcRunner.PlanExecutorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Plan
  alias PtcRunner.PlanExecutor

  describe "execute/3 - basic execution" do
    test "successful execution without replanning" do
      raw = %{
        "tasks" => [
          %{"id" => "step1", "input" => "Do step 1"},
          %{"id" => "step2", "input" => "Do step 2", "depends_on" => ["step1"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input ->
        {:ok, ~s({"result": "done"})}
      end

      {:ok, metadata} = PlanExecutor.execute(plan, "Test mission", llm: mock_llm, max_turns: 1)

      assert Map.has_key?(metadata.results, "step1")
      assert Map.has_key?(metadata.results, "step2")
      assert metadata.replan_count == 0
      assert metadata.execution_attempts == 1
      assert metadata.replan_history == []
    end

    test "returns execution metadata with timing" do
      raw = %{"tasks" => [%{"id" => "task", "input" => "Do it"}]}
      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input ->
        Process.sleep(10)
        {:ok, ~s({"result": "done"})}
      end

      {:ok, metadata} = PlanExecutor.execute(plan, "Test mission", llm: mock_llm, max_turns: 1)

      assert metadata.total_duration_ms >= 10
      assert metadata.execution_attempts == 1
    end
  end

  describe "execute/3 - sanitization" do
    test "strips illegal verification predicate and executes without verification" do
      # Predicate uses "result" instead of "data/result" — Lisp.validate will flag it
      raw = %{
        "tasks" => [
          %{
            "id" => "fetch",
            "input" => "Fetch data",
            "verification" => "(map? result)",
            "on_verification_failure" => "stop"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input ->
        {:ok, ~s({"items": []})}
      end

      # Succeeds because the illegal predicate is stripped, not enforced
      {:ok, metadata} = PlanExecutor.execute(plan, "Test mission", llm: mock_llm, max_turns: 1)
      assert Map.has_key?(metadata.results, "fetch")
    end
  end

  describe "execute/3 - replanning" do
    test "triggers replan on verification failure with :replan strategy" do
      # First plan: task fails verification
      raw = %{
        "tasks" => [
          %{
            "id" => "fetch",
            "input" => "Fetch data",
            "verification" => "(> (count (get data/result \"items\")) 0)",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        cond do
          # First execution: return empty items (fails verification)
          count == 0 ->
            {:ok, ~s({"items": []})}

          # MetaPlanner replan call: return a repair plan
          String.contains?(prompt, "repair specialist") ->
            {:ok, ~s({
              "tasks": [
                {"id": "fetch", "input": "Fetch data with broader search", "verification": null}
              ]
            })}

          # Second execution: return valid items
          true ->
            {:ok, ~s({"items": [1, 2, 3]})}
        end
      end

      {:ok, metadata} =
        PlanExecutor.execute(plan, "Fetch some data",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0
        )

      Agent.stop(call_count)

      # Should have replanned once
      assert metadata.replan_count == 1
      assert metadata.execution_attempts == 2
      assert length(metadata.replan_history) == 1
      assert hd(metadata.replan_history).task_id == "fetch"
    end

    test "preserves completed results across replan" do
      # Two tasks: first succeeds, second fails and needs replan
      # Use an agent so the prompt has "Task:" prefix (distinguishes from replan context)
      raw = %{
        "agents" => %{
          "worker" => %{"prompt" => "You are a worker"}
        },
        "tasks" => [
          %{"id" => "step1", "agent" => "worker", "input" => "EXECUTE_STEP_ONE"},
          %{
            "id" => "step2",
            "agent" => "worker",
            "input" => "Second step",
            "depends_on" => ["step1"],
            "verification" => "false",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      step1_calls = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        cond do
          # Check for MetaPlanner replan call FIRST
          String.contains?(prompt, "repair specialist") ->
            # Repair plan includes step1 (to be skipped) and fixed step2
            {:ok, ~s({
              "agents": {"worker": {"prompt": "You are a worker"}},
              "tasks": [
                {"id": "step1", "agent": "worker", "input": "EXECUTE_STEP_ONE"},
                {"id": "step2", "agent": "worker", "input": "Fixed second step", "depends_on": ["step1"]}
              ]
            })}

          # Count actual execution of step1 (prompt contains "Task: EXECUTE_STEP_ONE")
          String.contains?(prompt, "Task: EXECUTE_STEP_ONE") ->
            Agent.update(step1_calls, &(&1 + 1))
            {:ok, ~s({"value": "step1_result"})}

          true ->
            {:ok, ~s({"value": "step2_result"})}
        end
      end

      {:ok, metadata} =
        PlanExecutor.execute(plan, "Two step mission",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0
        )

      # step1 should only be called once (skipped on replan)
      assert Agent.get(step1_calls, & &1) == 1
      Agent.stop(step1_calls)

      # Both results should be present
      assert metadata.results["step1"]["value"] == "step1_result"
      assert Map.has_key?(metadata.results, "step2")
    end

    test "stops at max_total_replans" do
      raw = %{
        "tasks" => [
          %{
            "id" => "always_fails",
            "input" => "This always fails",
            "verification" => "false",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "repair specialist") do
          # Always return the same failing plan
          {:ok, ~s({
            "tasks": [
              {"id": "always_fails", "input": "Still fails", "verification": "false", "on_verification_failure": "replan"}
            ]
          })}
        else
          {:ok, ~s({"result": "bad"})}
        end
      end

      {:error, reason, metadata} =
        PlanExecutor.execute(plan, "Doomed mission",
          llm: mock_llm,
          max_turns: 1,
          max_total_replans: 2,
          replan_cooldown_ms: 0
        )

      assert {:max_replans_exceeded, :total, 2} = reason
      assert metadata.replan_count == 2
      assert metadata.execution_attempts == 3
    end

    test "stops at max_replan_attempts per task" do
      raw = %{
        "tasks" => [
          %{
            "id" => "stubborn_task",
            "input" => "Keeps failing",
            "verification" => "false",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "repair specialist") do
          {:ok, ~s({
            "tasks": [
              {"id": "stubborn_task", "input": "Try again", "verification": "false", "on_verification_failure": "replan"}
            ]
          })}
        else
          {:ok, ~s({"result": "nope"})}
        end
      end

      {:error, reason, metadata} =
        PlanExecutor.execute(plan, "Stubborn mission",
          llm: mock_llm,
          max_turns: 1,
          max_replan_attempts: 2,
          max_total_replans: 10,
          replan_cooldown_ms: 0
        )

      assert {:max_replans_exceeded, :per_task, "stubborn_task", 2} = reason
      assert metadata.replan_count == 2
    end
  end

  describe "execute/3 - human review interaction" do
    test "pauses at human review and returns metadata" do
      raw = %{
        "tasks" => [
          %{"id" => "research", "input" => "Do research"},
          %{
            "id" => "approve",
            "input" => "Review results",
            "type" => "human_review",
            "depends_on" => ["research"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input ->
        {:ok, ~s({"findings": "research complete"})}
      end

      {:waiting, pending, metadata} =
        PlanExecutor.execute(plan, "Research mission", llm: mock_llm, max_turns: 1)

      assert length(pending) == 1
      assert hd(pending).task_id == "approve"
      assert Map.has_key?(metadata.results, "research")
      assert metadata.replan_count == 0
    end
  end

  describe "execute/3 - error handling" do
    test "returns error on task failure" do
      raw = %{
        "tasks" => [
          %{"id" => "broken", "input" => "This will break", "critical" => true}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input ->
        {:error, "LLM error"}
      end

      {:error, reason, metadata} =
        PlanExecutor.execute(plan, "Broken mission", llm: mock_llm, max_turns: 1)

      assert {:task_failed, "broken", _} = reason
      assert metadata.execution_attempts == 1
      assert metadata.replan_count == 0
    end

    test "returns error when replan generation fails" do
      raw = %{
        "tasks" => [
          %{
            "id" => "task",
            "input" => "Do something",
            "verification" => "false",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "repair specialist") do
          {:error, "Cannot generate plan"}
        else
          {:ok, ~s({"result": "done"})}
        end
      end

      {:error, reason, metadata} =
        PlanExecutor.execute(plan, "Mission",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0
        )

      assert {:replan_generation_failed, {:generation_error, _}} = reason
      assert metadata.execution_attempts == 1
    end
  end

  describe "execute/3 - plan validation" do
    test "rejects plan with circular dependency" do
      raw = %{
        "tasks" => [
          %{"id" => "a", "input" => "do A", "depends_on" => ["b"]},
          %{"id" => "b", "input" => "do B", "depends_on" => ["a"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input -> {:ok, ~s({"result": "done"})} end

      {:error, reason, metadata} = PlanExecutor.execute(plan, "Mission", llm: mock_llm)

      assert {:invalid_plan, issues} = reason
      assert Enum.any?(issues, &(&1.category == :cycle_detected))
      assert metadata.execution_attempts == 0
    end

    test "rejects plan with missing dependency" do
      raw = %{
        "tasks" => [
          %{"id" => "a", "input" => "do A", "depends_on" => ["nonexistent"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn _input -> {:ok, ~s({"result": "done"})} end

      {:error, reason, _metadata} = PlanExecutor.execute(plan, "Mission", llm: mock_llm)

      assert {:invalid_plan, issues} = reason
      assert Enum.any?(issues, &(&1.category == :missing_dependency))
    end

    test "rejects repair plan with validation errors" do
      raw = %{
        "tasks" => [
          %{
            "id" => "task",
            "input" => "Do something",
            "verification" => "false",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "repair specialist") do
          # Return a repair plan with a cycle
          {:ok, ~s({
            "tasks": [
              {"id": "a", "input": "do A", "depends_on": ["b"]},
              {"id": "b", "input": "do B", "depends_on": ["a"]}
            ]
          })}
        else
          {:ok, ~s({"result": "done"})}
        end
      end

      {:error, reason, metadata} =
        PlanExecutor.execute(plan, "Mission",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0
        )

      assert {:repair_plan_invalid, issues} = reason
      assert Enum.any?(issues, &(&1.category == :cycle_detected))
      # One execution attempt, then repair plan validation failed
      assert metadata.execution_attempts == 1
    end
  end

  describe "execute/3 - event emission" do
    test "emits events for successful execution" do
      raw = %{
        "tasks" => [
          %{"id" => "step1", "input" => "Do step 1"},
          %{"id" => "step2", "input" => "Do step 2", "depends_on" => ["step1"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      events = Agent.start_link(fn -> [] end) |> elem(1)

      on_event = fn event ->
        Agent.update(events, fn list -> list ++ [event] end)
      end

      mock_llm = fn _input ->
        {:ok, ~s({"result": "done"})}
      end

      {:ok, _metadata} =
        PlanExecutor.execute(plan, "Test mission",
          llm: mock_llm,
          max_turns: 1,
          on_event: on_event
        )

      event_list = Agent.get(events, & &1)
      Agent.stop(events)

      # Extract event types for easier assertion
      event_types = Enum.map(event_list, fn {type, _data} -> type end)

      # Verify key events are present
      assert :execution_started in event_types
      assert :task_started in event_types
      assert :task_succeeded in event_types
      assert :execution_finished in event_types

      # Verify execution_started is first and execution_finished is last
      assert hd(event_types) == :execution_started
      assert List.last(event_types) == :execution_finished

      # Verify execution_started data
      {:execution_started, start_data} = hd(event_list)
      assert start_data.mission == "Test mission"
      assert start_data.task_count == 2

      # Verify execution_finished data
      {:execution_finished, finish_data} = List.last(event_list)
      assert finish_data.status == :ok
      assert finish_data.duration_ms >= 0
    end

    test "emits events for replan flow" do
      raw = %{
        "tasks" => [
          %{
            "id" => "fetch",
            "input" => "Fetch data",
            "verification" => "(> (count (get data/result \"items\")) 0)",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      events = Agent.start_link(fn -> [] end) |> elem(1)

      on_event = fn event ->
        Agent.update(events, fn list -> list ++ [event] end)
      end

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        cond do
          # First execution: return empty items (fails verification)
          count == 0 ->
            {:ok, ~s({"items": []})}

          # MetaPlanner replan call: return a repair plan
          String.contains?(prompt, "repair specialist") ->
            {:ok, ~s({
              "tasks": [
                {"id": "fetch", "input": "Fetch data with broader search", "verification": null}
              ]
            })}

          # Second execution: return valid items
          true ->
            {:ok, ~s({"items": [1, 2, 3]})}
        end
      end

      {:ok, _metadata} =
        PlanExecutor.execute(plan, "Fetch some data",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0,
          on_event: on_event
        )

      Agent.stop(call_count)
      event_list = Agent.get(events, & &1)
      Agent.stop(events)

      event_types = Enum.map(event_list, fn {type, _data} -> type end)

      # Verify replan-related events are present
      assert :verification_failed in event_types
      assert :replan_started in event_types
      assert :replan_finished in event_types

      # Find the verification_failed event
      {_, vf_data} = Enum.find(event_list, fn {type, _} -> type == :verification_failed end)
      assert vf_data.task_id == "fetch"
      assert is_binary(vf_data.diagnosis)

      # Find the replan_started event
      {_, rs_data} = Enum.find(event_list, fn {type, _} -> type == :replan_started end)
      assert rs_data.task_id == "fetch"
      assert rs_data.total_replans == 1

      # Find the replan_finished event
      {_, rf_data} = Enum.find(event_list, fn {type, _} -> type == :replan_finished end)
      assert rf_data.new_tasks == 1
    end

    test "emits task_skipped for tasks in initial_results" do
      raw = %{
        "tasks" => [
          %{"id" => "step1", "input" => "Do step 1"},
          %{"id" => "step2", "input" => "Do step 2", "depends_on" => ["step1"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      events = Agent.start_link(fn -> [] end) |> elem(1)

      on_event = fn event ->
        Agent.update(events, fn list -> list ++ [event] end)
      end

      mock_llm = fn _input ->
        {:ok, ~s({"result": "step2_done"})}
      end

      # Provide step1 in initial_results - it should be skipped
      {:ok, metadata} =
        PlanExecutor.execute(plan, "Test mission",
          llm: mock_llm,
          max_turns: 1,
          initial_results: %{"step1" => %{"value" => "precomputed"}},
          on_event: on_event
        )

      event_list = Agent.get(events, & &1)
      Agent.stop(events)

      # Find task_skipped event
      skipped_events = Enum.filter(event_list, fn {type, _} -> type == :task_skipped end)
      assert length(skipped_events) == 1
      {_, skip_data} = hd(skipped_events)
      assert skip_data.task_id == "step1"
      assert skip_data.reason == :already_completed

      # Verify step1 result is preserved
      assert metadata.results["step1"] == %{"value" => "precomputed"}
    end
  end

  describe "run/2 - high-level API" do
    test "generates and executes plan from mission" do
      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn _input ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        # First call is MetaPlanner.plan, subsequent calls are task execution
        if count == 0 do
          {:ok, ~s({
            "tasks": [
              {"id": "step1", "input": "Do step 1"},
              {"id": "step2", "input": "Do step 2", "depends_on": ["step1"]}
            ]
          })}
        else
          {:ok, ~s({"result": "done"})}
        end
      end

      {:ok, results, metadata} =
        PlanExecutor.run("Test mission",
          llm: mock_llm,
          max_turns: 1
        )

      Agent.stop(call_count)

      assert Map.has_key?(results, "step1")
      assert Map.has_key?(results, "step2")
      assert metadata.execution_attempts >= 1
    end

    test "emits planning events" do
      events = Agent.start_link(fn -> [] end) |> elem(1)

      on_event = fn event ->
        Agent.update(events, fn list -> list ++ [event] end)
      end

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn _input ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        if count == 0 do
          {:ok, ~s({"tasks": [{"id": "task", "input": "Do it"}]})}
        else
          {:ok, ~s({"result": "done"})}
        end
      end

      {:ok, _results, _metadata} =
        PlanExecutor.run("Test",
          llm: mock_llm,
          max_turns: 1,
          on_event: on_event
        )

      Agent.stop(call_count)
      event_list = Agent.get(events, & &1)
      Agent.stop(events)

      event_types = Enum.map(event_list, fn {type, _} -> type end)

      # Verify planning events are present
      assert :planning_started in event_types
      assert :planning_finished in event_types
      assert :execution_started in event_types
    end

    test "returns error when planning fails" do
      mock_llm = fn _input ->
        {:error, "LLM error"}
      end

      {:error, reason, metadata} = PlanExecutor.run("Test", llm: mock_llm)

      assert {:planning_failed, _} = reason
      assert metadata.execution_attempts == 0
    end
  end

  describe "trial history helper functions" do
    test "truncate_value/2 handles strings under limit" do
      assert PlanExecutor.truncate_value("short", 100) == "short"
    end

    test "truncate_value/2 truncates long strings" do
      long = String.duplicate("a", 100)
      result = PlanExecutor.truncate_value(long, 20)
      assert String.length(result) == 20
      assert String.ends_with?(result, "...")
    end

    test "truncate_value/2 handles nil" do
      assert PlanExecutor.truncate_value(nil, 100) == "(nil)"
    end

    test "truncate_value/2 handles maps via Jason" do
      result = PlanExecutor.truncate_value(%{key: "value"}, 100)
      assert result == ~s({"key":"value"})
    end

    test "truncate_value/2 handles lists via Jason" do
      result = PlanExecutor.truncate_value([1, 2, 3], 100)
      assert result == "[1,2,3]"
    end

    test "build_approach_summary/2 extracts agent info" do
      raw = %{
        "agents" => %{
          "researcher" => %{"prompt" => "You research topics", "tools" => ["search", "fetch"]}
        },
        "tasks" => [
          %{"id" => "task1", "agent" => "researcher", "input" => "Find stock prices"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)
      summary = PlanExecutor.build_approach_summary(plan, "task1")

      assert summary =~ "Agent: researcher"
      assert summary =~ "Tools: search, fetch"
      # Task input is stored separately in replan record, not in approach
      refute summary =~ "Task:"
    end

    test "build_approach_summary/2 handles missing task" do
      raw = %{"tasks" => [%{"id" => "task1", "input" => "Do something"}]}
      {:ok, plan} = Plan.parse(raw)
      summary = PlanExecutor.build_approach_summary(plan, "nonexistent")

      assert summary == "(task not found)"
    end

    test "build_replan_record/3 returns enriched record" do
      raw = %{
        "agents" => %{
          "worker" => %{"prompt" => "Worker agent", "tools" => ["tool1"]}
        },
        "tasks" => [
          %{"id" => "fetch", "agent" => "worker", "input" => "Fetch data from API"}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      state = %{
        plan: plan,
        replan_count: 0
      }

      failure_context = %{
        task_id: "fetch",
        task_output: %{items: []},
        diagnosis: "Expected items, got empty"
      }

      record = PlanExecutor.build_replan_record(state, failure_context, 2)

      assert record.attempt == 1
      assert record.task_id == "fetch"
      assert record.input =~ "Fetch data"
      assert record.approach =~ "Agent: worker"
      assert record.approach =~ "Tools: tool1"
      assert record.output =~ "items"
      assert record.diagnosis =~ "Expected items"
      assert record.new_task_count == 2
      assert %DateTime{} = record.timestamp
    end
  end

  describe "execute/3 - enriched replan history" do
    test "replan_history contains enriched records" do
      raw = %{
        "agents" => %{
          "worker" => %{"prompt" => "Worker", "tools" => ["tool1"]}
        },
        "tasks" => [
          %{
            "id" => "fetch",
            "agent" => "worker",
            "input" => "Fetch some data",
            "verification" => "(> (count (get data/result \"items\")) 0)",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        cond do
          count == 0 ->
            {:ok, ~s({"items": []})}

          String.contains?(prompt, "repair specialist") ->
            {:ok, ~s({
              "tasks": [
                {"id": "fetch", "input": "Fetch with broader search"}
              ]
            })}

          true ->
            {:ok, ~s({"items": [1, 2, 3]})}
        end
      end

      {:ok, metadata} =
        PlanExecutor.execute(plan, "Fetch data mission",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0
        )

      Agent.stop(call_count)

      assert length(metadata.replan_history) == 1
      record = hd(metadata.replan_history)

      # Verify enriched fields are present
      assert record.attempt == 1
      assert record.task_id == "fetch"
      assert is_binary(record.input)
      assert is_binary(record.approach)
      assert is_binary(record.output)
      assert is_binary(record.diagnosis)
      assert is_integer(record.new_task_count)
      assert %DateTime{} = record.timestamp
    end

    test "trial_history is passed to MetaPlanner in replan opts" do
      raw = %{
        "tasks" => [
          %{
            "id" => "task1",
            "input" => "First task",
            "verification" => "false",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      captured_prompts = Agent.start_link(fn -> [] end) |> elem(1)
      replan_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "repair specialist") do
          count = Agent.get_and_update(replan_count, fn n -> {n, n + 1} end)
          Agent.update(captured_prompts, fn list -> list ++ [prompt] end)

          if count == 0 do
            # First replan: return plan that still fails (to trigger second replan)
            {:ok, ~s({
              "tasks": [
                {"id": "task1", "input": "Attempt 2", "verification": "false", "on_verification_failure": "replan"}
              ]
            })}
          else
            # Second replan: return plan without verification (success)
            {:ok, ~s({
              "tasks": [
                {"id": "task1", "input": "Final attempt"}
              ]
            })}
          end
        else
          {:ok, ~s({"result": "data"})}
        end
      end

      # Run with enough replans to see trial history in second replan
      {:ok, _metadata} =
        PlanExecutor.execute(plan, "Test mission",
          llm: mock_llm,
          max_turns: 1,
          max_total_replans: 3,
          replan_cooldown_ms: 0
        )

      prompts = Agent.get(captured_prompts, & &1)
      Agent.stop(captured_prompts)
      Agent.stop(replan_count)

      # Should have 2 replan prompts
      assert length(prompts) == 2

      # Second replan should include trial history from first attempt
      second_prompt = Enum.at(prompts, 1)
      assert second_prompt =~ "Trial & Error History"
      assert second_prompt =~ "Attempt 1"
    end
  end

  describe "execute/3 - self-correcting repair" do
    test "retries replan when repair plan has validation errors" do
      raw = %{
        "tasks" => [
          %{
            "id" => "task",
            "input" => "Do something",
            "verification" => "false",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        cond do
          # First execution
          count == 0 ->
            {:ok, ~s({"result": "bad"})}

          # First replan attempt: return invalid plan with cycle
          String.contains?(prompt, "repair specialist") and
              not String.contains?(prompt, "Validation Errors") ->
            {:ok, ~s({
              "tasks": [
                {"id": "a", "input": "do A", "depends_on": ["b"]},
                {"id": "b", "input": "do B", "depends_on": ["a"]}
              ]
            })}

          # Second replan attempt (with validation feedback): return valid plan
          String.contains?(prompt, "Validation Errors") ->
            {:ok, ~s({
              "tasks": [
                {"id": "task", "input": "Fixed version"}
              ]
            })}

          # Final execution succeeds
          true ->
            {:ok, ~s({"result": "good"})}
        end
      end

      {:ok, metadata} =
        PlanExecutor.execute(plan, "Test mission",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0
        )

      Agent.stop(call_count)

      # Should have succeeded after self-correction
      assert metadata.replan_count == 1
      assert Map.has_key?(metadata.results, "task")
    end

    test "fails after self-correction produces another invalid plan" do
      raw = %{
        "tasks" => [
          %{
            "id" => "task",
            "input" => "Do something",
            "verification" => "false",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        if String.contains?(prompt, "repair specialist") do
          # Always return invalid plan with cycle
          {:ok, ~s({
            "tasks": [
              {"id": "a", "input": "do A", "depends_on": ["b"]},
              {"id": "b", "input": "do B", "depends_on": ["a"]}
            ]
          })}
        else
          {:ok, ~s({"result": "bad"})}
        end
      end

      {:error, reason, _metadata} =
        PlanExecutor.execute(plan, "Test mission",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0
        )

      assert {:repair_plan_invalid, issues} = reason
      assert Enum.any?(issues, &(&1.category == :cycle_detected))
    end
  end

  describe "execute/3 - quality gate replan cycle" do
    test "quality gate fails → replan → re-execution succeeds" do
      # Plan: fetch data, then analyze (with quality gate enabled)
      raw = %{
        "tasks" => [
          %{"id" => "fetch_balance", "input" => "Fetch balance sheet data"},
          %{
            "id" => "analyze",
            "input" => "Analyze all financial data: {{results.fetch_balance}}",
            "depends_on" => ["fetch_balance"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)
      gate_call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn input ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)
        output_mode = Map.get(input, :output)
        messages = Map.get(input, :messages, [])
        prompt = if messages != [], do: hd(messages) |> Map.get(:content, ""), else: ""

        cond do
          # Quality gate checks (JSON mode with sufficiency prompt)
          output_mode == :json and String.contains?(prompt, "data sufficiency checker") ->
            gate_count = Agent.get_and_update(gate_call_count, fn n -> {n, n + 1} end)

            if gate_count == 0 do
              # First gate: insufficient data
              {:ok,
               ~s|{"sufficient": false, "missing": ["income statement data"], "evidence": [{"field": "income data", "found": false, "source": "NOT FOUND"}]}|}
            else
              # Second gate (after replan): data is now sufficient
              {:ok,
               ~s|{"sufficient": true, "missing": [], "evidence": [{"field": "income data", "found": true, "source": "fetch_income"}]}|}
            end

          # MetaPlanner replan call
          String.contains?(prompt, "repair specialist") ->
            # Return a repair plan that adds the missing data fetch
            {:ok, ~s({
              "tasks": [
                {"id": "fetch_balance", "input": "Fetch balance sheet data"},
                {"id": "fetch_income", "input": "Fetch income statement data"},
                {"id": "analyze", "input": "Analyze all financial data", "depends_on": ["fetch_balance", "fetch_income"]}
              ]
            })}

          # Regular task execution
          count == 0 ->
            {:ok, ~s({"balance_sheet": {"assets": 100}})}

          true ->
            {:ok, ~s({"result": "analysis complete"})}
        end
      end

      {:ok, metadata} =
        PlanExecutor.execute(plan, "Analyze company finances",
          llm: mock_llm,
          max_turns: 1,
          quality_gate: true,
          replan_cooldown_ms: 0
        )

      Agent.stop(call_count)
      Agent.stop(gate_call_count)

      # Verify replan happened
      assert metadata.replan_count == 1
      # Verify final results contain the analyze task
      assert Map.has_key?(metadata.results, "analyze")
      assert Map.has_key?(metadata.results, "fetch_balance")
    end
  end
end
