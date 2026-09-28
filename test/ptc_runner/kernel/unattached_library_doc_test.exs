defmodule PtcRunner.Kernel.UnattachedLibraryDocTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunState

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
end
