defmodule PtcRunner.TestSupport.LiveStatusFixtures do
  @moduledoc false

  # Shared by LiveStatusTest (async) and LiveStatusGlobalStateTest.

  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  def run_config(limits, sink, input) do
    {:ok, workflow} = WorkflowEnvironment.new([])
    {:ok, mission} = MissionEnvironment.new([])

    run_config(limits, sink, input, workflow, mission)
  end

  def run_config(limits, sink, input, workflow, mission) do
    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
      input: input,
      limits: limits,
      event_sink: sink
    )
  end
end
