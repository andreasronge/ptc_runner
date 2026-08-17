defmodule PtcViewer.LiveRouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias PtcViewer.LiveStore

  @moduletag :tmp_dir

  setup %{tmp_dir: trace_dir} do
    {:ok, store} = LiveStore.start(self())

    %{
      store: store,
      opts: [trace_dir: trace_dir, kernel_trace_adapter: nil, live_store: store, live_port: 0]
    }
  end

  test "frames posted by a run are exposed to the snapshot endpoint", %{opts: opts} do
    frame = %{"seq" => 0, "phase" => "running", "elapsed_ms" => 10}

    post_conn =
      conn(:post, "/api/live/runs/run-abc", Jason.encode!(frame))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert post_conn.status == 200

    get_conn = conn(:get, "/api/live/runs") |> call_router(opts)
    assert get_conn.status == 200

    assert %{"runs" => [%{"run_id" => "run-abc", "phase" => "running"}]} =
             Jason.decode!(get_conn.resp_body)
  end

  test "deleting a run removes it from the snapshot", %{opts: opts, store: store} do
    :ok = LiveStore.put_frame(store, "run-abc", %{"seq" => 0, "phase" => "ok"})

    delete_conn = conn(:delete, "/api/live/runs/run-abc") |> call_router(opts)
    assert delete_conn.status == 200
    assert Jason.decode!(delete_conn.resp_body) == %{"status" => "ok"}

    get_conn = conn(:get, "/api/live/runs") |> call_router(opts)
    assert %{"runs" => []} = Jason.decode!(get_conn.resp_body)
  end

  test "deleting an unknown run answers 404 JSON", %{opts: opts} do
    delete_conn = conn(:delete, "/api/live/runs/nope") |> call_router(opts)

    assert delete_conn.status == 404
    assert Jason.decode!(delete_conn.resp_body) == %{"error" => "unknown_run"}
  end

  test "deleting a run answers 503 when no store is configured", %{tmp_dir: trace_dir} do
    opts = [trace_dir: trace_dir, kernel_trace_adapter: nil]

    assert (conn(:delete, "/api/live/runs/run-abc") |> call_router(opts)).status == 503
  end

  test "rejects a non-JSON frame body", %{opts: opts} do
    post_conn =
      conn(:post, "/api/live/runs/run-abc", "not json")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert post_conn.status == 400
  end

  test "live endpoints answer 503 when no store is configured", %{tmp_dir: trace_dir} do
    opts = [trace_dir: trace_dir, kernel_trace_adapter: nil]

    assert (conn(:get, "/api/live/runs") |> call_router(opts)).status == 503
    assert (conn(:get, "/api/live/launch") |> call_router(opts)).status == 503
  end

  test "launch endpoint reports disabled without a configured target", %{opts: opts} do
    get_conn = conn(:get, "/api/live/launch") |> call_router(opts)

    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body) == %{"enabled" => false}
  end

  test "launch describes the configured target and its manifest input", %{
    opts: opts,
    tmp_dir: tmp_dir
  } do
    manifest_path = Path.join(tmp_dir, "demo.json")

    File.write!(
      manifest_path,
      Jason.encode!(%{
        "version" => 1,
        "workflow" => %{"components" => [], "entry" => "demo/run"},
        "input" => %{"value" => %{"topics" => ["a", "b"]}}
      })
    )

    opts =
      Keyword.put(opts, :live_launch, %{
        manifest: "demo.json",
        cwd: tmp_dir,
        label: "demo"
      })

    get_conn = conn(:get, "/api/live/launch") |> call_router(opts)
    assert get_conn.status == 200

    assert %{
             "enabled" => true,
             "manifest" => "demo.json",
             "label" => "demo",
             "input" => %{"topics" => ["a", "b"]},
             "launch" => %{"status" => "idle"}
           } = Jason.decode!(get_conn.resp_body)

    # POST with port 0 (tests) is refused as not configured rather than
    # spawning a run whose reporter could never reach back.
    post_conn =
      conn(:post, "/api/live/launch", Jason.encode!(%{"input" => %{"topics" => ["x"]}}))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert post_conn.status == 400
  end

  defp call_router(conn, opts), do: PtcViewer.Router.call(conn, PtcViewer.Router.init(opts))
end
