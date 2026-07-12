defmodule PtcViewer.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @moduletag :router

  setup do
    trace_dir = Path.join(System.tmp_dir!(), "ptc_viewer_test_traces_#{:rand.uniform(100_000)}")

    File.mkdir_p!(trace_dir)

    # Create fixture files
    File.write!(Path.join(trace_dir, "trace1.jsonl"), ~s|{"event":"start"}\n{"event":"end"}\n|)
    File.write!(Path.join(trace_dir, "trace2.jsonl"), ~s|{"event":"solo"}\n|)

    on_exit(fn ->
      File.rm_rf!(trace_dir)
    end)

    %{trace_dir: trace_dir, router_opts: [trace_dir: trace_dir, kernel_trace_adapter: nil]}
  end

  test "GET /api/traces returns list of .jsonl files", %{router_opts: router_opts} do
    conn = conn(:get, "/api/traces") |> call_router(router_opts)

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

  test "GET /api/traces/:filename returns file content", %{router_opts: router_opts} do
    conn = conn(:get, "/api/traces/trace1.jsonl") |> call_router(router_opts)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/x-ndjson"
    assert conn.resp_body =~ ~s|{"event":"start"}|
  end

  test "GET /api/traces/:filename returns 404 for missing file", %{router_opts: router_opts} do
    conn = conn(:get, "/api/traces/missing.jsonl") |> call_router(router_opts)

    assert conn.status == 404
  end

  test "GET /api/traces with path traversal returns 404", %{router_opts: router_opts} do
    conn =
      conn(:get, "/api/traces/..%2F..%2Fetc%2Fpasswd")
      |> call_router(router_opts)

    assert conn.status == 404
  end

  test "GET /api/kernel/runs uses the shared host query adapter", %{trace_dir: trace_dir} do
    adapter = fn _source, operation, arguments ->
      {:ok, %{"operation" => Atom.to_string(operation), "arguments" => arguments}}
    end

    router_opts = [trace_dir: trace_dir, kernel_trace_adapter: adapter]

    conn =
      conn(:get, "/api/kernel/runs?limit=2&status=error")
      |> call_router(router_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body == %{
             "operation" => "list_runs",
             "arguments" => %{"limit" => 2, "status" => "error"}
           }
  end

  test "canonical run, turn, and counter routes preserve query arguments", %{trace_dir: trace_dir} do
    adapter = fn _source, operation, arguments ->
      {:ok, %{"operation" => Atom.to_string(operation), "arguments" => arguments}}
    end

    opts = [trace_dir: trace_dir, kernel_trace_adapter: adapter]

    run = conn(:get, "/api/kernel/runs/run-1") |> call_router(opts)

    turns =
      conn(:get, "/api/kernel/runs/run-1/turns?limit=1&cursor=next-page")
      |> call_router(opts)

    counters =
      conn(:get, "/api/kernel/counters?tags=%7B%22stage%22%3A%22test%22%7D") |> call_router(opts)

    assert Jason.decode!(run.resp_body) == %{
             "operation" => "get_run",
             "arguments" => %{"run_id" => "run-1"}
           }

    assert Jason.decode!(turns.resp_body) == %{
             "operation" => "list_turns",
             "arguments" => %{"run_id" => "run-1", "limit" => 1, "cursor" => "next-page"}
           }

    assert Jason.decode!(counters.resp_body) == %{
             "operation" => "counters",
             "arguments" => %{"tags" => %{"stage" => "test"}}
           }
  end

  test "canonical routes preserve not-found, invalid, unavailable, and adapter-fault failures", %{
    trace_dir: trace_dir
  } do
    assert 503 ==
             (conn(:get, "/api/kernel/runs")
              |> call_router(trace_dir: trace_dir, kernel_trace_adapter: nil)).status

    assert 404 ==
             (conn(:get, "/api/kernel/runs/missing")
              |> call_router(
                trace_dir: trace_dir,
                kernel_trace_adapter: fn _, _, _ -> {:error, :not_found} end
              )).status

    assert 400 ==
             (conn(:get, "/api/kernel/runs?limit=nope")
              |> call_router(
                trace_dir: trace_dir,
                kernel_trace_adapter: fn _, _, _ -> {:error, :invalid_query} end
              )).status

    assert 500 ==
             (conn(:get, "/api/kernel/runs")
              |> call_router(
                trace_dir: trace_dir,
                kernel_trace_adapter: fn _, _, _ -> raise "adapter failed" end
              )).status

    assert 500 ==
             (conn(:get, "/api/kernel/runs")
              |> call_router(
                trace_dir: trace_dir,
                kernel_trace_adapter: fn _, _, _ -> :unexpected end
              )).status
  end

  test "canonical routes classify trace source failures", %{trace_dir: trace_dir} do
    statuses = %{
      source_unavailable: 503,
      source_changed: 409,
      source_limit_exceeded: 413,
      malformed_source: 422,
      unsupported_version: 422
    }

    Enum.each(statuses, fn {reason, expected_status} ->
      conn =
        conn(:get, "/api/kernel/runs")
        |> call_router(
          trace_dir: trace_dir,
          kernel_trace_adapter: fn _, _, _ -> {:error, reason} end
        )

      assert conn.status == expected_status
    end)
  end

  defp call_router(conn, opts), do: PtcViewer.Router.call(conn, PtcViewer.Router.init(opts))
end
