defmodule PtcViewer.ApiTest do
  use ExUnit.Case, async: false

  setup do
    trace_dir = Path.join(System.tmp_dir!(), "ptc_api_test_traces_#{:rand.uniform(100_000)}")

    File.mkdir_p!(trace_dir)

    File.write!(Path.join(trace_dir, "a.jsonl"), "line1\nline2\n")
    File.write!(Path.join(trace_dir, "b.jsonl"), "line3\n")
    File.write!(Path.join(trace_dir, "secret.private.jsonl"), "private\n")
    File.write!(Path.join(trace_dir, "not_a_trace.txt"), "ignored")

    on_exit(fn ->
      File.rm_rf!(trace_dir)
    end)

    %{trace_dir: trace_dir}
  end

  test "list_traces returns only .jsonl files", %{trace_dir: trace_dir} do
    traces = PtcViewer.Api.list_traces(trace_dir)
    filenames = Enum.map(traces, & &1.filename) |> Enum.sort()
    assert filenames == ["a.jsonl", "b.jsonl"]
  end

  test "list_traces returns empty list for missing directory" do
    assert PtcViewer.Api.list_traces("/nonexistent/path") == []
  end

  test "get_trace returns file content", %{trace_dir: trace_dir} do
    assert {:ok, content} = PtcViewer.Api.get_trace("a.jsonl", trace_dir)
    assert content == "line1\nline2\n"
  end

  test "get_trace returns error for missing file", %{trace_dir: trace_dir} do
    assert {:error, :not_found} = PtcViewer.Api.get_trace("missing.jsonl", trace_dir)
  end

  test "get_trace prevents path traversal", %{trace_dir: trace_dir} do
    assert {:error, :not_found} = PtcViewer.Api.get_trace("../../etc/passwd", trace_dir)
  end

  test "raw routes do not disclose reserved private traces", %{trace_dir: trace_dir} do
    refute Enum.any?(
             PtcViewer.Api.list_traces(trace_dir),
             &(&1.filename == "secret.private.jsonl")
           )

    assert {:error, :not_found} =
             PtcViewer.Api.get_trace("secret.private.jsonl", trace_dir)
  end

  test "raw routes reject symbolic links", %{trace_dir: trace_dir} do
    link = Path.join(trace_dir, "linked.jsonl")
    File.ln_s!(Path.join(trace_dir, "a.jsonl"), link)

    refute Enum.any?(PtcViewer.Api.list_traces(trace_dir), &(&1.filename == "linked.jsonl"))
    assert {:error, :not_found} = PtcViewer.Api.get_trace("linked.jsonl", trace_dir)
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
end
