defmodule PtcViewer.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  @moduletag :router
  @moduletag :tmp_dir

  setup %{tmp_dir: trace_dir} do
    %{trace_dir: trace_dir, router_opts: [trace_dir: trace_dir, kernel_trace_adapter: nil]}
  end

  test "legacy raw trace routes are absent", %{router_opts: router_opts} do
    assert (conn(:get, "/api/traces") |> call_router(router_opts)).status == 404
    assert (conn(:get, "/api/traces/trace1.jsonl") |> call_router(router_opts)).status == 404
  end

  test "canonical transcript frontend asset is served", %{router_opts: router_opts} do
    conn = conn(:get, "/js/kernel-transcript.js") |> call_router(router_opts)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "javascript"
    assert conn.resp_body =~ "Canonical Kernel TraceLog transcript view"
  end

  test "entry, run handoff, and unknown browser paths have distinct HTTP semantics", %{
    router_opts: router_opts
  } do
    entry = conn(:get, "/") |> call_router(router_opts)
    assert entry.status == 200
    assert entry.resp_body =~ "ptc-viewer-config"

    handoff = conn(:get, "/run/run%3Aone") |> call_router(router_opts)
    assert handoff.status == 302
    assert get_resp_header(handoff, "location") == ["/#/run/run%3Aone"]
    refute handoff.resp_body =~ "ptc-viewer-config"

    for request <- [
          conn(:get, "/runs"),
          conn(:get, "/runs/does-not-exist"),
          conn(:get, "/totally/made/up"),
          conn(:post, "/totally/made/up", "")
        ] do
      response = call_router(request, router_opts)
      assert response.status == 404
      assert response.resp_body == "Not found"
      refute response.resp_body =~ "ptc-viewer-config"
    end
  end

  test "path-form run handoff enforces the Viewer run ID bound", %{router_opts: router_opts} do
    oversized = String.duplicate("a", 513)
    response = conn(:get, "/run/#{oversized}") |> call_router(router_opts)

    assert response.status == 404
    assert response.resp_body == "Not found"
  end

  test "GET /api/kernel/runs uses the shared host query adapter", %{trace_dir: trace_dir} do
    adapter = fn _source, operation, arguments ->
      {:ok, %{"operation" => Atom.to_string(operation), "arguments" => arguments}}
    end

    router_opts = [trace_dir: trace_dir, kernel_trace_adapter: adapter]

    conn =
      conn(:get, "/api/kernel/runs?limit=2&status=error&bundle=sha256%3Abundle")
      |> call_router(router_opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)

    assert body == %{
             "operation" => "list_runs",
             "arguments" => %{
               "limit" => 2,
               "status" => "error",
               "bundle" => "sha256:bundle"
             }
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

  test "canonical routes preserve isolated-run and retained-size failures", %{
    trace_dir: trace_dir
  } do
    for {reason, expected_status, expected_body} <- [
          {:run_isolated, 422, "run_isolated"},
          {:source_retained_limit_exceeded, 413, "Trace source retained size exceeded"}
        ] do
      response =
        conn(:get, "/api/kernel/runs/damaged")
        |> call_router(
          trace_dir: trace_dir,
          kernel_trace_adapter: fn _, _, _ -> {:error, reason} end
        )

      assert response.status == expected_status
      assert response.resp_body == expected_body
    end
  end

  test "conversation route is unconfigured by default and delegates a fixed source", %{
    trace_dir: trace_dir
  } do
    unconfigured =
      conn(:get, "/api/analysis/runs/run-1/conversation") |> call_router(trace_dir: trace_dir)

    # A project that records no inspection artifact is a configuration state
    # with a next action, not an unreachable service.
    assert unconfigured.status == 404
    assert unconfigured.resp_body == "inspection_not_configured"

    # The private grant is a different configuration state with a different next
    # action, so it answers under its own reason code.
    ungranted =
      conn(:get, "/api/analysis/runs/run-1/conversation")
      |> call_router(trace_dir: trace_dir, inspection_absence: :not_private)

    assert ungranted.status == 404
    assert ungranted.resp_body == "inspection_not_private"

    # Host-side grant decisions answer with this same body. The adapter below
    # only locks the HTTP mapping; it does not exercise ViewerSnapshotStore.
    adapter = fn _source, _run_id -> {:error, :inspection_not_private} end
    source = {:pinned, "fixed.ptcins"}
    {:ok, withheld} = PtcViewer.InspectionStore.start(source)
    on_exit(fn -> if Process.alive?(withheld), do: PtcViewer.InspectionStore.stop(withheld) end)

    withheld_response =
      conn(:get, "/api/analysis/runs/r1/conversation")
      |> call_router(
        trace_dir: trace_dir,
        inspection_store: withheld,
        inspection_adapter: adapter
      )

    assert withheld_response.status == 404
    assert withheld_response.resp_body == "inspection_not_private"

    source = {:pinned, "fixed.ptcins"}

    adapter = fn pinned_source, run_id ->
      {:ok,
       %{
         "source" => inspect(pinned_source),
         "run_id" => run_id,
         "streams" => [%{"stream_id" => "stream-1"}]
       }}
    end

    {:ok, store} = PtcViewer.InspectionStore.start(source)
    on_exit(fn -> if Process.alive?(store), do: PtcViewer.InspectionStore.stop(store) end)

    response =
      conn(:get, "/api/analysis/runs/run-1/conversation")
      |> call_router(
        trace_dir: trace_dir,
        inspection_store: store,
        inspection_adapter: adapter
      )

    assert response.status == 200

    assert Jason.decode!(response.resp_body) == %{
             "source" => inspect(source),
             "run_id" => "run-1",
             "streams" => [%{"stream_id" => "stream-1"}]
           }
  end

  test "conversation route classifies fixed source failures", %{trace_dir: trace_dir} do
    # A run the grant does not cover is a configuration state the reader can
    # act on, so it answers with a reason code the browser renders as a
    # sentence. A source that failed is a transport status and stays prose.
    responses = %{
      not_found: {404, "inspection_run_not_recorded"},
      inspection_run_mismatch: {404, "inspection_run_mismatch"},
      inspection_source_unavailable: {503, "Inspection source unavailable"},
      inspection_source_changed: {409, "Inspection source changed"},
      inspection_source_limit_exceeded: {413, "Inspection source too large"},
      malformed_inspection_artifact: {422, "Unsupported inspection artifact"},
      invalid_inspection_artifact: {422, "Unsupported inspection artifact"}
    }

    Enum.each(responses, fn {reason, {expected_status, expected_body}} ->
      {:ok, store} =
        PtcViewer.InspectionStore.start({:pinned, "fixed.ptcins"})

      response =
        conn(:get, "/api/analysis/runs/run-1/conversation")
        |> call_router(
          trace_dir: trace_dir,
          inspection_store: store,
          inspection_adapter: fn _, _ -> {:error, reason} end
        )

      assert response.status == expected_status
      assert response.resp_body == expected_body
      PtcViewer.InspectionStore.stop(store)
    end)
  end

  test "result route delegates the pinned inspection source", %{trace_dir: trace_dir} do
    source = {:pinned, "fixed.ptcins"}
    {:ok, store} = PtcViewer.InspectionStore.start(source)
    on_exit(fn -> if Process.alive?(store), do: PtcViewer.InspectionStore.stop(store) end)

    response =
      conn(:get, "/api/analysis/runs/run-1/result")
      |> call_router(
        trace_dir: trace_dir,
        inspection_store: store,
        inspection_adapter: PtcViewer.PinningInspectionTestAdapter
      )

    assert response.status == 200
    assert Jason.decode!(response.resp_body)["value"] == "done"

    missing =
      conn(:get, "/api/analysis/runs/run-1/result")
      |> call_router(
        trace_dir: trace_dir,
        inspection_store: store,
        inspection_adapter: PtcViewer.MissingResultInspectionTestAdapter
      )

    assert missing.status == 404
    assert missing.resp_body == "inspection_result_not_recorded"
  end

  test "prelude route delegates only the pinned inspection grant", %{trace_dir: trace_dir} do
    source = {:pinned, "fixed.ptcins"}
    {:ok, store} = PtcViewer.InspectionStore.start(source)
    on_exit(fn -> if Process.alive?(store), do: PtcViewer.InspectionStore.stop(store) end)

    response =
      conn(:get, "/api/analysis/runs/run-1/preludes")
      |> call_router(
        trace_dir: trace_dir,
        inspection_store: store,
        inspection_adapter: PtcViewer.PinningInspectionTestAdapter
      )

    assert response.status == 200

    assert Jason.decode!(response.resp_body) == %{
             "source" => inspect(source),
             "run_id" => "run-1",
             "items" => []
           }
  end

  test "execution-error and explicit-failure-value routes delegate the pinned grant", %{
    trace_dir: trace_dir
  } do
    source = {:pinned, "fixed.ptcins"}
    {:ok, store} = PtcViewer.InspectionStore.start(source)
    on_exit(fn -> if Process.alive?(store), do: PtcViewer.InspectionStore.stop(store) end)

    errors =
      conn(:get, "/api/analysis/runs/run-1/execution-errors")
      |> call_router(
        trace_dir: trace_dir,
        inspection_store: store,
        inspection_adapter: PtcViewer.PinningInspectionTestAdapter
      )

    failures =
      conn(:get, "/api/analysis/runs/run-1/explicit-failure-values")
      |> call_router(
        trace_dir: trace_dir,
        inspection_store: store,
        inspection_adapter: PtcViewer.PinningInspectionTestAdapter
      )

    expected = %{
      "source" => inspect(source),
      "run_id" => "run-1",
      "items" => []
    }

    assert errors.status == 200
    assert failures.status == 200
    assert Jason.decode!(errors.resp_body) == expected
    assert Jason.decode!(failures.resp_body) == expected
  end

  test "POST /api/kernel/refresh recaptures the host snapshot without a run id", %{
    trace_dir: trace_dir
  } do
    test = self()

    refreshed =
      conn(:post, "/api/kernel/refresh")
      |> call_router(
        trace_dir: trace_dir,
        live_trace_refresh: fn nil ->
          send(test, :refreshed)
          :ok
        end
      )

    assert refreshed.status == 200
    assert Jason.decode!(refreshed.resp_body) == %{"status" => "ok"}
    assert_received :refreshed

    missing =
      conn(:post, "/api/kernel/refresh")
      |> call_router(trace_dir: trace_dir)

    assert missing.status == 503
    assert missing.resp_body == "Trace refresh unavailable"
  end

  defp call_router(conn, opts), do: PtcViewer.Router.call(conn, PtcViewer.Router.init(opts))
end
