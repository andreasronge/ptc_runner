defmodule PtcRunner.Kernel.UnattachedLibraryDocTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.StreamingInspection

  test "mission evaluation gives exact export and environment-neutral attachment guidance" do
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)

    assert %{outcome: :continued, value: nil, prints: prints} =
             Evaluation.evaluate_source(
               state,
               "default",
               mission,
               ~S|(doc "agent.core/run")|,
               1_000
             )

    output = Enum.join(prints, "\n")
    assert output =~ ~s|"agent.core/run" is an export of shipped library "agent.core"|
    assert output =~ "--project PROJECT.json or --manifest MANIFEST.json"
    assert output =~ ~s|{"library": "agent.core"}|
    assert output =~ "workflow.components or missions.<name>.components"
    assert output =~ "Other hosts must construct an environment"
    assert output =~ "fixed profiles cannot change their component set"

    assert :ok = RunState.stop(state)
  end

  test "workflow evaluation gives exact export attachment guidance" do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "unattached-library-doc")

    {:ok, inspection_sink} =
      StreamingInspection.start(
        run_id: "unattached-library-doc",
        trace_id: "unattached-library-doc"
      )

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink,
        inspection_sink: inspection_sink
      )

    assert {:ok, _} = Kernel.run(~S|(doc "agent.core/run")|, config)
    assert {:ok, records} = StreamingInspection.records(inspection_sink)

    prints =
      records
      |> Enum.filter(&(&1["record_type"] == "execution-prints"))
      |> Enum.flat_map(& &1["payload"]["prints"])

    output = Enum.join(prints, "\n")
    assert output =~ ~s|"agent.core/run" is an export of shipped library "agent.core"|
    assert output =~ "--project PROJECT.json or --manifest MANIFEST.json"
    assert output =~ ~s|{"library": "agent.core"}|
    assert output =~ "workflow.components or missions.<name>.components"
  end
end
