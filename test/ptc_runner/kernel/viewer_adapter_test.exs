defmodule PtcRunner.Kernel.ViewerAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.ConversationProjection
  alias PtcRunner.Kernel.InspectionSnapshot
  alias PtcRunner.Kernel.ProjectViewerAdapter
  alias PtcRunner.Kernel.RunAnalysis
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.TraceSnapshot
  alias PtcRunner.Kernel.ViewerAdapter
  alias PtcRunner.TestSupport.PrivateInspectionFixture

  @tag :tmp_dir
  test "viewer conversation preserves the canonical analysis snapshot identity", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root)
    {:ok, trace} = TraceSnapshot.start({:private_authorized_directory, fixture.traces})
    {:ok, inspection} = InspectionSnapshot.start({:directory, fixture.inspection}, trace)
    on_exit(fn -> InspectionSnapshot.stop(inspection) end)
    on_exit(fn -> TraceSnapshot.stop(trace) end)

    assert {:ok, analysis} = RunAnalysis.new(trace, inspection)

    assert {:ok, page} = RunAnalysis.collect(analysis, fixture.run_id, "turns", 1_000)
    expected = ConversationProjection.present_page(page)

    assert {:ok, expected_preludes} =
             InspectionSnapshot.query(inspection, :effective_preludes, %{
               "run_id" => fixture.run_id,
               "limit" => 1_000
             })

    inspection_path =
      fixture.inspection
      |> Path.join("*.inspection.jsonl")
      |> Path.wildcard()
      |> List.first()

    assert {:ok, grant} =
             ViewerAdapter.pin_inspection(inspection_path, {:directory, fixture.traces})

    assert {:ok, actual} = ViewerAdapter.conversation(grant, fixture.run_id)
    assert actual == expected
    assert {:ok, ^expected_preludes} = ViewerAdapter.preludes(grant, fixture.run_id)
    assert {:error, :inspection_run_mismatch} = ViewerAdapter.preludes(grant, "another-run")

    assert {:ok, expected_errors} =
             InspectionSnapshot.query(inspection, :execution_errors, %{
               "run_id" => fixture.run_id,
               "limit" => 1_000
             })

    assert {:ok, expected_failures} =
             InspectionSnapshot.query(inspection, :explicit_failure_values, %{
               "run_id" => fixture.run_id,
               "limit" => 1_000
             })

    assert {:ok, ^expected_errors} = ViewerAdapter.execution_errors(grant, fixture.run_id)

    assert {:ok, ^expected_failures} =
             ViewerAdapter.explicit_failure_values(grant, fixture.run_id)

    assert expected_failures["items"] != []

    project_source = {:inspection_snapshot, inspection}
    assert {:ok, ^expected} = ProjectViewerAdapter.conversation(project_source, fixture.run_id)

    assert {:ok, ^expected_preludes} =
             ProjectViewerAdapter.preludes(project_source, fixture.run_id)

    assert {:ok, ^expected_errors} =
             ProjectViewerAdapter.execution_errors(project_source, fixture.run_id)

    assert {:ok, ^expected_failures} =
             ProjectViewerAdapter.explicit_failure_values(project_source, fixture.run_id)
  end

  @tag :tmp_dir
  test "pinning an exact trace file cannot acquire authority from a sibling", %{tmp_dir: root} do
    inspected = PrivateInspectionFixture.create!(Path.join(root, "inspected"), "inspected-run")
    selected = PrivateInspectionFixture.create!(Path.join(root, "selected"), "selected-run")
    selected_trace = Path.join(selected.traces, "#{selected.run_id}.jsonl")
    sibling_trace = Path.join(selected.traces, "#{inspected.run_id}.jsonl")
    File.cp!(Path.join(inspected.traces, "#{inspected.run_id}.jsonl"), sibling_trace)

    inspection_path =
      inspected.inspection
      |> Path.join("*.inspection.jsonl")
      |> Path.wildcard()
      |> List.first()

    assert {:error, :inspection_correlation_missing} =
             ViewerAdapter.pin_inspection(inspection_path, {:file, selected_trace})
  end

  @tag :tmp_dir
  test "exact normal files retain TraceLog's extensionless admission", %{tmp_dir: root} do
    fixture = PrivateInspectionFixture.create!(root, "extensionless-run")
    jsonl_path = Path.join(fixture.traces, "#{fixture.run_id}.jsonl")
    extensionless_path = Path.join(fixture.traces, "canonical-trace")
    File.rename!(jsonl_path, extensionless_path)
    [inspection_path] = Path.wildcard(Path.join(fixture.inspection, "*.inspection.jsonl"))

    assert {:ok, _grant} =
             ViewerAdapter.pin_inspection(inspection_path, {:file, extensionless_path})
  end

  @tag :tmp_dir
  test "private directory pinning cannot acquire authority from a normal sibling", %{
    tmp_dir: root
  } do
    inspected = PrivateInspectionFixture.create!(Path.join(root, "inspected"), "normal-run")
    selected = PrivateInspectionFixture.create!(Path.join(root, "selected"), "private-run")
    selected_jsonl = Path.join(selected.traces, "#{selected.run_id}.jsonl")
    File.rename!(selected_jsonl, Path.join(selected.traces, "#{selected.run_id}.private.jsonl"))

    File.cp!(
      Path.join(inspected.traces, "#{inspected.run_id}.jsonl"),
      Path.join(selected.traces, "#{inspected.run_id}.jsonl")
    )

    [inspection_path] = Path.wildcard(Path.join(inspected.inspection, "*.inspection.jsonl"))

    assert {:error, :inspection_correlation_missing} =
             ViewerAdapter.pin_inspection(
               inspection_path,
               {:private_directory, selected.traces}
             )
  end

  @tag :tmp_dir
  test "viewer API and TraceLog return the same source-scoped projection", %{tmp_dir: directory} do
    path = Path.join(directory, "kernel.jsonl")

    connector = %{
      "provider" => "fixture-mcp",
      "protocol" => "mcp-2026-07-28",
      "transport" => "streamable_http",
      "server_info_hash" => nil,
      "snapshot_hash" => String.duplicate("a", 64),
      "tools" => []
    }

    mission = %{
      "prelude" => %{
        "component_ids" => ["reader"],
        "dependency_indices" => [[]],
        "hash" => String.duplicate("c", 64)
      },
      "inventory_hash" => String.duplicate("b", 64),
      "inventory_bytes" => 321,
      "model_context_hash" => String.duplicate("d", 64),
      "model_context_bytes" => 123
    }

    started = %{
      "missions" => %{"reader" => mission},
      "connector_snapshots" => [connector]
    }

    events = [event(1, "run-started", started), event(2, "run-stopped", %{"outcome" => "ok"})]
    assert :ok = TraceLog.append_jsonl(path, events)
    config = [trace_dir: directory, kernel_trace_adapter: ViewerAdapter]

    {:ok, trace_log} = TraceLog.new(source: {:directory, directory})
    assert {:ok, expected} = TraceLog.query(trace_log, :list_runs, %{"limit" => 1})
    assert {:ok, ^expected} = PtcViewer.Api.kernel_query(config, :list_runs, %{"limit" => 1})

    assert {:ok, run} = TraceLog.query(trace_log, :get_run, %{"run_id" => "viewer-run"})
    assert run["missions"] == %{"reader" => mission}
    assert run["connector_snapshots"] == [connector]
    assert {:ok, ^run} = PtcViewer.Api.kernel_query(config, :get_run, %{"run_id" => "viewer-run"})

    assert {:ok, turns} =
             TraceLog.query(trace_log, :list_turns, %{"run_id" => "viewer-run"})

    assert {:ok, ^turns} =
             PtcViewer.Api.kernel_query(config, :list_turns, %{"run_id" => "viewer-run"})

    assert {:ok, counters} = TraceLog.query(trace_log, :counters, %{"run_id" => "viewer-run"})

    assert {:ok, ^counters} =
             PtcViewer.Api.kernel_query(config, :counters, %{"run_id" => "viewer-run"})
  end

  defp event(sequence, type, data) do
    %{
      "schema_version" => 2,
      "run_id" => "viewer-run",
      "trace_id" => "viewer-trace",
      "sequence" => sequence,
      "timestamp" => "2026-07-12T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
