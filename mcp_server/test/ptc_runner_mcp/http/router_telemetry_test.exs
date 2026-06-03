defmodule PtcRunnerMcp.Http.RouterTelemetryTest do
  use PtcRunnerMcp.Http.RouterCase

  alias PtcRunnerMcp.Http.Auth
  alias PtcRunnerMcp.Http.Telemetry
  alias PtcRunnerMcp.Log
  alias PtcRunnerMcp.TraceConfig
  alias PtcRunnerMcp.TraceHandler

  test "HTTP request telemetry carries request, owner, and session correlation" do
    handler_id = attach_http_telemetry()

    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "obs-init", "method" => "initialize"})
      )
      |> auth()
      |> put_req_header("x-request-id", "http-request-1")
      |> call()

    assert conn.status == 200
    assert get_resp_header(conn, "x-request-id") == ["http-request-1"]
    [session_id] = get_resp_header(conn, "mcp-session-id")

    owner_hash = Auth.owner_for(@token).hash
    session_hash = Telemetry.hash_id(session_id)

    assert_receive {:http_telemetry, ^handler_id, [:ptc_lisp, :http, :request, :start],
                    %{system_time: _}, %{request_id: "http-request-1"}}

    assert_receive {:http_telemetry, ^handler_id, [:ptc_lisp, :http, :session, :created],
                    %{count: 1},
                    %{
                      owner_hash: ^owner_hash,
                      session_hash: ^session_hash,
                      protocol_version: _
                    }}

    assert_receive {:http_telemetry, ^handler_id, [:ptc_lisp, :http, :request, :stop],
                    %{duration: duration},
                    %{
                      request_id: "http-request-1",
                      status: 200,
                      owner_hash: ^owner_hash,
                      session_hash: ^session_hash
                    }}
                   when is_integer(duration)
  end

  test "HTTP request log line is correlated and does not leak the raw session id" do
    Log.set_level(:info)
    parent = self()

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        conn =
          conn(
            :post,
            "/mcp",
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => "log-init", "method" => "initialize"})
          )
          |> auth()
          |> put_req_header("x-request-id", "http-log-1")
          |> call()

        assert conn.status == 200
        [session_id] = get_resp_header(conn, "mcp-session-id")
        send(parent, {:created_session_id, session_id})
      end)

    assert_receive {:created_session_id, session_id}

    line =
      stderr
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["event"] == "http_request_stop"))

    assert line["request_id"] == "http-log-1"
    assert line["fields"]["status"] == 200
    assert line["fields"]["owner_hash"] == Auth.owner_for(@token).hash
    refute String.contains?(stderr, @token)
    refute String.contains?(stderr, session_id)
  end

  test "HTTP tool-call traces carry owner and session hashes" do
    dir = Path.join(System.tmp_dir!(), "ptc_mcp_http_trace_#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    TraceConfig.set(%{trace_dir: dir, trace_payloads: :summary, trace_max_files: 1000})
    TraceHandler.attach()

    session_id = initialize_session()
    owner_hash = Auth.owner_for(@token).hash
    session_hash = Telemetry.hash_id(session_id)

    call = %{
      "jsonrpc" => "2.0",
      "id" => "trace-call",
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_eval",
        "arguments" => %{"program" => "(+ 1 2)", "context" => %{}}
      }
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(call))
      |> auth()
      |> put_req_header("x-request-id", "http-trace-1")
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 200

    [file] = wait_for_files(dir, 1)
    events = read_jsonl(Path.join(dir, file))
    call_start = Enum.find(events, &(&1["event"] == "ptc_lisp.call.start"))

    assert call_start["metadata"]["owner_hash"] == owner_hash
    assert call_start["metadata"]["mcp_session_hash"] == session_hash
    assert call_start["metadata"]["transport_request_id"] == "http-trace-1"
    refute inspect(events) =~ @token
    refute inspect(events) =~ session_id

    File.rm_rf!(dir)
  end

  defp attach_http_telemetry do
    handler_id = "http-router-test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:ptc_lisp, :http, :request, :start],
          [:ptc_lisp, :http, :request, :stop],
          [:ptc_lisp, :http, :session, :created]
        ],
        fn event, measurements, metadata, _config ->
          send(parent, {:http_telemetry, handler_id, event, measurements, metadata})
        end,
        %{}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp read_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
