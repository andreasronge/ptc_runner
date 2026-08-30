defmodule PtcRunner.Kernel.NamedMissionsDiagnosisTest do
  @moduledoc """
  can a user diagnose a broken agent loop from the shipped tools alone?

  The failure reproduced here is the exact one the live e2e hit: the model
  replies in prose instead of calling the tool. No credentials — the provider
  is a stub requester that always answers in prose.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment

  @shipped """
  (ns spike.shipped "agent.core against one named space.")

  (defn run [_input]
    (return (agent.core/run-value "anything" {"max_turns" 3 "mission" "work"})))
  """

  # The loop the earlier e2e used: no annotation, protocol error is fatal.
  @handrolled """
  (ns spike.handrolled "A hand-rolled loop that annotates nothing.")

  (defn run [_input]
    (loop [turn 0]
      (if (>= turn 3)
        (fail {:kind :turn-limit})
        (let [response (llm/request {"system" "s"
                                     "messages" [{"role" "user" "content" "anything"}]
                                     "tools" [(agent.native/tool-schema)]})
              action (agent.native/normalize response 64000)]
          (if (not= :tool-call (get action :kind))
            (fail {:kind :protocol-error})
            (return :unreachable))))))
  """

  defp prose_capability do
    {:ok, capability} =
      LLMCapability.new(
        requester: fn _request ->
          {:ok, %{"content" => "Sure! I would read the record and report it back to you."}}
        end
      )

    capability
  end

  defp run_loop(source, id, libraries, deps) do
    {:ok, component} = Component.new(id: id, source: source, dependencies: deps)
    {:ok, components} = Library.resolve_components([component | libraries])
    {:ok, bundle} = Kernel.compile_bundle(components)

    {:ok, workflow} =
      WorkflowEnvironment.new(bundle: bundle, capabilities: [prose_capability()])

    {:ok, work} = MissionEnvironment.new([])
    {:ok, default_mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(subordinate_evaluations: 8, workflow_capability_calls: 32)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: id)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => default_mission, "work" => work},
        input: %{"input" => %{}},
        limits: limits,
        event_sink: sink
      )

    outcome = Kernel.run("(#{id}/run data/input)", config)
    {outcome, sink}
  end

  defp annotations(sink) do
    sink
    |> EventSink.events()
    |> Enum.filter(&(&1.type == "workflow-annotation"))
    |> Enum.map(& &1.data)
  end

  test "agent.core leaves a diagnosable trail when the model answers in prose" do
    {outcome, sink} =
      run_loop(@shipped, "spike.shipped", [{:library, "agent.core"}], ["agent.core"])

    assert {:error, error} = outcome

    # The public error alone says only that the subject failed.
    assert error.kind == :workflow_failed

    # The canonical trace says what actually went wrong, on every turn.
    kinds = Enum.map(annotations(sink), & &1.data["kind"])
    assert kinds != []
    assert Enum.all?(kinds, &(&1 == "protocol-error"))

    turns = Enum.map(annotations(sink), & &1.data["turn"])
    assert turns == Enum.sort(turns)
    assert length(turns) >= 2, "the loop retried, so the trail shows the retries"
  end

  test "a hand-rolled loop that skips annotation leaves the trace silent" do
    {outcome, sink} =
      run_loop(
        @handrolled,
        "spike.handrolled",
        [{:library, "llm"}, {:library, "agent.native"}],
        ["agent.native", "llm"]
      )

    assert {:error, _error} = outcome

    # Same failure, no trail at all. This is the gap: not a missing tool, but a
    # loop that never called the annotation route the shipped loop calls.
    assert annotations(sink) == []
  end

  test "counters separate a protocol failure from an evaluation failure" do
    {_outcome, sink} =
      run_loop(@shipped, "spike.shipped", [{:library, "agent.core"}], ["agent.core"])

    events =
      sink
      |> EventSink.events()
      |> Enum.map(&normalize_event/1)

    assert {:ok, counters} =
             TraceLog.query_loaded(events, "diag", :counters, %{}, 1_000_000, :sanitized)

    # The model was called repeatedly but nothing ever reached a mission:
    # that pair is the signature of a protocol-level loop bug.
    assert counters["workflow_capability_calls"] >= 2
    assert counters["evaluations_by_mission"] == %{}

    # "evaluations" counts the workflow's own evaluation too, so it is 1 even
    # though no mission program ever ran. evaluations_by_mission is the
    # mission-only figure; the two are easy to confuse when reading a trace.
    assert counters["evaluations"] == 1
  end

  # ex_dna:disable-for-next-line — mirrors canonical trace normalization in continuation coverage
  defp normalize_event(event) do
    Map.new(event, fn
      {:data, data} -> {"data", Map.new(data, fn {k, v} -> {to_string(k), v} end)}
      {:timestamp, %DateTime{} = at} -> {"timestamp", DateTime.to_iso8601(at)}
      {key, value} -> {to_string(key), value}
    end)
  end
end
