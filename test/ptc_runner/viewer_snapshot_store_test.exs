defmodule PtcRunner.ViewerSnapshotStoreTest do
  use ExUnit.Case, async: true

  alias PtcRunner.ViewerSnapshotStore

  @tag :tmp_dir
  test "a requested refresh atomically exposes a newly completed run", %{tmp_dir: directory} do
    path = Path.join(directory, "runs.jsonl")
    write_events(path, [event("first", 1, "run-started")])

    assert {:ok, store} =
             ViewerSnapshotStore.start({:directory, directory}, fn _trace, _deadline ->
               {:ok, nil}
             end)

    on_exit(fn -> ViewerSnapshotStore.stop(store) end)

    assert {:ok, %{"run_id" => "first"}} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => "first"})

    assert {:error, :not_found} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => "second"})

    write_events(path, [
      event("first", 1, "run-started"),
      event("second", 1, "run-started"),
      event("second", 2, "run-stopped")
    ])

    assert :ok = ViewerSnapshotStore.refresh(store, "second")

    assert {:ok, %{"run_id" => "second"}} =
             ViewerSnapshotStore.query(store, :get_run, %{"run_id" => "second"})
  end

  defp write_events(path, events) do
    File.write!(path, Enum.map_join(events, "", &(Jason.encode!(&1) <> "\n")))
  end

  defp event(run_id, sequence, type) do
    data = if type == "run-started", do: %{"missions" => %{}}, else: %{"outcome" => "ok"}

    %{
      "schema_version" => 2,
      "run_id" => run_id,
      "trace_id" => "trace-#{run_id}",
      "sequence" => sequence,
      "timestamp" => "2026-08-17T12:00:00Z",
      "type" => type,
      "data" => data
    }
  end
end
