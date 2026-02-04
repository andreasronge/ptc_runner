defmodule PtcRunner.PlanTracerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.PlanTracer

  describe "format_event/1" do
    # Planning events (from run/2)
    test "formats planning_started" do
      formatted = PlanTracer.format_event({:planning_started, %{mission: "Research stocks"}})

      assert formatted =~ "Planning"
      assert formatted =~ "Research stocks"
    end

    test "formats planning_finished" do
      formatted = PlanTracer.format_event({:planning_finished, %{task_count: 5}})

      assert formatted =~ "Plan generated"
      assert formatted =~ "5 tasks"
    end

    test "formats planning_failed" do
      formatted =
        PlanTracer.format_event({:planning_failed, %{reason: {:timeout, "LLM timed out"}}})

      assert formatted =~ "Planning failed"
      assert formatted =~ "timeout"
    end

    test "formats planning_retry" do
      formatted = PlanTracer.format_event({:planning_retry, %{validation_errors: 3}})

      assert formatted =~ "Plan invalid"
      assert formatted =~ "retrying"
      assert formatted =~ "3 validation error"
    end

    # Execution events
    test "formats execution_started" do
      formatted =
        PlanTracer.format_event({:execution_started, %{mission: "Test mission", task_count: 3}})

      assert formatted =~ "Mission: Test mission"
      assert formatted =~ "3 tasks"
    end

    test "formats execution_finished with status" do
      formatted =
        PlanTracer.format_event({:execution_finished, %{status: :ok, duration_ms: 1500}})

      assert formatted =~ "Execution finished"
      assert formatted =~ "ok"
      assert formatted =~ "1500ms"
    end

    test "formats task_started" do
      formatted = PlanTracer.format_event({:task_started, %{task_id: "fetch_data", attempt: 1}})

      assert formatted =~ "[START] fetch_data"
      # No attempt shown for first attempt
      refute formatted =~ "attempt"
    end

    test "formats task_started with retry attempt" do
      formatted = PlanTracer.format_event({:task_started, %{task_id: "fetch_data", attempt: 2}})

      assert formatted =~ "[START] fetch_data"
      assert formatted =~ "attempt 2"
    end

    test "formats task_succeeded" do
      formatted =
        PlanTracer.format_event({:task_succeeded, %{task_id: "fetch_data", duration_ms: 250}})

      assert formatted =~ "fetch_data"
      assert formatted =~ "250ms"
      # Contains checkmark (may be ANSI-encoded)
      assert formatted =~ "✓" or formatted =~ "[32m"
    end

    test "formats task_failed" do
      formatted = PlanTracer.format_event({:task_failed, %{task_id: "broken", reason: :timeout}})

      assert formatted =~ "broken"
      assert formatted =~ "timeout"
      # Contains X (may be ANSI-encoded)
      assert formatted =~ "✗" or formatted =~ "[31m"
    end

    test "formats task_skipped" do
      formatted =
        PlanTracer.format_event({:task_skipped, %{task_id: "step1", reason: :already_completed}})

      assert formatted =~ "step1"
      assert formatted =~ "Skipped"
      assert formatted =~ "already_completed"
    end

    test "formats verification_failed" do
      formatted =
        PlanTracer.format_event(
          {:verification_failed, %{task_id: "fetch", diagnosis: "Expected 5 items, got 0"}}
        )

      assert formatted =~ "fetch"
      assert formatted =~ "Verification failed"
      assert formatted =~ "Expected 5 items, got 0"
    end

    test "formats replan_started" do
      formatted =
        PlanTracer.format_event(
          {:replan_started, %{task_id: "fetch", diagnosis: "Count < 5", total_replans: 1}}
        )

      assert formatted =~ "REPLAN #1"
      assert formatted =~ "fetch"
      assert formatted =~ "Count < 5"
    end

    test "formats replan_finished" do
      formatted = PlanTracer.format_event({:replan_finished, %{new_tasks: 2}})

      assert formatted =~ "Repair plan"
      assert formatted =~ "2 task"
    end
  end

  describe "stateful tracer" do
    test "start and stop" do
      {:ok, tracer} = PlanTracer.start()
      assert is_pid(tracer)
      assert Process.alive?(tracer)

      :ok = PlanTracer.stop(tracer)
      refute Process.alive?(tracer)
    end

    test "handler/1 returns bound function" do
      {:ok, tracer} = PlanTracer.start(output: :logger)
      handler = PlanTracer.handler(tracer)

      assert is_function(handler, 1)
      # Just verify it doesn't crash
      handler.({:execution_started, %{mission: "Bound", task_count: 1}})

      PlanTracer.stop(tracer)
    end
  end

  describe "integration with PlanExecutor" do
    alias PtcRunner.Plan
    alias PtcRunner.PlanExecutor

    test "traces full execution lifecycle" do
      raw = %{
        "tasks" => [
          %{"id" => "step1", "input" => "Do step 1"},
          %{"id" => "step2", "input" => "Do step 2", "depends_on" => ["step1"]}
        ]
      }

      {:ok, plan} = Plan.parse(raw)

      events = Agent.start_link(fn -> [] end) |> elem(1)

      on_event = fn event ->
        # Verify formatting doesn't crash
        _ = PlanTracer.format_event(event)
        Agent.update(events, fn list -> list ++ [event] end)
      end

      mock_llm = fn _input ->
        {:ok, ~s({"result": "done"})}
      end

      {:ok, _metadata} =
        PlanExecutor.execute(plan, "Integration test mission",
          llm: mock_llm,
          max_turns: 1,
          on_event: on_event
        )

      event_list = Agent.get(events, & &1)
      Agent.stop(events)

      event_types = Enum.map(event_list, fn {type, _} -> type end)

      # Verify key events are present
      assert :execution_started in event_types
      assert :task_started in event_types
      assert :task_succeeded in event_types
      assert :execution_finished in event_types

      # Verify execution_started is first and execution_finished is last
      assert hd(event_types) == :execution_started
      assert List.last(event_types) == :execution_finished
    end

    test "traces replan flow" do
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
        _ = PlanTracer.format_event(event)
        Agent.update(events, fn list -> list ++ [event] end)
      end

      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      mock_llm = fn %{messages: [%{content: prompt}]} ->
        count = Agent.get_and_update(call_count, fn n -> {n, n + 1} end)

        cond do
          count == 0 ->
            {:ok, ~s({"items": []})}

          String.contains?(prompt, "repair specialist") ->
            {:ok, ~s({
              "tasks": [
                {"id": "fetch", "input": "Fetch with broader search", "verification": null}
              ]
            })}

          true ->
            {:ok, ~s({"items": [1, 2, 3]})}
        end
      end

      {:ok, _metadata} =
        PlanExecutor.execute(plan, "Replan test",
          llm: mock_llm,
          max_turns: 1,
          replan_cooldown_ms: 0,
          on_event: on_event
        )

      Agent.stop(call_count)
      event_list = Agent.get(events, & &1)
      Agent.stop(events)

      event_types = Enum.map(event_list, fn {type, _} -> type end)

      # Verify replan events appear
      assert :verification_failed in event_types
      assert :replan_started in event_types
      assert :replan_finished in event_types

      # Verify the formatted messages would contain expected text
      for event <- event_list do
        formatted = PlanTracer.format_event(event)
        assert is_binary(formatted)
      end
    end
  end
end
