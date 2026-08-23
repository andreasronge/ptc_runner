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

  test "kernel_query delegates the explicitly selected private directory", %{trace_dir: trace_dir} do
    parent = self()

    adapter = fn source, operation, arguments ->
      send(parent, {:query, source, operation, arguments})
      {:ok, %{"items" => []}}
    end

    config = [
      trace_dir: trace_dir,
      private_traces: true,
      kernel_trace_adapter: adapter
    ]

    assert {:ok, %{"items" => []}} =
             PtcViewer.Api.kernel_query(config, :list_runs, %{})

    assert_receive {:query, {:private_directory, ^trace_dir}, :list_runs, %{}}
  end

  test "kernel_query preserves an opaque pre-pinned trace source", %{trace_dir: trace_dir} do
    parent = self()
    source = {:snapshot, make_ref()}

    adapter = fn actual_source, operation, arguments ->
      send(parent, {:query, actual_source, operation, arguments})
      {:ok, %{"items" => []}}
    end

    config = [trace_dir: trace_dir, trace_source: source, kernel_trace_adapter: adapter]

    assert {:ok, %{"items" => []}} =
             PtcViewer.Api.kernel_query(config, :list_runs, %{"limit" => 1})

    assert_receive {:query, ^source, :list_runs, %{"limit" => 1}}
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

    # No store and no adapter is a project that records no inspection artifact;
    # a store that cannot answer is evidence out of reach. Only the second is
    # worth retrying, so the two do not share a reason.
    assert {:error, :inspection_not_configured} = PtcViewer.Api.conversation([], "run-1")

    assert {:error, :inspection_not_configured} =
             PtcViewer.Api.conversation([inspection_store: store], "run-1")

    assert {:error, :inspection_not_configured} =
             PtcViewer.Api.conversation([inspection_adapter: adapter], "run-1")

    # A project that records inspection artifacts but withholds the private
    # grant reaches the same absent store by a different route. Reporting it as
    # "not configured" sends the reader to change the field they already set.
    assert {:error, :inspection_not_private} =
             PtcViewer.Api.conversation([inspection_absence: :not_private], "run-1")
  end

  test "preludes delegates the pinned inspection grant", %{trace_dir: trace_dir} do
    source = {:pinned, "run.inspection.jsonl"}
    {:ok, store} = PtcViewer.InspectionStore.start(source)
    on_exit(fn -> if Process.alive?(store), do: PtcViewer.InspectionStore.stop(store) end)

    config = [
      trace_dir: trace_dir,
      inspection_store: store,
      inspection_adapter: PtcViewer.PinningInspectionTestAdapter
    ]

    assert {:ok, %{"source" => actual_source, "run_id" => "run-1", "items" => []}} =
             PtcViewer.Api.preludes(config, "run-1")

    assert actual_source == inspect(source)
  end

  test "execution_errors and explicit_failure_values delegate the pinned grant", %{
    trace_dir: trace_dir
  } do
    source = {:pinned, "run.inspection.jsonl"}
    {:ok, store} = PtcViewer.InspectionStore.start(source)
    on_exit(fn -> if Process.alive?(store), do: PtcViewer.InspectionStore.stop(store) end)

    config = [
      trace_dir: trace_dir,
      inspection_store: store,
      inspection_adapter: PtcViewer.PinningInspectionTestAdapter
    ]

    assert {:ok, %{"source" => actual_errors, "run_id" => "run-1", "items" => []}} =
             PtcViewer.Api.execution_errors(config, "run-1")

    assert {:ok, %{"source" => actual_failures, "run_id" => "run-1", "items" => []}} =
             PtcViewer.Api.explicit_failure_values(config, "run-1")

    assert actual_errors == inspect(source)
    assert actual_failures == inspect(source)
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
