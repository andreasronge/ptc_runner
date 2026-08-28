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

  test "mission evaluation names an unattached shipped library instead of denying it" do
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

    assert Enum.join(prints, "\n") =~
             "agent.core/run is a shipped library export that this session has not attached."

    assert :ok = RunState.stop(state)
  end

  test "workflow evaluation names an unattached shipped library instead of denying it" do
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

    assert Enum.join(prints, "\n") =~
             "agent.core/run is a shipped library export that this session has not attached."
  end
end
