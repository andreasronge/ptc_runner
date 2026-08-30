defmodule PtcViewer.LiveRouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias PtcViewer.LiveStore

  @moduletag :tmp_dir
  @live_nonce "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @live_token "container-reporter-token-with-at-least-32-bytes"
  @live_launch_body_limit 2_000_010

  setup %{tmp_dir: trace_dir} do
    {:ok, store} = LiveStore.start(self())

    %{
      store: store,
      opts: [
        trace_dir: trace_dir,
        kernel_trace_adapter: nil,
        live_store: store,
        live_mutation_nonce: @live_nonce
      ]
    }
  end

  test "a non-loopback reporter must authenticate with the configured bearer token", %{
    opts: opts
  } do
    opts = Keyword.put(opts, :live_token_digest, PtcViewer.LiveSecurity.token_digest(@live_token))
    frame = Jason.encode!(%{"seq" => 0, "phase" => "running"})

    unauthenticated =
      conn(:post, "http://viewer.internal/api/live/runs/run-remote", frame)
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert unauthenticated.status == 403

    authenticated =
      conn(:post, "http://viewer.internal/api/live/runs/run-remote", frame)
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @live_token)
      |> call_router(opts)

    assert authenticated.status == 200
  end

  test "browser live reads and mutations reject non-local authorities", %{
    opts: opts,
    store: store
  } do
    :ok = LiveStore.put_frame(store, "run-abc", %{"seq" => 0, "phase" => "ok"})

    project_opts = Keyword.put(opts, :live_project, fn -> %{"name" => "secret-source"} end)

    assert (conn(:get, "http://evil.example/api/live/project")
            |> call_router(project_opts)).status == 403

    delete =
      conn(:delete, "http://evil.example/api/live/runs/run-abc")
      |> Plug.Conn.put_req_header("origin", "http://evil.example")
      |> Plug.Conn.put_req_header("x-ptc-viewer-live-nonce", @live_nonce)
      |> call_router(opts)

    assert delete.status == 403
    assert [%{"run_id" => "run-abc"}] = LiveStore.snapshot(store)
  end

  test "spoofed local authority cannot enable or mutate live controls without the bearer token",
       %{
         opts: opts,
         store: store
       } do
    :ok = LiveStore.put_frame(store, "run-abc", %{"seq" => 0, "phase" => "ok"})
    opts = Keyword.put(opts, :live_token_digest, PtcViewer.LiveSecurity.token_digest(@live_token))

    spoofed_entry =
      conn(:get, "http://localhost/")
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> call_router(opts)

    refute entry_config(spoofed_entry)["live_enabled"]

    refused =
      conn(:delete, "http://localhost/api/live/runs/run-abc")
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("x-ptc-viewer-live-nonce", @live_nonce)
      |> call_router(opts)

    assert refused.status == 403
    assert [%{"run_id" => "run-abc"}] = LiveStore.snapshot(store)

    authenticated_entry =
      conn(:get, "http://localhost/?live_token=#{@live_token}")
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> call_router(opts)

    assert entry_config(authenticated_entry)["live_enabled"]

    accepted =
      conn(:delete, "http://localhost/api/live/runs/run-abc")
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @live_token)
      |> Plug.Conn.put_req_header("x-ptc-viewer-live-nonce", @live_nonce)
      |> call_router(opts)

    assert accepted.status == 200
  end

  test "spoofed local authority cannot read live data without the bearer token", %{
    opts: opts,
    store: store
  } do
    :ok = LiveStore.put_frame(store, "run-secret", %{"seq" => 0, "phase" => "running"})

    opts =
      opts
      |> Keyword.put(:live_token_digest, PtcViewer.LiveSecurity.token_digest(@live_token))
      |> Keyword.put(:live_project, fn -> %{"name" => "secret-project"} end)

    refused =
      conn(:get, "http://localhost/api/live/project")
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> call_router(opts)

    assert refused.status == 403
    refute refused.resp_body =~ "secret-project"

    authenticated =
      conn(:get, "http://localhost/api/live/runs")
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> @live_token)
      |> call_router(opts)

    assert authenticated.status == 200
    assert authenticated.resp_body =~ "run-secret"

    query_authenticated =
      conn(:get, "http://localhost/api/live/runs?live_token=#{@live_token}")
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> call_router(opts)

    assert query_authenticated.status == 200
    assert query_authenticated.resp_body =~ "run-secret"
  end

  test "a percent-encoded token containing plus signs enables remote browser controls", %{
    opts: opts
  } do
    token = "token+with+plus+signs+and-at-least-32-bytes"
    opts = Keyword.put(opts, :live_token_digest, PtcViewer.LiveSecurity.token_digest(token))

    entry =
      conn(:get, "http://localhost/?live_token=#{URI.encode_www_form(token)}")
      |> Map.put(:remote_ip, {172, 18, 0, 4})
      |> call_router(opts)

    assert entry_config(entry)["live_enabled"]
  end

  test "browser live mutations require same-origin authority and the page nonce", %{
    opts: opts,
    store: store
  } do
    :ok = LiveStore.put_frame(store, "run-abc", %{"seq" => 0, "phase" => "ok"})

    missing_nonce =
      conn(:delete, "http://localhost/api/live/runs/run-abc")
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> call_router(opts)

    assert missing_nonce.status == 403

    accepted =
      conn(:delete, "http://localhost/api/live/runs/run-abc")
      |> Plug.Conn.put_req_header("origin", "http://localhost")
      |> Plug.Conn.put_req_header("x-ptc-viewer-live-nonce", @live_nonce)
      |> call_router(opts)

    assert accepted.status == 200
  end

  test "entry config exposes live controls only on a local authority", %{opts: opts} do
    local = browser_conn(:get, "/") |> call_router(opts) |> entry_config()
    assert local["live_enabled"]
    assert local["live_mutation_nonce"] == @live_nonce

    remote = conn(:get, "http://viewer.internal/") |> call_router(opts) |> entry_config()
    refute remote["live_enabled"]
    refute Map.has_key?(remote, "live_mutation_nonce")
  end

  test "frames posted by a run are exposed to the snapshot endpoint", %{opts: opts} do
    frame = %{"seq" => 0, "phase" => "running", "elapsed_ms" => 10}

    post_conn =
      conn(:post, "/api/live/runs/run-abc", Jason.encode!(frame))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert post_conn.status == 200

    get_conn = browser_conn(:get, "/api/live/runs") |> call_router(opts)
    assert get_conn.status == 200

    assert %{"runs" => [%{"run_id" => "run-abc", "phase" => "running"}]} =
             Jason.decode!(get_conn.resp_body)
  end

  test "snapshot endpoint returns newest run first so runs[0] is the latest ceiling", %{
    opts: opts
  } do
    for {run_id, limit} <- [{"run-old", 30_000}, {"run-new", 1}] do
      frame = %{"seq" => 0, "phase" => "ok", "limits" => %{"run_duration_ms" => limit}}

      post_conn =
        conn(:post, "/api/live/runs/#{run_id}", Jason.encode!(frame))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> call_router(opts)

      assert post_conn.status == 200
    end

    get_conn = browser_conn(:get, "/api/live/runs") |> call_router(opts)
    assert get_conn.status == 200

    assert %{"runs" => [newest, oldest]} = Jason.decode!(get_conn.resp_body)
    assert newest["run_id"] == "run-new"
    assert newest["limits"]["run_duration_ms"] == 1
    assert oldest["run_id"] == "run-old"
    assert oldest["limits"]["run_duration_ms"] == 30_000
    assert {:ok, _at, 0} = DateTime.from_iso8601(newest["first_seen_at"])
    assert {:ok, _at, 0} = DateTime.from_iso8601(oldest["first_seen_at"])
  end

  test "deleting a run removes it from the snapshot", %{opts: opts, store: store} do
    :ok = LiveStore.put_frame(store, "run-abc", %{"seq" => 0, "phase" => "ok"})

    delete_conn = browser_mutation(:delete, "/api/live/runs/run-abc") |> call_router(opts)
    assert delete_conn.status == 200
    assert Jason.decode!(delete_conn.resp_body) == %{"status" => "ok"}

    get_conn = browser_conn(:get, "/api/live/runs") |> call_router(opts)
    assert %{"runs" => []} = Jason.decode!(get_conn.resp_body)
  end

  test "deleting an unknown run answers 404 JSON", %{opts: opts} do
    delete_conn = browser_mutation(:delete, "/api/live/runs/nope") |> call_router(opts)

    assert delete_conn.status == 404
    assert Jason.decode!(delete_conn.resp_body) == %{"error" => "unknown_run"}
  end

  test "inspecting an ended run refreshes the host snapshot before navigation", %{opts: opts} do
    test = self()

    opts =
      Keyword.put(opts, :live_trace_refresh, fn run_id ->
        send(test, {:refresh_trace, run_id})
        :ok
      end)

    conn = browser_mutation(:post, "/api/live/runs/run-abc/inspect") |> call_router(opts)

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
    assert_receive {:refresh_trace, "run-abc"}
  end

  test "inspect reports a run that is not yet in canonical traces", %{opts: opts} do
    opts = Keyword.put(opts, :live_trace_refresh, fn _run_id -> {:error, :not_found} end)

    conn = browser_mutation(:post, "/api/live/runs/run-abc/inspect") |> call_router(opts)

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "run_not_found"}
  end

  test "deleting a run answers 503 when no store is configured", %{tmp_dir: trace_dir} do
    opts = [
      trace_dir: trace_dir,
      kernel_trace_adapter: nil,
      live_mutation_nonce: @live_nonce
    ]

    assert (browser_mutation(:delete, "/api/live/runs/run-abc") |> call_router(opts)).status ==
             503
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

    assert (browser_conn(:get, "/api/live/runs") |> call_router(opts)).status == 503
    assert (browser_conn(:get, "/api/live/launch") |> call_router(opts)).status == 503
  end

  test "project endpoint serves the adapter payload", %{opts: opts} do
    adapter = fn -> %{"name" => "demo", "environments" => [%{"name" => "workflow"}]} end

    get_conn =
      browser_conn(:get, "/api/live/project")
      |> call_router(Keyword.put(opts, :live_project, adapter))

    assert get_conn.status == 200

    assert %{"enabled" => true, "name" => "demo", "environments" => [%{"name" => "workflow"}]} =
             Jason.decode!(get_conn.resp_body)
  end

  test "project endpoint accepts an {:ok, project} adapter result", %{opts: opts} do
    adapter = fn -> {:ok, %{"name" => "demo"}} end

    get_conn =
      browser_conn(:get, "/api/live/project")
      |> call_router(Keyword.put(opts, :live_project, adapter))

    assert %{"enabled" => true, "name" => "demo"} = Jason.decode!(get_conn.resp_body)
  end

  test "project endpoint reports disabled without an adapter", %{opts: opts} do
    get_conn = browser_conn(:get, "/api/live/project") |> call_router(opts)

    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body) == %{"enabled" => false}
  end

  test "a failing adapter degrades to disabled instead of 500", %{opts: opts} do
    adapter = fn -> raise "manifest vanished" end

    get_conn =
      browser_conn(:get, "/api/live/project")
      |> call_router(Keyword.put(opts, :live_project, adapter))

    assert get_conn.status == 200
    assert Jason.decode!(get_conn.resp_body) == %{"enabled" => false}
  end

  test "an adapter returning a non-map degrades to disabled", %{opts: opts} do
    get_conn =
      browser_conn(:get, "/api/live/project")
      |> call_router(Keyword.put(opts, :live_project, fn -> :nope end))

    assert Jason.decode!(get_conn.resp_body) == %{"enabled" => false}
  end

  test "project endpoint answers 503 when no store is configured", %{tmp_dir: trace_dir} do
    opts = [trace_dir: trace_dir, kernel_trace_adapter: nil]

    assert (browser_conn(:get, "/api/live/project") |> call_router(opts)).status == 503
  end

  test "launch endpoint reports disabled without a configured target", %{opts: opts} do
    get_conn = browser_conn(:get, "/api/live/launch") |> call_router(opts)

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
        label: "demo",
        adapter: fn _request, _report -> {0, "ok"} end
      })

    get_conn = browser_conn(:get, "/api/live/launch") |> call_router(opts)
    assert get_conn.status == 200

    assert %{
             "enabled" => true,
             "manifest" => "demo.json",
             "label" => "demo",
             "input" => %{"topics" => ["a", "b"]},
             "launch" => %{"status" => "idle"}
           } = Jason.decode!(get_conn.resp_body)

    post_conn =
      browser_mutation(
        :post,
        "/api/live/launch",
        Jason.encode!(%{"input" => %{"topics" => ["x"]}})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert post_conn.status == 202
  end

  test "launch accepts the canonical 2 MB input boundary and rejects the next byte", %{
    opts: opts,
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "demo.json"), "{}")
    test_process = self()

    opts =
      Keyword.put(opts, :live_launch, %{
        manifest: "demo.json",
        cwd: tmp_dir,
        adapter: fn request, _report ->
          send(test_process, {:large_launch, request})
          {0, "ok"}
        end
      })

    accepted =
      browser_mutation(:post, "/api/live/launch", launch_body(@live_launch_body_limit))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert accepted.status == 202
    assert_receive {:large_launch, {:workflow, %{input: _name}}}, 2_000

    rejected =
      browser_mutation(:post, "/api/live/launch", launch_body(@live_launch_body_limit + 1))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert rejected.status == 400
    assert Jason.decode!(rejected.resp_body) == %{"error" => "body_too_large"}
  end

  test "a mission body takes the mission path, not the input path", %{opts: opts, tmp_dir: dir} do
    File.write!(Path.join(dir, "demo.json"), "{}")
    test_process = self()

    adapter = fn request, _report ->
      send(test_process, {:launch_request, request})
      {0, "ok"}
    end

    opts =
      Keyword.put(opts, :live_launch, %{manifest: "demo.json", cwd: dir, adapter: adapter})

    post_conn =
      browser_mutation(
        :post,
        "/api/live/launch",
        Jason.encode!(%{"mission" => "review", "expression" => "(dir)"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert post_conn.status == 202
    assert_receive {:launch_request, {:mission, %{name: "review", expression: "(dir)"}}}

    without_expression =
      browser_mutation(
        :post,
        "/api/live/launch",
        Jason.encode!(%{"mission" => "review"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> call_router(opts)

    assert Jason.decode!(without_expression.resp_body) == %{"error" => "invalid_input"}
  end

  defp call_router(conn, opts), do: PtcViewer.Router.call(conn, PtcViewer.Router.init(opts))

  defp browser_conn(method, path, body \\ nil),
    do: conn(method, "http://localhost" <> path, body)

  defp browser_mutation(method, path, body \\ nil) do
    method
    |> browser_conn(path, body)
    |> Plug.Conn.put_req_header("origin", "http://localhost")
    |> Plug.Conn.put_req_header("x-ptc-viewer-live-nonce", @live_nonce)
  end

  defp launch_body(size) do
    prefix = ~s({"input":{"payload":")
    suffix = ~s("}})
    prefix <> String.duplicate("x", size - byte_size(prefix) - byte_size(suffix)) <> suffix
  end

  defp entry_config(conn) do
    [encoded] =
      Regex.run(~r/<meta name="ptc-viewer-config" content="([^"]+)">/, conn.resp_body,
        capture: :all_but_first
      )

    encoded
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end
end
