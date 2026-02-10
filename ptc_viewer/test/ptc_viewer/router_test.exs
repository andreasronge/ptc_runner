defmodule PtcViewer.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :router

  setup do
    trace_dir = Path.join(System.tmp_dir!(), "ptc_viewer_test_traces_#{:rand.uniform(100_000)}")
    plan_dir = Path.join(System.tmp_dir!(), "ptc_viewer_test_plans_#{:rand.uniform(100_000)}")

    File.mkdir_p!(trace_dir)
    File.mkdir_p!(plan_dir)

    # Create fixture files
    File.write!(Path.join(trace_dir, "trace1.jsonl"), ~s|{"event":"start"}\n{"event":"end"}\n|)
    File.write!(Path.join(trace_dir, "trace2.jsonl"), ~s|{"event":"solo"}\n|)
    File.write!(Path.join(plan_dir, "plan1.json"), ~s|{"goal":"test"}|)

    Application.put_env(:ptc_viewer, :trace_dir, trace_dir)
    Application.put_env(:ptc_viewer, :plan_dir, plan_dir)

    on_exit(fn ->
      File.rm_rf!(trace_dir)
      File.rm_rf!(plan_dir)
    end)

    %{trace_dir: trace_dir, plan_dir: plan_dir}
  end

  test "GET /api/traces returns list of .jsonl files" do
    conn = conn(:get, "/api/traces") |> PtcViewer.Router.call(PtcViewer.Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

    body = Jason.decode!(conn.resp_body)
    assert length(body) == 2

    filenames = Enum.map(body, & &1["filename"])
    assert "trace1.jsonl" in filenames
    assert "trace2.jsonl" in filenames

    first = Enum.find(body, &(&1["filename"] == "trace1.jsonl"))
    assert first["size"] > 0
    assert first["modified"]
  end

  test "GET /api/traces/:filename returns file content" do
    conn =
      conn(:get, "/api/traces/trace1.jsonl") |> PtcViewer.Router.call(PtcViewer.Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/x-ndjson"
    assert conn.resp_body =~ ~s|{"event":"start"}|
  end

  test "GET /api/traces/:filename returns 404 for missing file" do
    conn =
      conn(:get, "/api/traces/missing.jsonl") |> PtcViewer.Router.call(PtcViewer.Router.init([]))

    assert conn.status == 404
  end

  test "GET /api/traces with path traversal returns 404" do
    conn =
      conn(:get, "/api/traces/..%2F..%2Fetc%2Fpasswd")
      |> PtcViewer.Router.call(PtcViewer.Router.init([]))

    assert conn.status == 404
  end

  test "GET /api/plans returns list of .json files" do
    conn = conn(:get, "/api/plans") |> PtcViewer.Router.call(PtcViewer.Router.init([]))

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert length(body) == 1
    assert hd(body)["filename"] == "plan1.json"
  end

  test "GET /api/plans/:filename returns file content" do
    conn = conn(:get, "/api/plans/plan1.json") |> PtcViewer.Router.call(PtcViewer.Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    assert conn.resp_body == ~s|{"goal":"test"}|
  end
end
