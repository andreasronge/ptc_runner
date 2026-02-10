defmodule PtcViewer.ApiTest do
  use ExUnit.Case, async: false

  setup do
    trace_dir = Path.join(System.tmp_dir!(), "ptc_api_test_traces_#{:rand.uniform(100_000)}")
    plan_dir = Path.join(System.tmp_dir!(), "ptc_api_test_plans_#{:rand.uniform(100_000)}")

    File.mkdir_p!(trace_dir)
    File.mkdir_p!(plan_dir)

    File.write!(Path.join(trace_dir, "a.jsonl"), "line1\nline2\n")
    File.write!(Path.join(trace_dir, "b.jsonl"), "line3\n")
    File.write!(Path.join(trace_dir, "not_a_trace.txt"), "ignored")
    File.write!(Path.join(plan_dir, "plan.json"), ~s|{"steps":[]}|)

    Application.put_env(:ptc_viewer, :trace_dir, trace_dir)
    Application.put_env(:ptc_viewer, :plan_dir, plan_dir)

    on_exit(fn ->
      File.rm_rf!(trace_dir)
      File.rm_rf!(plan_dir)
    end)

    %{trace_dir: trace_dir, plan_dir: plan_dir}
  end

  test "list_traces returns only .jsonl files, sorted" do
    traces = PtcViewer.Api.list_traces()
    filenames = Enum.map(traces, & &1.filename)
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

  test "list_plans returns only .json files" do
    plans = PtcViewer.Api.list_plans()
    assert length(plans) == 1
    assert hd(plans).filename == "plan.json"
  end

  test "get_plan returns file content" do
    assert {:ok, content} = PtcViewer.Api.get_plan("plan.json")
    assert content == ~s|{"steps":[]}|
  end

  test "get_plan returns error for missing file" do
    assert {:error, :not_found} = PtcViewer.Api.get_plan("missing.json")
  end
end
