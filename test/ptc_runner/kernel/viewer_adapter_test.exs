defmodule PtcRunner.Kernel.ViewerAdapterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.ViewerAdapter

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
      "schema_version" => 1,
      "run_id" => "viewer-run",
      "trace_id" => "viewer-trace",
      "sequence" => sequence,
      "timestamp" => "2026-07-12T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
