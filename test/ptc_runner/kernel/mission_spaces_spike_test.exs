defmodule PtcRunner.Kernel.MissionSpacesSpikeTest do
  @moduledoc """
  SPIKE: named mission spaces isolate definition memory and value history.

  These are the questions the spike exists to answer, so they are asserted
  directly against the Kernel rather than through a manifest.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  defp config(extra_missions) do
    {:ok, kernel_component} = Library.component("kernel")
    {:ok, bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(subordinate_evaluations: 16)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mission-spaces-spike")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        extra_missions: extra_missions,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {config, sink}
  end

  defp two_spaces do
    {:ok, research} = MissionEnvironment.new([])
    {:ok, review} = MissionEnvironment.new([])
    %{"research" => research, "review" => review}
  end

  test "a definition committed in one space is invisible in another" do
    {config, _sink} = config(two_spaces())

    source = """
    (do
      (kernel/eval-source-in "research" "(def secret 42)")
      (return
        {"same-space" (get (kernel/eval-source-in "research" "(return secret)") :value)
         "other-space" (get (kernel/eval-source-in "review" "(return secret)") :outcome)}))
    """

    assert {:ok, %{value: value}} = Kernel.run(source, config)
    assert value["same-space"] == 42
    refute value["other-space"] == :returned
  end

  test "the same name in two spaces holds two different values" do
    {config, _sink} = config(two_spaces())

    source = """
    (do
      (kernel/eval-source-in "research" "(def role \\"gatherer\\")")
      (kernel/eval-source-in "review" "(def role \\"checker\\")")
      (return
        {"research" (get (kernel/eval-source-in "research" "(return role)") :value)
         "review" (get (kernel/eval-source-in "review" "(return role)") :value)}))
    """

    assert {:ok, %{value: value}} = Kernel.run(source, config)
    assert value == %{"research" => "gatherer", "review" => "checker"}
  end

  test "value history is per space" do
    {config, _sink} = config(two_spaces())

    source = """
    (do
      (kernel/eval-source-in "research" "(+ 1 1)")
      (kernel/eval-source-in "review" "(+ 10 10)")
      (return
        {"research" (get (kernel/eval-source-in "research" "(return *1)") :value)
         "review" (get (kernel/eval-source-in "review" "(return *1)") :value)}))
    """

    assert {:ok, %{value: value}} = Kernel.run(source, config)
    assert value == %{"research" => 2, "review" => 20}
  end

  test "an undeclared space is refused rather than falling back to the default" do
    {config, _sink} = config(two_spaces())

    source = ~S|(return (kernel/eval-source-in "nope" "(return 1)"))|

    assert {:ok, %{value: value}} = Kernel.run(source, config)
    assert value.status == :error
    assert value.reason == :unknown_mission_space
  end

  test "omitting the space keeps the pre-spike default behaviour" do
    {config, _sink} = config(%{})

    source = """
    (do
      (kernel/eval-source "(def kept 7)")
      (return (get (kernel/eval-source "(return kept)") :value)))
    """

    assert {:ok, %{value: 7}} = Kernel.run(source, config)
  end

  test "mission evaluation events carry the space that ran them" do
    {config, sink} = config(two_spaces())

    source = ~S|(return (get (kernel/eval-source-in "review" "(return 1)") :value))|

    assert {:ok, _result} = Kernel.run(source, config)

    spaces =
      sink
      |> EventSink.events()
      |> Enum.filter(&(&1.type == "evaluation-started"))
      |> Enum.map(&get_in(&1.data, [:space]))

    assert "review" in spaces
  end
end
