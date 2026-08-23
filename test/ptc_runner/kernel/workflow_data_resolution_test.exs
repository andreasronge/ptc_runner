defmodule PtcRunner.Kernel.WorkflowDataResolutionTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp

  @sentinel "SECRET_INPUT_SENTINEL"

  test "a workflow entry resolves granted input, rejects misses, and does not render called values" do
    input = %{"tickets" => [%{"id" => @sentinel}], "orders" => []}

    assert {:ok, %{value: [%{"id" => @sentinel}]}} = run_entry("(return data/tickets)", input)

    assert {:error,
            %{kind: :workflow_failed, reason: :runtime_error, details: %{message: missing}}} =
             run_entry("(return data/nosuch)", input)

    assert missing =~ "data/nosuch is not a granted data name"
    assert missing =~ "data/orders"
    assert missing =~ "data/tickets"
    refute missing =~ @sentinel

    assert {:error, %{kind: :evaluation_failed, reason: :not_callable, details: details}} =
             run_entry("(return (data/tickets))", input)

    assert details[:name] == "data/tickets"
    refute inspect(details) =~ @sentinel
  end

  test "a workflow entry names no params entry point in its missing-grant diagnostic" do
    assert {:error, %{details: %{message: message}}} =
             run_entry("(return data/params)", %{"tickets" => []})

    assert message =~ "data/params is not a granted data name"
    refute message =~ "kernel/eval-with"
    refute message =~ "supplied no params"
  end

  test "the generic embedding API stays permissive" do
    assert {:ok, %{return: nil}} = Lisp.run("data/missing")
  end

  defp run_entry(source, input) do
    {:ok, workflow} = WorkflowEnvironment.new(bundle: nil)
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "workflow-data-resolution")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{},
        input: input,
        limits: limits,
        event_sink: sink
      )

    Kernel.run(source, config)
  end
end
