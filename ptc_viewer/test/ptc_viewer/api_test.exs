defmodule PtcViewer.ApiTest do
  use ExUnit.Case, async: false

  setup do
    trace_dir = Path.join(System.tmp_dir!(), "ptc_api_test_traces_#{:rand.uniform(100_000)}")

    File.mkdir_p!(trace_dir)

    on_exit(fn ->
      File.rm_rf!(trace_dir)
    end)

    %{trace_dir: trace_dir}
  end

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

  test "start rejects an adapter that does not implement the query contract" do
    assert {:error, :invalid_kernel_trace_adapter} =
             PtcViewer.start(kernel_trace_adapter: String, open: false)
  end

  test "legacy raw trace API is absent" do
    refute function_exported?(PtcViewer.Api, :list_traces, 1)
    refute function_exported?(PtcViewer.Api, :get_trace, 2)
  end
end
