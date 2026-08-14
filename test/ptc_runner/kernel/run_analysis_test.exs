defmodule PtcRunner.Kernel.RunAnalysisTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ConversationProjection
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.RunAnalysis
  alias PtcRunner.Kernel.RunAnalysisCapability
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @tag :tmp_dir
  test "run listing delegates the bounded native page", %{tmp_dir: root} do
    File.write!(Path.join(root, "empty.jsonl"), "")

    {:ok, trace} =
      TraceSnapshot.start({:directory, root},
        max_result_bytes: HostConfig.minimum_snapshot_result_bytes()
      )

    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace)

    assert {:ok, %{"items" => [], "snapshot_hash" => "sha256:" <> _}} =
             RunAnalysis.query(analysis, :runs, %{})
  end

  @tag :tmp_dir
  test "opens a run and reads its advertised primitive collections", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)

    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, %{"items" => [%{"run_id" => run_id}]}} =
             RunAnalysis.query(analysis, :runs, %{})

    assert run_id == fixture.run_id

    assert {:ok,
            %{
              "run" => %{"run_id" => ^run_id, "complete" => true},
              "inspection" => %{"counts" => counts},
              "result" => %{"available?" => false},
              "collections" => collections
            }} = RunAnalysis.query(analysis, :open, %{"run_id" => run_id})

    assert counts["capability_calls"] == 1
    assert counts["provider_exchanges"] == 1
    assert Enum.find(collections, &(&1["name"] == "activity"))["available?"]
    assert Enum.find(collections, &(&1["name"] == "turns"))["available?"]

    capability_id = "tool-#{run_id}"

    assert {:ok, %{"items" => [_ | _]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "activity"
             })

    assert {:ok,
            %{
              "evidence" => %{"complete?" => true},
              "items" => [
                %{
                  "generated" => [%{"source" => "(return 42)"}],
                  "feedback" => [],
                  "messages_added" => [%{"content" => prompt}],
                  "response" => %{"status" => "ok"}
                } = turn
              ]
            }} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "turns"
             })

    assert prompt == "private-prompt-#{run_id}"
    refute Map.has_key?(turn, "system")

    assert {:ok, %{"items" => [%{"arguments" => %{"system" => "private-system-" <> ^run_id}}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "model_exchanges"
             })

    assert {:ok, %{"items" => [%{"capability_id" => ^capability_id}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "capability_calls"
             })

    assert {:ok, %{"items" => [%{"request_id" => 7, "request" => %{"method" => "tools/call"}}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "provider_exchanges"
             })

    assert {:ok, %{"items" => [%{"kind" => "limit_exceeded"}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "execution_errors"
             })

    assert {:ok, %{"items" => [%{"source_hash" => "sha256:" <> _}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "prelude_sources"
             })

    assert {:ok, %{"items" => [%{"source_hash" => "sha256:" <> _}]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "generated_sources"
             })

    assert {:error, :invalid_query} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => run_id,
               "collection" => "activity",
               "limit" => 101
             })
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
             ConversationProjection.streams(exchanges)

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
             ConversationProjection.streams(exchanges)
  end

  test "turn projection labels duplicate source matches without inventing an exact edge" do
    assistant = %{
      "role" => "assistant",
      "tool_calls" => [%{"args" => %{"program" => "(return 42)"}}]
    }

    programs = [
      %{"evaluation_id" => "evaluation-1", "source" => "(return 42)"},
      %{"evaluation_id" => "evaluation-2", "source" => "(return 42)"}
    ]

    projection =
      ConversationProjection.compile(
        [exchange(1, [%{"role" => "user", "content" => "run it"}], assistant)],
        programs,
        %{"terminal?" => true, "events_dropped?" => false}
      )

    assert [turn] = projection.items
    assert Enum.map(turn["generated"], & &1["association"]) == ["source_match", "source_match"]
    assert Enum.all?(turn["generated"], & &1["association_ambiguous?"])
    refute projection.evidence["complete?"]
    assert projection.evidence["ambiguity_count"] == 1
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
              "result" => %{"available?" => false},
              "collections" => collections
            }} = RunAnalysis.query(analysis, :open, %{"run_id" => trace_only})

    assert Enum.find(collections, &(&1["name"] == "activity"))["available?"]
    refute Enum.find(collections, &(&1["name"] == "turns"))["available?"]

    assert {:ok, %{"items" => [_ | _]}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => trace_only,
               "collection" => "activity"
             })

    assert {:error, :evidence_unavailable} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => trace_only,
               "collection" => "turns"
             })

    assert {:error, :not_found} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => "unknown",
               "collection" => "turns"
             })

    assert {:error, :not_found} =
             RunAnalysis.query(analysis, :open, %{"run_id" => "unknown"})
  end

  @tag :tmp_dir
  test "conversation completeness reconciles private exchanges with canonical evidence", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root, "missing-exchange")
    remove_capability_records!(fixture.inspection, "llm-#{fixture.run_id}")
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok,
            %{
              "evidence" => %{
                "canonical_complete?" => true,
                "complete?" => false,
                "missing_exchange_count" => 1
              },
              "items" => []
            }} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "turns"
             })
  end

  @tag :tmp_dir
  test "conversation completeness requires a canonical terminal event", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root, "open-run")
    trace_path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")

    trace_path
    |> File.stream!()
    |> Enum.reject(fn line -> line |> Jason.decode!() |> Map.fetch!("type") == "run-stopped" end)
    |> then(&File.write!(trace_path, &1))

    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, %{"evidence" => %{"canonical_complete?" => false, "complete?" => false}}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "turns"
             })
  end

  @tag :tmp_dir
  test "read returns primitive cursors for the caller to follow", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok,
            %{
              "items" => [_event],
              "next_cursor" => cursor,
              "truncated" => true
            }} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "activity",
               "limit" => 1
             })

    assert {:ok, %{"items" => [_event], "snapshot_hash" => snapshot_hash}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "activity",
               "limit" => 1,
               "cursor" => cursor
             })

    assert is_binary(snapshot_hash)
  end

  @tag :tmp_dir
  test "internal collection rejects a multi-page aggregate above the result-byte limit", %{
    tmp_dir: root
  } do
    fixture = PrivateInspectionFixture.create!(root)
    max_result_bytes = 1_500

    {:ok, trace} =
      TraceSnapshot.start({:private_authorized_directory, fixture.traces},
        max_result_bytes: max_result_bytes
      )

    on_exit(fn -> TraceSnapshot.stop(trace) end)
    assert {:ok, analysis} = RunAnalysis.new(trace)

    assert {:ok, %{"next_cursor" => cursor}} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "activity",
               "limit" => 100
             })

    assert is_binary(cursor)

    assert {:error, :result_limit_exceeded} =
             RunAnalysis.collect(analysis, fixture.run_id, "activity", 100)
  end

  @tag :tmp_dir
  test "read does not compose independently bounded private collections", %{tmp_dir: root} do
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

    assert {:ok, analysis} = RunAnalysis.new(sizing_trace, sizing_inspection)

    assert {:ok, ^exchanges} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "model_exchanges",
               "limit" => 100
             })

    assert {:ok, ^programs} =
             RunAnalysis.query(analysis, :read, %{
               "run_id" => fixture.run_id,
               "collection" => "generated_sources",
               "limit" => 100
             })

    :ok = InspectionSnapshot.stop(sizing_inspection)
    :ok = TraceSnapshot.stop(sizing_trace)
  end

  @tag :tmp_dir
  test "one capability builder exposes only runs, open, and read", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)

    assert {:ok, capabilities} = RunAnalysisCapability.from_snapshots(trace, inspection)

    assert Enum.map(capabilities, & &1.name) == [
             "analysis-runs",
             "analysis-open",
             "analysis-read"
           ]

    read = Enum.find(capabilities, &(&1.name == "analysis-read"))
    assert read.input_schema["properties"]["limit"]["maximum"] == 100

    assert {:ok, %{"items" => [_]}} =
             read.callback.(%{"run_id" => fixture.run_id, "collection" => "turns"})

    assert {:ok, provider_capabilities} =
             RunAnalysisCapability.from_snapshots(trace, inspection, "evidence")

    assert Enum.map(provider_capabilities, & &1.name) == [
             "evidence.runs",
             "evidence.open",
             "evidence.read"
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

  defp remove_capability_records!(directory, capability_id) do
    [path] = Path.wildcard(Path.join(directory, "*.inspection.jsonl"))

    retained =
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.reject(fn record ->
        get_in(record, ["correlation", "capability_id"]) == capability_id
      end)
      |> Enum.with_index(1)
      |> Enum.map_join(fn {record, sequence} ->
        record |> Map.put("sequence", sequence) |> Jason.encode!() |> Kernel.<>("\n")
      end)

    File.write!(path, retained)
  end
end
