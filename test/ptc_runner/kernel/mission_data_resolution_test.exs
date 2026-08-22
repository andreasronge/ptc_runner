defmodule PtcRunner.Kernel.MissionDataResolutionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.MissionInventory
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment

  @sentinel "SECRET_TICKET_SENTINEL"

  test "source_referenceable_forms matches the inventory grant list and skips unparseable keys" do
    data = %{"orders" => [1], "tickets" => [2], "not a symbol" => [3]}
    {:ok, mission} = MissionEnvironment.new(data: data)
    {:ok, inventory} = MissionInventory.build(mission, Limits.defaults())

    forms = MissionInventory.source_referenceable_forms(data)

    rendered_forms =
      inventory.rendered |> Jason.decode!() |> Map.fetch!("data") |> Enum.map(& &1["form"])

    assert forms == ["data/orders", "data/tickets"]
    assert rendered_forms == forms
  end

  test "a mission evaluation resolves grants, rejects misses, and does not render called values" do
    {:ok, mission} =
      MissionEnvironment.new(data: %{"tickets" => [%{"id" => @sentinel}], "orders" => []})

    {:ok, state} = RunState.start(Limits.defaults())

    assert %{outcome: :continued, value: [%{"id" => @sentinel}]} =
             Evaluation.evaluate_source(state, "default", mission, "data/tickets", 1_000)

    assert %{
             outcome: :evaluation_error,
             kind: :runtime_error,
             details: %{message: missing}
           } = Evaluation.evaluate_source(state, "default", mission, "data/nosuch", 1_000)

    assert missing =~ "data/nosuch is not a granted data name"
    assert missing =~ "data/orders"
    assert missing =~ "data/tickets"
    refute missing =~ @sentinel

    assert %{
             outcome: :evaluation_error,
             kind: :not_callable,
             details: %{message: not_callable}
           } = Evaluation.evaluate_source(state, "default", mission, "(data/tickets)", 1_000)

    assert not_callable =~ "not callable: data/tickets"
    refute not_callable =~ @sentinel
  end

  test "kernel/eval-source without params fails data/params distinctly" do
    assert {:ok, kernel_component} = Library.component("kernel")
    assert {:ok, bundle} = Kernel.compile_bundle([kernel_component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new(data: %{"tickets" => [1]})
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "mission-data-params")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => mission},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: value}} =
             Kernel.run(
               ~S|(return (kernel/eval-source "default" "(get data/params \"id\")"))|,
               config
             )

    assert value["outcome"] == "evaluation_error"
    assert value["kind"] == "runtime_error"
    message = get_in(value, ["details", "message"])
    assert message =~ "supplied no params"
    assert message =~ "kernel/eval-with"
    assert message =~ "kernel/eval-source-with"
    refute message =~ "granted"
    refute message =~ "data/tickets"
  end
end
