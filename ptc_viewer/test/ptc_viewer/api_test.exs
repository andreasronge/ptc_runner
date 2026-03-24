defmodule PtcViewer.ApiTest do
  use ExUnit.Case, async: false

  setup do
    trace_dir = Path.join(System.tmp_dir!(), "ptc_api_test_traces_#{:rand.uniform(100_000)}")

    File.mkdir_p!(trace_dir)

    File.write!(Path.join(trace_dir, "a.jsonl"), "line1\nline2\n")
    File.write!(Path.join(trace_dir, "b.jsonl"), "line3\n")
    File.write!(Path.join(trace_dir, "not_a_trace.txt"), "ignored")

    Application.put_env(:ptc_viewer, :trace_dir, trace_dir)

    on_exit(fn ->
      File.rm_rf!(trace_dir)
    end)

    %{trace_dir: trace_dir}
  end

  test "list_traces returns only .jsonl files" do
    traces = PtcViewer.Api.list_traces()
    filenames = Enum.map(traces, & &1.filename) |> Enum.sort()
    assert filenames == ["a.jsonl", "b.jsonl"]
  end

  test "list_traces returns empty list for missing directory" do
    Application.put_env(:ptc_viewer, :trace_dir, "/nonexistent/path")
    assert PtcViewer.Api.list_traces() == []
  end

  test "get_trace returns file content" do
    assert {:ok, content} = PtcViewer.Api.get_trace("a.jsonl")
    assert content == "line1\nline2\n"
  end

  test "get_trace returns error for missing file" do
    assert {:error, :not_found} = PtcViewer.Api.get_trace("missing.jsonl")
  end

  test "get_trace prevents path traversal" do
    assert {:error, :not_found} = PtcViewer.Api.get_trace("../../etc/passwd")
  end
end
