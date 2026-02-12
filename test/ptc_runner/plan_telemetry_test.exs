defmodule PtcRunner.PlanTelemetryTest do
  @moduledoc """
  Integration tests for plan-layer telemetry events.

  Verifies that PlanExecutor emits the expected telemetry events with
  correct metadata for execution, task, and replan lifecycle events.
  """
  use ExUnit.Case, async: false

  alias PtcRunner.Plan
  alias PtcRunner.PlanExecutor

  setup do
    table = :ets.new(:plan_telemetry_events, [:bag, :public])

    handler = fn event, measurements, metadata, config ->
      :ets.insert(config.table, {event, measurements, metadata, System.monotonic_time()})
    end

    handler_id = "plan-telemetry-test-#{:erlang.unique_integer()}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ptc_runner, :plan_executor, :execution, :start],
        [:ptc_runner, :plan_executor, :execution, :stop],
        [:ptc_runner, :plan_executor, :task, :start],
        [:ptc_runner, :plan_executor, :task, :stop],
        [:ptc_runner, :plan_executor, :replan, :start],
        [:ptc_runner, :plan_executor, :replan, :stop]
      ],
      handler,
      %{table: table}
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      if :ets.info(table) != :undefined do
        :ets.delete(table)
      end
    end)

    {:ok, table: table}
  end

  defp get_events_by_name(table, event_name) do
    table
    |> :ets.tab2list()
    |> Enum.filter(fn {event, _, _, _} -> event == event_name end)
  end

  # Build an LLM function that returns results based on call count
  defp counting_llm(responses) do
    counter = :counters.new(1, [:atomics])

    fn _opts ->
      :counters.add(counter, 1, 1)
      count = :counters.get(counter, 1)
      response = Enum.at(responses, count - 1, List.last(responses))
      {:ok, response}
    end
  end

  # Parse a plan from a raw map, raising on failure
  defp parse_plan!(raw) do
    {:ok, plan} = Plan.parse(raw)
    plan
  end

  describe "execution.start has phases (Issue 4)" do
    test "includes phases list with phase index and task_ids", %{table: table} do
      plan =
        parse_plan!(%{
          "tasks" => [
            %{"id" => "step1", "input" => "Do step 1"},
            %{"id" => "step2", "input" => "Do step 2", "depends_on" => ["step1"]}
          ]
        })

      # LLM returns JSON results for both tasks (auto-detected as JSON mode since no tools)
      llm = counting_llm([~s|{"result": "step1 done"}|, ~s|{"result": "step2 done"}|])

      {:ok, _metadata} = PlanExecutor.execute(plan, "Test mission", llm: llm)

      starts = get_events_by_name(table, [:ptc_runner, :plan_executor, :execution, :start])
      assert length(starts) == 1

      [{_, _, meta, _}] = starts
      assert is_list(meta.phases)
      assert length(meta.phases) == 2

      # Phase 0: step1 (no deps), Phase 1: step2 (depends on step1)
      [phase0, phase1] = meta.phases
      assert phase0.phase == 0
      assert phase0.task_ids == ["step1"]
      assert phase1.phase == 1
      assert phase1.task_ids == ["step2"]
    end
  end

  describe "execution.stop has total_tasks and task_ids (Issue 9)" do
    test "includes total_tasks count and task_ids list", %{table: table} do
      plan =
        parse_plan!(%{
          "tasks" => [
            %{"id" => "research", "input" => "Research topic"},
            %{"id" => "summarize", "input" => "Summarize", "depends_on" => ["research"]}
          ]
        })

      llm = counting_llm([~s|{"data": "found info"}|, ~s|{"summary": "brief"}|])

      {:ok, _metadata} = PlanExecutor.execute(plan, "Test mission", llm: llm)

      stops = get_events_by_name(table, [:ptc_runner, :plan_executor, :execution, :stop])
      assert length(stops) == 1

      [{_, _, meta, _}] = stops
      assert meta.total_tasks == 2
      assert Enum.sort(meta.task_ids) == ["research", "summarize"]
      assert meta.status == :ok
    end
  end

  describe "task.start has input (Issue 1)" do
    test "includes task input field in metadata", %{table: table} do
      plan =
        parse_plan!(%{
          "tasks" => [
            %{"id" => "fetch", "input" => "Fetch stock prices for AAPL"},
            %{
              "id" => "analyze",
              "input" => "Analyze the data",
              "depends_on" => ["fetch"]
            }
          ]
        })

      llm = counting_llm([~s|{"price": 150}|, ~s|{"analysis": "bullish"}|])

      {:ok, _metadata} = PlanExecutor.execute(plan, "Stock analysis", llm: llm)

      task_starts = get_events_by_name(table, [:ptc_runner, :plan_executor, :task, :start])
      assert length(task_starts) == 2

      # Find each task's start event
      fetch_start =
        Enum.find(task_starts, fn {_, _, meta, _} -> meta.task_id == "fetch" end)

      analyze_start =
        Enum.find(task_starts, fn {_, _, meta, _} -> meta.task_id == "analyze" end)

      assert fetch_start != nil
      assert analyze_start != nil

      {_, _, fetch_meta, _} = fetch_start
      {_, _, analyze_meta, _} = analyze_start

      assert fetch_meta.input == "Fetch stock prices for AAPL"
      assert analyze_meta.input == "Analyze the data"
    end
  end

  describe "task.start has dependency_result_sizes for synthesis gates (Issue 10)" do
    test "includes dependency_result_sizes map for synthesis gate tasks", %{table: table} do
      plan =
        parse_plan!(%{
          "agents" => %{
            "synthesizer" => %{
              "prompt" => "You synthesize information",
              "tools" => []
            }
          },
          "tasks" => [
            %{"id" => "research1", "input" => "Research topic A"},
            %{"id" => "research2", "input" => "Research topic B"},
            %{
              "id" => "synthesize",
              "input" => "Combine research findings",
              "type" => "synthesis_gate",
              "agent" => "synthesizer",
              "depends_on" => ["research1", "research2"]
            }
          ]
        })

      # research1, research2 return data; synthesize compresses
      llm =
        counting_llm([
          ~s|{"findings": "Topic A data with some content"}|,
          ~s|{"findings": "Topic B data with some content"}|,
          ~s|{"summary": "Combined findings from A and B with enough content to pass validation"}|
        ])

      {:ok, _metadata} = PlanExecutor.execute(plan, "Research synthesis", llm: llm)

      task_starts = get_events_by_name(table, [:ptc_runner, :plan_executor, :task, :start])

      # Find the synthesis gate's start event
      synth_start =
        Enum.find(task_starts, fn {_, _, meta, _} -> meta.task_id == "synthesize" end)

      assert synth_start != nil
      {_, _, synth_meta, _} = synth_start

      assert Map.has_key?(synth_meta, :dependency_result_sizes)
      assert is_map(synth_meta.dependency_result_sizes)
      assert Map.has_key?(synth_meta.dependency_result_sizes, "research1")
      assert Map.has_key?(synth_meta.dependency_result_sizes, "research2")
      assert is_integer(synth_meta.dependency_result_sizes["research1"])
      assert is_integer(synth_meta.dependency_result_sizes["research2"])
      assert synth_meta.dependency_result_sizes["research1"] > 0
      assert synth_meta.dependency_result_sizes["research2"] > 0
    end
  end

  describe "task.stop has verification_error for verification failures (Issue 7)" do
    test "includes verification_error when task verification fails", %{table: table} do
      # Use a predicate that passes sanitization (valid syntax + valid bindings)
      # but evaluates to false at runtime, producing a verification_failed error.
      # (get data/result "valid") returns false/nil -> predicate returns diagnosis string
      plan =
        parse_plan!(%{
          "tasks" => [
            %{
              "id" => "fetch",
              "input" => "Fetch data",
              "verification" => ~s|(if (get data/result "valid") true "Data not valid")|,
              "on_verification_failure" => "stop"
            }
          ]
        })

      # Return data where "valid" is false, so verification fails
      llm = counting_llm([~s|{"valid": false, "data": "bad"}|])

      {:error, _reason, _metadata} = PlanExecutor.execute(plan, "Test mission", llm: llm)

      task_stops = get_events_by_name(table, [:ptc_runner, :plan_executor, :task, :stop])
      assert task_stops != []

      # Find the fetch task stop
      fetch_stop =
        Enum.find(task_stops, fn {_, _, meta, _} -> meta.task_id == "fetch" end)

      assert fetch_stop != nil
      {_, _, stop_meta, _} = fetch_stop

      assert Map.has_key?(stop_meta, :verification_error)
      assert is_binary(stop_meta.verification_error)
    end
  end

  describe "replan.start and replan.stop emitted on replan (Issue 8)" do
    test "emits replan events with expected metadata", %{table: table} do
      plan =
        parse_plan!(%{
          "tasks" => [
            %{
              "id" => "fetch",
              "input" => "Fetch data",
              "verification" => ~s|(if (get data/result "valid") true "Data not valid")|,
              "on_verification_failure" => "replan"
            }
          ]
        })

      call_count = :counters.new(1, [:atomics])

      # First call: fetch returns invalid data (triggers replan)
      # Second call: MetaPlanner.replan generates a repair plan (via LLM)
      # Third call: re-execution of the repaired task succeeds
      llm = fn _opts ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          # Initial fetch - returns data that fails verification
          1 ->
            {:ok, ~s|{"valid": false, "data": "bad"}|}

          # MetaPlanner.replan call - return a repair plan JSON
          2 ->
            {:ok,
             Jason.encode!(%{
               "tasks" => [
                 %{
                   "id" => "fetch_v2",
                   "input" => "Fetch data with corrected approach"
                 }
               ]
             })}

          # Re-execution of fetch_v2
          _ ->
            {:ok, ~s|{"valid": true, "data": "good"}|}
        end
      end

      result =
        PlanExecutor.execute(plan, "Test replan mission",
          llm: llm,
          replan_cooldown_ms: 0,
          max_replan_attempts: 3
        )

      # Result could be :ok or :error depending on repair plan execution
      # We mainly care about the telemetry events being emitted
      assert elem(result, 0) in [:ok, :error]

      replan_starts =
        get_events_by_name(table, [:ptc_runner, :plan_executor, :replan, :start])

      # At least one replan should have been triggered
      assert replan_starts != []

      [{_, _, start_meta, _} | _] = replan_starts
      assert start_meta.task_id == "fetch"
      assert is_binary(start_meta.diagnosis)
      assert is_integer(start_meta.attempt)
      assert start_meta.attempt >= 1

      # Check replan.stop if the repair plan was successfully generated
      replan_stops =
        get_events_by_name(table, [:ptc_runner, :plan_executor, :replan, :stop])

      if replan_stops != [] do
        [{_, _, stop_meta, _} | _] = replan_stops
        assert is_integer(stop_meta.new_task_count)
        assert stop_meta.new_task_count >= 1
        assert stop_meta.task_id == "fetch"
      end
    end
  end

  describe "replan.stop emitted on error paths (F20)" do
    test "emits replan.stop with status :error when repair plan is invalid", %{table: table} do
      plan =
        parse_plan!(%{
          "tasks" => [
            %{
              "id" => "task",
              "input" => "Do something",
              "verification" => "false",
              "on_verification_failure" => "replan"
            }
          ]
        })

      llm = fn input ->
        messages = Map.get(input, :messages, [])
        prompt = if messages != [], do: hd(messages) |> Map.get(:content, ""), else: ""

        if String.contains?(prompt, "repair specialist") do
          # Return invalid plan with cycle (both initial and retry fail validation)
          {:ok,
           ~s|{"tasks": [{"id": "a", "input": "do A", "depends_on": ["b"]}, {"id": "b", "input": "do B", "depends_on": ["a"]}]}|}
        else
          {:ok, ~s|{"result": "done"}|}
        end
      end

      {:error, {:repair_plan_invalid, _}, _} =
        PlanExecutor.execute(plan, "Mission", llm: llm, max_turns: 1, replan_cooldown_ms: 0)

      replan_stops =
        get_events_by_name(table, [:ptc_runner, :plan_executor, :replan, :stop])

      assert replan_stops != []

      [{_, _, meta, _} | _] = replan_stops
      assert meta.status == :error
      assert meta.task_id == "task"
    end

    test "emits replan.stop with status :error when replan generation fails", %{table: table} do
      plan =
        parse_plan!(%{
          "tasks" => [
            %{
              "id" => "task",
              "input" => "Do something",
              "verification" => "false",
              "on_verification_failure" => "replan"
            }
          ]
        })

      llm = fn input ->
        messages = Map.get(input, :messages, [])
        prompt = if messages != [], do: hd(messages) |> Map.get(:content, ""), else: ""

        if String.contains?(prompt, "repair specialist") do
          {:error, "Cannot generate plan"}
        else
          {:ok, ~s|{"result": "done"}|}
        end
      end

      {:error, {:replan_generation_failed, _}, _} =
        PlanExecutor.execute(plan, "Mission", llm: llm, max_turns: 1, replan_cooldown_ms: 0)

      replan_stops =
        get_events_by_name(table, [:ptc_runner, :plan_executor, :replan, :stop])

      assert length(replan_stops) == 1

      [{_, _, meta, _}] = replan_stops
      assert meta.status == :error
      assert meta.task_id == "task"
    end
  end

  describe "execution metadata correct after replan failure (F21)" do
    test "metadata has incremented replan_count and merged results on replan error",
         %{table: table} do
      plan =
        parse_plan!(%{
          "agents" => %{
            "worker" => %{"prompt" => "You are a worker"}
          },
          "tasks" => [
            %{"id" => "step1", "agent" => "worker", "input" => "FIRST_STEP_INPUT"},
            %{
              "id" => "step2",
              "agent" => "worker",
              "input" => "Second step",
              "depends_on" => ["step1"],
              "verification" => "false",
              "on_verification_failure" => "replan"
            }
          ]
        })

      llm = fn input ->
        messages = Map.get(input, :messages, [])
        prompt = if messages != [], do: hd(messages) |> Map.get(:content, ""), else: ""

        cond do
          String.contains?(prompt, "repair specialist") ->
            {:error, "Cannot generate plan"}

          String.contains?(prompt, "Task: FIRST_STEP_INPUT") ->
            {:ok, ~s|{"value": "step1_result"}|}

          true ->
            {:ok, ~s|{"value": "step2_result"}|}
        end
      end

      {:error, _, metadata} =
        PlanExecutor.execute(plan, "Two step mission",
          llm: llm,
          max_turns: 1,
          replan_cooldown_ms: 0
        )

      # F21: replan_count should be 1 (replan was attempted even though it failed)
      assert metadata.replan_count == 1

      # F21: results should include completed step1 (merged from context)
      assert metadata.results["step1"]["value"] == "step1_result"

      # Verify execution.stop telemetry also has correct data
      exec_stops =
        get_events_by_name(table, [:ptc_runner, :plan_executor, :execution, :stop])

      assert length(exec_stops) == 1

      [{_, _, exec_meta, _}] = exec_stops
      assert exec_meta.replan_count == 1
      assert Map.has_key?(exec_meta.results, "step1")
    end
  end
end
