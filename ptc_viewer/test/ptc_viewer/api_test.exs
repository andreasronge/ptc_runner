defmodule PtcViewer.ApiTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: trace_dir}, do: %{trace_dir: trace_dir}

  test "kernel_query delegates the explicit directory source to the host adapter", %{
    trace_dir: trace_dir
  } do
    parent = self()

    adapter = fn source, operation, arguments ->
      send(parent, {:query, source, operation, arguments})
      {:ok, %{"items" => []}}
    end

    config = [trace_dir: trace_dir, kernel_trace_adapter: adapter]

    assert {:ok, %{"items" => []}} =
             PtcViewer.Api.kernel_query(config, :list_runs, %{"limit" => 1})

    assert_receive {:query, {:directory, ^trace_dir}, :list_runs, %{"limit" => 1}}
  end

  test "kernel_query contains malformed adapter returns", %{trace_dir: trace_dir} do
    config = [trace_dir: trace_dir, kernel_trace_adapter: fn _, _, _ -> :unexpected end]

    assert {:error, :adapter_failure} =
             PtcViewer.Api.kernel_query(config, :list_runs, %{})
  end

  test "conversation delegates only the exact configured file and run", %{trace_dir: trace_dir} do
    parent = self()
    source = {:pinned, "run.inspection.jsonl"}

    adapter = fn pinned_source, run_id ->
      send(parent, {:inspection, pinned_source, run_id})
      {:ok, %{"run_id" => run_id, "streams" => []}}
    end

    {:ok, store} = PtcViewer.InspectionStore.start(source)
    on_exit(fn -> if Process.alive?(store), do: PtcViewer.InspectionStore.stop(store) end)

    config = [
      trace_dir: trace_dir,
      kernel_trace_adapter: nil,
      inspection_store: store,
      inspection_adapter: adapter
    ]

    assert {:ok, %{"run_id" => "run-1", "streams" => []}} =
             PtcViewer.Api.conversation(config, "run-1")

    assert_receive {:inspection, ^source, "run-1"}
    assert {:error, :unavailable} = PtcViewer.Api.conversation([], "run-1")
  end

  test "start rejects an adapter that does not implement the query contract" do
    assert {:error, :invalid_kernel_trace_adapter} =
             PtcViewer.start(kernel_trace_adapter: String, open: false)
  end

  test "start requires a valid inspection adapter for a fixed file" do
    assert {:error, :invalid_inspection_config} =
             PtcViewer.start(inspection_file: "run.inspection.jsonl", open: false)

    assert {:error, :invalid_inspection_adapter} =
             PtcViewer.start(
               inspection_file: "run.inspection.jsonl",
               inspection_adapter: String,
               open: false
             )
  end

  test "legacy raw trace API is absent" do
    refute function_exported?(PtcViewer.Api, :list_traces, 1)
    refute function_exported?(PtcViewer.Api, :get_trace, 2)
  end
end
