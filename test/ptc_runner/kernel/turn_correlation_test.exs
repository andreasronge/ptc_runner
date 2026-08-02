defmodule PtcRunner.Kernel.TurnCorrelationTest do
  @moduledoc """
  A turn's capability calls must be attributable to the evaluation that made
  them, on both the canonical and the private plane.

  Without this the documented `evaluation_id` turn filter returns only the
  evaluation's own start/stop pair, and reconstructing "what happened in this
  turn" requires folding every event in sequence order by hand.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "capability events carry the evaluation that invoked them" do
    events = run_with_capability_calls()

    started = Enum.filter(events, &(&1["type"] == "capability-started"))
    refute started == []

    for event <- started do
      assert %{"evaluation_id" => evaluation_id} = event["data"],
             "capability-started carried no evaluation_id: #{inspect(event["data"])}"

      assert is_binary(evaluation_id)
    end

    stopped = Enum.filter(events, &(&1["type"] == "capability-stopped"))

    for event <- stopped do
      assert %{"evaluation_id" => evaluation_id} = event["data"]
      assert is_binary(evaluation_id)
    end
  end

  test "a mission call is attributed to its own evaluation, not the enclosing workflow" do
    events = run_with_capability_calls()

    workflow_evaluation =
      events
      |> Enum.find(
        &(&1["type"] == "evaluation-started" and &1["data"]["environment"] == "workflow")
      )
      |> get_in(["data", "evaluation_id"])

    mission_evaluation =
      events
      |> Enum.find(
        &(&1["type"] == "evaluation-started" and &1["data"]["environment"] == "mission")
      )
      |> get_in(["data", "evaluation_id"])

    assert is_binary(workflow_evaluation)
    assert is_binary(mission_evaluation)
    refute workflow_evaluation == mission_evaluation

    mission_call =
      Enum.find(events, &(&1["type"] == "capability-started" and &1["data"]["name"] == "probe"))

    assert mission_call["data"]["evaluation_id"] == mission_evaluation
  end

  test "every capability event's evaluation is open at that point in the sequence" do
    events = run_with_capability_calls()

    {_open, violations} =
      Enum.reduce(events, {[], []}, fn event, {open, violations} ->
        case {event["type"], event["data"]} do
          {"evaluation-started", %{"evaluation_id" => id}} ->
            {[id | open], violations}

          {"evaluation-stopped", %{"evaluation_id" => id}} ->
            {List.delete(open, id), violations}

          {"capability-started", %{"evaluation_id" => id}} ->
            if id in open,
              do: {open, violations},
              else: {open, [{event["sequence"], id, open} | violations]}

          _other ->
            {open, violations}
        end
      end)

    assert violations == [],
           "capability events attributed to a closed evaluation: #{inspect(violations)}"
  end

  @tag :tmp_dir
  test "a turn's private record joins its program with the calls it made", %{tmp_dir: tmp} do
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)

    {:ok, probe} =
      Capability.new(
        name: "probe",
        input_schema: %{"type" => "object", "additionalProperties" => true},
        effect: :read,
        callback: fn _arguments -> {:ok, %{"seen" => true}} end
      )

    {:ok, kernel_component} = Library.component("kernel")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)
    {:ok, mission} = MissionEnvironment.new(capabilities: [probe])
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "turn-private")

    {:ok, inspection} =
      InspectionSink.start(run_id: "turn-private", trace_id: "trace-turn-private")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink,
        inspection_sink: inspection,
        inspection_path: Path.join(tmp, "turn.inspection.jsonl")
      )

    assert {:ok, _result} =
             Kernel.run(
               ~S|(return (kernel/eval (program (return (tool/probe {"n" 1})))))|,
               config
             )

    assert {:ok, records} = InspectionSink.records(inspection)

    program = Enum.find(records, &(&1["record_type"] == "evaluation-source"))

    assert %{"correlation" => %{"evaluation_id" => evaluation_id}} = program
    assert program["payload"]["source"] =~ "tool/probe"

    call =
      Enum.find(
        records,
        &(&1["record_type"] == "capability-input" and &1["payload"]["name"] == "probe")
      )

    assert call["payload"]["evaluation_id"] == evaluation_id,
           "the private capability record cannot be joined to the program that made it"
  end

  test "a workflow annotation carries the evaluation that emitted it, and log/turns returns it beside the turn's capability call" do
    {:ok, probe} =
      Capability.new(
        name: "probe",
        input_schema: %{"type" => "object", "additionalProperties" => true},
        effect: :read,
        callback: fn _arguments -> {:ok, %{"seen" => true}} end
      )

    {:ok, kernel_component} = Library.component("kernel")
    {:ok, event_component} = Library.component("workflow.event")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component, event_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle, capabilities: [probe])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "annotation-correlation")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = ~S"""
    (do
      (tool/probe {})
      (workflow.event/annotate "progress" {"stage" "started"})
      (return 1))
    """

    assert {:ok, _result} = Kernel.run(source, config)

    events = sink |> EventSink.events() |> Enum.map(&normalize/1)

    workflow_evaluation_id =
      events
      |> Enum.find(&(&1["type"] == "evaluation-started"))
      |> get_in(["data", "evaluation_id"])

    assert is_binary(workflow_evaluation_id)

    annotation = Enum.find(events, &(&1["type"] == "workflow-annotation"))

    assert annotation["data"]["evaluation_id"] == workflow_evaluation_id,
           "the annotation cannot be attributed to the evaluation that emitted it"

    # The documented `evaluation_id` turn filter must return the annotation
    # alongside the turn's other capability activity, not only the
    # evaluation's own start/stop pair.
    assert {:ok, trace_capabilities} = TraceCapability.new(source: sink)
    callbacks = Map.new(trace_capabilities, &{&1.name, &1.callback})

    assert {:ok, %{"items" => turns}} =
             callbacks["trace-list-turns"].(%{
               "run_id" => "annotation-correlation",
               "evaluation_id" => workflow_evaluation_id,
               "limit" => 20
             })

    turn_types = Enum.map(turns, & &1["type"])
    assert "workflow-annotation" in turn_types
    assert "capability-started" in turn_types
  end

  defp run_with_capability_calls do
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)

    {:ok, probe} =
      Capability.new(
        name: "probe",
        input_schema: %{"type" => "object", "additionalProperties" => true},
        effect: :read,
        callback: fn _arguments -> {:ok, %{"seen" => true}} end
      )

    {:ok, kernel_component} = Library.component("kernel")
    {:ok, workflow_bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: workflow_bundle)
    {:ok, mission} = MissionEnvironment.new(capabilities: [probe])
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "turn-correlation")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, _result} =
             Kernel.run(
               ~S|(return (kernel/eval (program (return (tool/probe {"n" 1})))))|,
               config
             )

    sink |> EventSink.events() |> Enum.map(&normalize/1)
  end

  defp normalize(event) do
    event
    |> Jason.encode!()
    |> Jason.decode!()
  end
end
