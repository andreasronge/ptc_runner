defmodule PtcRunner.Kernel.RunAnalysisTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.RunAnalysis
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @tag :tmp_dir
  test "answers the six run questions without exposing record-family queries", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)

    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, %{"items" => [%{"run_id" => run_id}], "complete?" => true}} =
             RunAnalysis.query(analysis, :runs, %{})

    assert run_id == fixture.run_id

    assert {:ok,
            %{
              "run" => %{"run_id" => ^run_id, "complete" => true},
              "inspection" => %{"counts" => counts},
              "result" => %{"available?" => false}
            }} = RunAnalysis.query(analysis, :overview, %{"run_id" => run_id})

    assert counts["capability_calls"] == 1
    assert counts["provider_exchanges"] == 1

    capability_id = "tool-#{run_id}"

    assert {:ok,
            %{
              "trace" => %{"items" => [_ | _]},
              "private" => %{
                "capability_calls" => [%{"capability_id" => ^capability_id}],
                "provider_exchanges" => [
                  %{
                    "capability_id" => ^capability_id,
                    "request_id" => 7,
                    "request" => %{"method" => "tools/call"}
                  }
                ],
                "execution_errors" => [%{"kind" => "limit_exceeded"}]
              }
            }} = RunAnalysis.query(analysis, :activity, %{"run_id" => run_id})

    assert {:ok,
            %{
              "complete?" => true,
              "streams" => [
                %{
                  "turns" => [
                    %{
                      "generated" => [%{"source" => "(return 42)"}],
                      "feedback" => [],
                      "messages_added" => [%{"content" => prompt}],
                      "response" => %{"status" => "ok"}
                    }
                  ]
                }
              ]
            }} = RunAnalysis.query(analysis, :conversation, %{"run_id" => run_id})

    assert prompt == "private-prompt-#{run_id}"
    expected_workflow_evaluation_id = "workflow-eval-#{run_id}"

    assert {:ok,
            %{
              "run" => %{"run_id" => ^run_id},
              "diagnostics" => [%{"evaluation_id" => evaluation_id}],
              "programs" => [
                %{
                  "relationship" => "same_workflow_evaluation",
                  "workflow_evaluation_id" => ^expected_workflow_evaluation_id
                }
              ]
            }} = RunAnalysis.query(analysis, :failure, %{"run_id" => run_id})

    assert evaluation_id == "workflow-eval-#{run_id}"

    assert {:ok,
            %{
              "effective_preludes" => [%{"source_hash" => "sha256:" <> _}],
              "generated_programs" => [%{"source_hash" => "sha256:" <> _}]
            }} = RunAnalysis.query(analysis, :source, %{"run_id" => run_id})
  end

  test "conversation streams choose the unique longest complete prefix" do
    user = %{"role" => "user", "content" => "start"}
    assistant_1 = %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "1"}]}
    feedback_1 = %{"role" => "tool", "tool_call_id" => "1", "content" => "first"}
    assistant_2 = %{"role" => "assistant", "content" => nil, "tool_calls" => [%{"id" => "2"}]}
    feedback_2 = %{"role" => "tool", "tool_call_id" => "2", "content" => "second"}

    exchanges = [
      exchange(1, [user], assistant_1),
      exchange(3, [user, assistant_1, feedback_1], assistant_2),
      exchange(5, [user, assistant_1, feedback_1, assistant_2, feedback_2], %{
        "role" => "assistant",
        "content" => "done"
      })
    ]

    assert %{"ambiguous?" => false, "streams" => [%{"turns" => turns}]} =
             RunAnalysis.conversation_streams(exchanges)

    assert Enum.map(turns, & &1["turn"]) == [1, 2, 3]
    assert Enum.at(turns, 1)["messages_added"] == [feedback_1]
    assert Enum.at(turns, 1)["feedback"] == [feedback_1]
    assert Enum.at(turns, 2)["messages_added"] == [feedback_2]
    assert Enum.at(turns, 2)["feedback"] == [feedback_2]
  end

  test "conversation streams preserve equal maximal forks as ambiguous" do
    user = %{"role" => "user", "content" => "same"}
    assistant = %{"role" => "assistant", "content" => "same answer"}

    exchanges = [
      exchange(1, [user], assistant, "a"),
      exchange(3, [user], assistant, "b"),
      exchange(5, [user, assistant, %{"role" => "user", "content" => "next"}], assistant, "c")
    ]

    assert %{"ambiguous?" => true, "ambiguous" => [%{"capability_id" => "c"}]} =
             RunAnalysis.conversation_streams(exchanges)
  end

  @tag :tmp_dir
  test "rejects an inspection snapshot captured against another trace snapshot", %{tmp_dir: root} do
    left = PrivateInspectionFixture.create!(Path.join(root, "left"), "left")
    right = PrivateInspectionFixture.create!(Path.join(root, "right"), "right")
    {:ok, left_trace} = TraceSnapshot.start({:private_authorized_directory, left.traces})
    {:ok, right_trace} = TraceSnapshot.start({:private_authorized_directory, right.traces})

    {:ok, right_inspection} =
      InspectionSnapshot.start({:directory, right.inspection}, right_trace)

    on_exit(fn -> InspectionSnapshot.stop(right_inspection) end)
    on_exit(fn -> TraceSnapshot.stop(right_trace) end)
    on_exit(fn -> TraceSnapshot.stop(left_trace) end)

    assert {:error, :invalid_run_analysis} = RunAnalysis.new(left_trace, right_inspection)
  end

  @tag :tmp_dir
  test "keeps canonical answers available when a private catalog has no artifact for the run", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root, "with-inspection")
    trace_only = "trace-only"

    File.write!(
      Path.join(fixture.traces, "#{trace_only}.jsonl"),
      Enum.map_join(PrivateInspectionFixture.canonical_events(trace_only), "", fn event ->
        Jason.encode!(event) <> "\n"
      end)
    )

    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok,
            %{
              "run" => %{"run_id" => ^trace_only},
              "inspection" => %{"available?" => false},
              "result" => %{"available?" => false}
            }} = RunAnalysis.query(analysis, :overview, %{"run_id" => trace_only})

    assert {:ok, %{"trace" => %{"items" => [_ | _]}, "private" => %{"available?" => false}}} =
             RunAnalysis.query(analysis, :activity, %{"run_id" => trace_only})

    assert {:ok, %{"run" => %{"run_id" => ^trace_only}, "private_evidence" => false}} =
             RunAnalysis.query(analysis, :failure, %{"run_id" => trace_only})

    assert {:error, :evidence_unavailable} =
             RunAnalysis.query(analysis, :conversation, %{"run_id" => trace_only})
  end

  @tag :tmp_dir
  test "semantic reads follow primitive cursors internally", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok,
            %{
              "complete?" => true,
              "trace" => %{"complete?" => true, "items" => events, "next_cursor" => nil}
            }} =
             RunAnalysis.query(analysis, :activity, %{"run_id" => fixture.run_id, "limit" => 1})

    assert length(events) > 1
  end

  @tag :tmp_dir
  test "enforces the result ceiling after composing semantic collections", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, sizing_trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})

    {:ok, sizing_inspection} =
      InspectionSnapshot.start({:directory, fixture.inspection}, sizing_trace)

    {:ok, exchanges} =
      InspectionSnapshot.query(sizing_inspection, :model_exchanges, %{
        "run_id" => fixture.run_id,
        "limit" => 1_000
      })

    {:ok, programs} =
      InspectionSnapshot.query(sizing_inspection, :generated_sources, %{
        "run_id" => fixture.run_id,
        "limit" => 1_000
      })

    ceiling = max(byte_size(Jason.encode!(exchanges)), byte_size(Jason.encode!(programs))) + 32
    :ok = InspectionSnapshot.stop(sizing_inspection)
    :ok = TraceSnapshot.stop(sizing_trace)

    {:ok, trace} =
      TraceSnapshot.start({:private_authorized_directory, fixture.traces},
        max_result_bytes: ceiling
      )

    {:ok, inspection} =
      InspectionSnapshot.start({:directory, fixture.inspection}, trace, max_result_bytes: ceiling)

    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, _page} =
             InspectionSnapshot.query(inspection, :model_exchanges, %{
               "run_id" => fixture.run_id,
               "limit" => 1_000
             })

    assert {:ok, _page} =
             InspectionSnapshot.query(inspection, :generated_sources, %{
               "run_id" => fixture.run_id,
               "limit" => 1_000
             })

    assert {:error, :result_limit_exceeded} =
             RunAnalysis.query(analysis, :conversation, %{
               "run_id" => fixture.run_id,
               "limit" => 1_000
             })
  end

  @tag :tmp_dir
  test "one capability builder exposes only the six semantic operations", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)

    assert {:ok, capabilities} = RunAnalysisCapability.from_snapshots(trace, inspection)

    assert Enum.map(capabilities, & &1.name) == [
             "analysis-runs",
             "analysis-overview",
             "analysis-activity",
             "analysis-conversation",
             "analysis-failure",
             "analysis-source"
           ]

    conversation = Enum.find(capabilities, &(&1.name == "analysis-conversation"))

    assert {:ok, %{"streams" => [%{"turns" => [_]}]}} =
             conversation.callback.(%{"run_id" => fixture.run_id})

    assert {:ok, provider_capabilities} =
             RunAnalysisCapability.from_snapshots(trace, inspection, "evidence")

    assert Enum.map(provider_capabilities, & &1.name) == [
             "evidence.runs",
             "evidence.overview",
             "evidence.activity",
             "evidence.conversation",
             "evidence.failure",
             "evidence.source"
           ]
  end

  defp exchange(sequence, messages, assistant, id \\ nil) do
    %{
      "capability_id" => id || "cap-#{sequence}",
      "input_sequence" => sequence,
      "output_sequence" => sequence + 1,
      "arguments" => %{"messages" => messages, "system" => "system"},
      "result" => %{"status" => "ok", "value" => Map.delete(assistant, "role")}
    }
  end
end
