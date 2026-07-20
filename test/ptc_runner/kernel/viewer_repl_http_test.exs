defmodule PtcRunner.Kernel.ViewerReplHttpTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.ViewerReplAdapter

  @tag :tmp_dir
  test "real Viewer HTTP lifecycle delegates to the root log-analysis backend", %{
    tmp_dir: trace_dir
  } do
    seed_trace(trace_dir, "seed")
    telemetry_id = "viewer-repl-http-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      telemetry_id,
      [[:bandit, :request, :start], [:bandit, :request, :stop]],
      fn event, _measurements, metadata, test_pid ->
        send(test_pid, {:viewer_repl_telemetry, event, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    {:ok, viewer} =
      PtcViewer.start(
        port: 0,
        trace_dir: trace_dir,
        repl_adapter: ViewerReplAdapter,
        repl_config: %{trace_dir: trace_dir, profile_id: "log-analysis-v1"},
        open: false
      )

    on_exit(fn -> if Process.alive?(viewer), do: PtcViewer.stop(viewer) end)
    assert {:ok, {{127, 0, 0, 1}, port}} = PtcViewer.listener_info(viewer)
    origin = "http://127.0.0.1:#{port}"

    html = Req.get!(origin <> "/")
    assert html.status == 200
    assert html.headers["cache-control"] == ["no-store"]

    [encoded] =
      Regex.run(~r/name="ptc-viewer-config" content="([^"]+)"/, html.body,
        capture: :all_but_first
      )

    page_config = encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert page_config["repl_enabled"] == true

    bootstrap =
      Req.get!(origin <> "/api/repl",
        headers: [
          {"sec-fetch-site", "same-origin"},
          {"x-ptc-viewer-page-nonce", page_config["page_bootstrap_nonce"]}
        ]
      )

    assert bootstrap.status == 200
    session_id = bootstrap.body["session_id"]
    nonce = bootstrap.body["mutation_nonce"]
    assert bootstrap.body["session"]["profile_id"] == "log-analysis-v1"
    assert bootstrap.body["session"]["namespaces"] == ["log"]
    refute inspect(bootstrap.body) =~ trace_dir

    private_source = ~S|(do "PRIVATE_REPL_SOURCE" (log/runs {}))|

    evaluated =
      Req.post!(origin <> "/api/repl/evaluations",
        json: %{"source" => private_source},
        headers: mutation_headers(origin, session_id, nonce)
      )

    assert evaluated.status == 200
    assert evaluated.body["evaluation"]["status"] == "ok"
    assert evaluated.body["evaluation"]["value_available?"] == true
    assert length(evaluated.body["transcript"]) == 1

    recoverable_error =
      Req.post!(origin <> "/api/repl/evaluations",
        json: %{"source" => "(missing/function)"},
        headers: mutation_headers(origin, session_id, nonce)
      )

    assert recoverable_error.status == 200
    assert recoverable_error.body["evaluation"]["status"] == "error"
    assert recoverable_error.body["evaluation"]["outcome"] == "evaluation_error"
    assert recoverable_error.body["evaluation"]["continuation_effect"] == "preserved"
    assert length(recoverable_error.body["transcript"]) == 2

    closed =
      Req.delete!(origin <> "/api/repl",
        headers: mutation_headers(origin, session_id, nonce)
      )

    assert closed.status == 200
    assert closed.body["lifecycle"] == "closed"

    telemetry = collect_telemetry([])
    assert length(telemetry) == 10

    telemetry_text =
      telemetry |> Enum.filter(&(elem(&1, 0) == [:bandit, :request, :stop])) |> inspect()

    refute telemetry_text =~ page_config["page_bootstrap_nonce"]
    refute telemetry_text =~ nonce
    refute telemetry_text =~ session_id
    refute telemetry_text =~ "PRIVATE_REPL_SOURCE"

    assert :ok = PtcViewer.stop(viewer)

    persisted =
      trace_dir
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, "log-analysis-"))

    assert length(persisted) == 1
  end

  defp mutation_headers(origin, session_id, nonce) do
    [
      {"origin", origin},
      {"x-ptc-viewer-session", session_id},
      {"x-ptc-viewer-nonce", nonce}
    ]
  end

  defp collect_telemetry(events) do
    receive do
      {:viewer_repl_telemetry, event, metadata} ->
        collect_telemetry([{event, metadata} | events])
    after
      100 -> Enum.reverse(events)
    end
  end

  defp seed_trace(directory, run_id) do
    path = Path.join(directory, run_id <> ".jsonl")
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)
    :ok = EventSink.emit(sink, "run-started", %{})
    :ok = EventSink.emit(sink, "run-stopped", %{outcome: :ok, reason: nil})
    :ok = TraceLog.append_jsonl(path, EventSink.events(sink))
    EventSink.stop(sink)
  end
end
