defmodule PtcRunner.Kernel.NamedMissionsContinuationTest do
  @moduledoc """
  named named missions isolate definition memory and value history.

  These are the questions the spike exists to answer, so they are asserted
  directly against the Kernel rather than through a manifest.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  defp config(extra_missions, limit_opts \\ []) do
    {:ok, kernel_component} = Library.component("kernel")
    {:ok, bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(Keyword.merge([subordinate_evaluations: 16], limit_opts))
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mission-continuations-spike")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: Map.put(extra_missions, "default", mission),
        input: %{},
        limits: limits,
        event_sink: sink
      )

    {config, sink}
  end

  defp two_missions do
    {:ok, research} = MissionEnvironment.new([])
    {:ok, review} = MissionEnvironment.new([])
    %{"research" => research, "review" => review}
  end

  test "a definition committed in one mission is invisible in another" do
    {config, _sink} = config(two_missions())

    source = """
    (do
      (kernel/eval-source-in "research" "(def secret 42)")
      (return
        {"same-mission" (get (kernel/eval-source-in "research" "(return secret)") :value)
         "other-mission" (get (kernel/eval-source-in "review" "(return secret)") :outcome)}))
    """

    assert {:ok, %{value: value}} = Kernel.run(source, config)
    assert value["same-mission"] == 42
    refute value["other-mission"] == :returned
  end

  test "the same name in two missions holds two different values" do
    {config, _sink} = config(two_missions())

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

  test "value history is per mission" do
    {config, _sink} = config(two_missions())

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

  test "an undeclared mission is refused rather than falling back to the default" do
    {config, _sink} = config(two_missions())

    source = ~S|(return (kernel/eval-source-in "nope" "(return 1)"))|

    assert {:ok, %{value: value}} = Kernel.run(source, config)
    assert value["status"] == "error"
    assert value["reason"] == "unknown_mission"
  end

  test "omitting the mission keeps the existing default behaviour" do
    {config, _sink} = config(%{})

    source = """
    (do
      (kernel/eval-source "(def kept 7)")
      (return (get (kernel/eval-source "(return kept)") :value)))
    """

    assert {:ok, %{value: 7}} = Kernel.run(source, config)
  end

  test "a trace can be queried down to one agent's mission" do
    {config, sink} = config(two_missions())

    source = """
    (do
      (kernel/eval-source-in "research" "(def a 1)")
      (kernel/eval-source-in "research" "(return a)")
      (kernel/eval-source-in "review" "(return 9)")
      (return :done))
    """

    assert {:ok, _result} = Kernel.run(source, config)

    events = Enum.map(EventSink.events(sink), &normalize_event/1)

    assert {:ok, %{"evaluations_by_mission" => by_mission}} =
             TraceLog.query_loaded(events, "spike", :counters, %{}, 1_000_000, :sanitized)

    assert by_mission == %{"research" => 2, "review" => 1}

    assert {:ok, %{"items" => items}} =
             TraceLog.query_loaded(
               events,
               "spike",
               :list_turns,
               %{"run_id" => "mission-continuations-spike", "mission_name" => "review"},
               1_000_000,
               :sanitized
             )

    assert items != []

    assert Enum.all?(items, fn item ->
             get_in(item, ["data", "mission_name"]) in [nil, "review"]
           end)
  end

  # The canonical JSONL projection uses string keys; sink events are structs.
  defp normalize_event(event) do
    Map.new(event, fn
      {:data, data} -> {"data", Map.new(data, fn {k, v} -> {to_string(k), v} end)}
      {:timestamp, %DateTime{} = at} -> {"timestamp", DateTime.to_iso8601(at)}
      {key, value} -> {to_string(key), value}
    end)
  end

  test "mission evaluation events carry the mission that ran them" do
    {config, sink} = config(two_missions())

    source = ~S|(return (get (kernel/eval-source-in "review" "(return 1)") :value))|

    assert {:ok, _result} = Kernel.run(source, config)

    missions =
      sink
      |> EventSink.events()
      |> Enum.filter(&(&1.type == "evaluation-started"))
      |> Enum.map(&get_in(&1.data, [:mission_name]))

    assert "review" in missions
  end

  test "evaluation preflight limits carry the requested mission" do
    {:ok, limits} = Limits.new(subordinate_source_bytes: 64)
    {:ok, state} = RunState.start(limits)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mission-preflight-limit")
    oversized = String.duplicate("x", 65)

    assert %{reason: :subordinate_source_bytes} =
             Evaluation.evaluate_mission(
               state,
               "review",
               mission,
               oversized,
               100,
               sink,
               nil
             )

    assert %{data: %{reason: :subordinate_source_bytes, mission_name: "review"}} =
             sink
             |> EventSink.events()
             |> Enum.find(&(&1.type == "limit-exceeded"))
  end
end
