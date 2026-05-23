defmodule PtcRunnerMcp.HttpRouterTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  import PtcRunnerMcp.TestSupport.WaitHelpers

  alias PtcRunnerMcp.ConcurrencyGate
  alias PtcRunnerMcp.Http.Auth
  alias PtcRunnerMcp.Http.Config, as: HttpConfig
  alias PtcRunnerMcp.Http.Router
  alias PtcRunnerMcp.Http.SessionRegistry
  alias PtcRunnerMcp.Http.Telemetry
  alias PtcRunnerMcp.Log
  alias PtcRunnerMcp.McpTestHelpers
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.{Names, Owner, Registry, Supervisor}
  alias PtcRunnerMcp.TraceConfig
  alias PtcRunnerMcp.TraceHandler

  @token String.duplicate("a", 32)

  setup context do
    McpTestHelpers.stop_existing_registry(SessionRegistry)
    {:ok, cfg} = HttpConfig.resolve(%{http: true, http_auth_token: @token})
    cfg = %{cfg | max_sessions: Map.get(context, :max_sessions, cfg.max_sessions)}
    Application.put_env(:ptc_runner_mcp, :http_config, cfg)
    start_supervised!({SessionRegistry, [config: cfg]})
    PtcRunnerMcp.ConcurrencyGate.init()
    PtcRunnerMcp.ConcurrencyGate.reset()

    original_trace = TraceConfig.get()
    original_log_level = Log.level()

    on_exit(fn ->
      SessionsConfig.set(SessionsConfig.defaults())
      TraceConfig.set(original_trace)
      TraceHandler.detach()
      Log.set_level(original_log_level)
    end)

    {:ok, cfg: cfg}
  end

  test "GET /mcp returns 405 with Allow" do
    conn = call(conn(:get, "/mcp"))
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST, DELETE"]
  end

  test "health and ready are unauthenticated" do
    assert call(conn(:get, "/health")).status == 200
    assert call(conn(:get, "/ready")).status == 200
  end

  test "missing and bad auth return bearer challenges" do
    conn =
      conn(:post, "/mcp", "{}") |> put_req_header("content-type", "application/json") |> call()

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

    conn =
      conn(:post, "/mcp", "{}")
      |> put_req_header("authorization", "Bearer nope")
      |> call()

    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
  end

  test "loopback bind rejects hostile Host before reading MCP POST body" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )
      |> auth()
      |> with_host("attacker.example")
      |> call()

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "missing Origin is allowed when Host is loopback" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )
      |> auth()
      |> with_host("127.0.0.1")
      |> call()

    assert conn.status == 200
    assert get_resp_header(conn, "mcp-session-id") != []
  end

  test "invalid browser Origin is rejected even with loopback Host" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )
      |> auth()
      |> with_host("127.0.0.1")
      |> put_req_header("origin", "http://attacker.example")
      |> call()

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "POST rejects present non-JSON content types" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
      )
      |> auth()
      |> put_req_header("content-type", "text/plain")
      |> call()

    assert conn.status == 415
    assert conn.resp_body == "unsupported media type"
  end

  test "initialize creates a session and later notification returns 202" do
    init = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-06-18"}
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(init))
      |> auth()
      |> call()

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    body = Jason.decode!(conn.resp_body)
    assert body["result"]["protocolVersion"] == "2025-06-18"

    notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

    conn =
      conn(:post, "/mcp", Jason.encode!(notification))
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 202
  end

  test "exit notification retires the HTTP session" do
    session_id = initialize_session()

    conn =
      conn(:post, "/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "method" => "exit"}))
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 202

    wait_until(fn ->
      SessionRegistry.lookup(session_id, Auth.owner_for(@token)) ==
        {:error, :not_found}
    end)

    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => "tools/list", "id" => 2})
      )
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 404
  end

  test "JSON-RPC response POST validates protocol version" do
    session_id = initialize_session()

    conn =
      conn(:post, "/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => "r", "result" => %{}}))
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "1999-01-01")
      |> call()

    assert conn.status == 400
  end

  test "POST rejects supported protocol version different from negotiated session" do
    session_id = initialize_session("2025-06-18")

    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "v", "method" => "tools/list"})
      )
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> call()

    assert conn.status == 400
    assert conn.resp_body == "bad MCP-Protocol-Version"
  end

  test "invalid initialize does not allocate a session" do
    conn =
      conn(:post, "/mcp", Jason.encode!(%{"id" => 1, "method" => "initialize"}))
      |> auth()
      |> call()

    assert conn.status == 200
    assert get_resp_header(conn, "mcp-session-id") == []
    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_600
    refute SessionRegistry.saturated?()
  end

  @tag max_sessions: 0
  test "initialize capacity errors echo the request id" do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "cap", "method" => "initialize"})
      )
      |> auth()
      |> call()

    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["id"] == "cap"
  end

  test "malformed POST mappings are deterministic" do
    assert (conn(:post, "/mcp", "") |> auth() |> call()).status == 400

    conn = conn(:post, "/mcp", "not-json") |> auth() |> call()
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_700

    conn = conn(:post, "/mcp", "[]") |> auth() |> call()
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_600
  end

  test "DELETE closes a session" do
    session_id = initialize_session()
    {:ok, meta} = SessionRegistry.lookup(session_id, Auth.owner_for(@token))
    ref = Process.monitor(meta.pid)

    conn =
      conn(:delete, "/mcp")
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 202
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000

    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      )
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 404
  end

  test "loopback bind rejects hostile Host on DELETE" do
    conn =
      conn(:delete, "/mcp")
      |> auth()
      |> with_host("attacker.example")
      |> call()

    assert conn.status == 403
    assert conn.resp_body == "forbidden"
  end

  test "deleted owner index allows same owner to initialize again" do
    first_id = initialize_session()

    conn =
      conn(:delete, "/mcp")
      |> auth()
      |> put_req_header("mcp-session-id", first_id)
      |> call()

    assert conn.status == 202

    second_id = initialize_session()
    assert second_id != first_id
  end

  test "draining registry makes ready and POST return 503 JSON-RPC error" do
    assert :ok = SessionRegistry.begin_drain()

    ready = call(conn(:get, "/ready"))
    assert ready.status == 503
    assert Jason.decode!(ready.resp_body)["status"] == "draining"

    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "during-drain", "method" => "initialize"})
      )
      |> auth()
      |> call()

    assert conn.status == 503
    body = Jason.decode!(conn.resp_body)
    assert body["id"] == "during-drain"
    assert body["error"]["message"] == "server draining"
  end

  test "drain waits for explicit cancellation rather than cancelling immediately" do
    session_id = initialize_session()
    {:ok, meta} = SessionRegistry.lookup(session_id, Auth.owner_for(@token))

    call = %{
      "jsonrpc" => "2.0",
      "id" => "slow",
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_eval",
        "arguments" => %{"program" => long_running_program(), "context" => %{}}
      }
    }

    parent = self()

    task =
      Task.async(fn ->
        conn =
          conn(:post, "/mcp", Jason.encode!(call))
          |> auth()
          |> put_req_header("mcp-session-id", session_id)
          |> call()

        send(parent, {:slow_done, conn.status, Jason.decode!(conn.resp_body)})
      end)

    wait_until(fn -> map_size(:sys.get_state(meta.pid).in_flight) == 1 end)
    assert :ok = SessionRegistry.begin_drain()

    refute_receive {:slow_done, _, _}, 30
    assert :ok = SessionRegistry.cancel_all(:shutdown)
    assert_receive {:slow_done, 200, body}, 1_000
    assert get_in(body, ["result", "structuredContent", "reason"]) == "cancelled"

    Task.await(task, 1_000)
  end

  test "session crash is monitored without taking down registry" do
    session_id = initialize_session()
    {:ok, meta} = SessionRegistry.lookup(session_id, Auth.owner_for(@token))

    registry = Process.whereis(SessionRegistry)
    ref = Process.monitor(meta.pid)
    Process.exit(meta.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}, 1_000

    assert Process.alive?(registry)

    wait_until(fn ->
      SessionRegistry.lookup(session_id, Auth.owner_for(@token)) ==
        {:error, :not_found}
    end)

    _new_session_id = initialize_session()
  end

  test "worker-tracked permit is released after hard session kill" do
    session_id = initialize_session()
    {:ok, meta} = SessionRegistry.lookup(session_id, Auth.owner_for(@token))

    call = %{
      "jsonrpc" => "2.0",
      "id" => "hard-kill",
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_eval",
        "arguments" => %{"program" => long_running_program(), "context" => %{}}
      }
    }

    task =
      Task.async(fn ->
        conn(:post, "/mcp", Jason.encode!(call))
        |> auth()
        |> put_req_header("mcp-session-id", session_id)
        |> call()
      end)

    wait_until(fn -> map_size(:sys.get_state(meta.pid).in_flight) == 1 end)
    [%{pid: worker_pid}] = :sys.get_state(meta.pid).in_flight |> Map.values()
    assert ConcurrencyGate.in_flight() == 1

    session_ref = Process.monitor(meta.pid)
    Process.exit(meta.pid, :kill)
    assert_receive {:DOWN, ^session_ref, :process, _pid, :killed}, 1_000

    worker_ref = Process.monitor(worker_pid)
    Process.exit(worker_pid, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, :killed}, 1_000

    wait_until(fn -> ConcurrencyGate.in_flight() == 0 end)
    Task.shutdown(task, :brutal_kill)
  end

  test "stopping registry stops live sessions" do
    session_id = initialize_session()
    {:ok, meta} = SessionRegistry.lookup(session_id, Auth.owner_for(@token))
    ref = Process.monitor(meta.pid)

    assert :ok = stop_supervised(SessionRegistry)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 1_000
  end

  test "stopping registry closes PTC-Lisp sessions owned by HTTP sessions" do
    start_ptc_sessions!()
    session_id = initialize_session()

    start_call = %{
      "jsonrpc" => "2.0",
      "id" => "start-owned-session",
      "method" => "tools/call",
      "params" => %{"name" => "lisp_session_start", "arguments" => %{}}
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(start_call))
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert get_in(body, ["result", "structuredContent", "status"]) == "ok"

    owner = Owner.http(session_id)
    assert [_] = Registry.list(owner)

    assert :ok = stop_supervised(SessionRegistry)

    wait_until(fn -> Registry.list(owner) == [] end)
  end

  test "client disconnect cancels in-flight HTTP work and releases permit" do
    session_id = initialize_session()
    {:ok, meta} = SessionRegistry.lookup(session_id, Auth.owner_for(@token))

    call = %{
      "jsonrpc" => "2.0",
      "id" => "disconnect",
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_eval",
        "arguments" => %{"program" => long_running_program(), "context" => %{}}
      }
    }

    task =
      Task.async(fn ->
        conn(:post, "/mcp", Jason.encode!(call))
        |> auth()
        |> put_req_header("mcp-session-id", session_id)
        |> call()
      end)

    wait_until(fn -> map_size(:sys.get_state(meta.pid).in_flight) == 1 end)
    assert ConcurrencyGate.in_flight() == 1

    Task.shutdown(task, :brutal_kill)

    wait_until(fn ->
      map_size(:sys.get_state(meta.pid).in_flight) == 0 and ConcurrencyGate.in_flight() == 0
    end)
  end

  test "session tools use transport owner even when client supplies owner" do
    start_ptc_sessions!()
    session_id = initialize_session()

    start_call = %{
      "jsonrpc" => "2.0",
      "id" => "start",
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_session_start",
        "arguments" => %{"owner" => %{"transport" => "stdio", "instance_id" => "forged"}}
      }
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(start_call))
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 200
    start_body = Jason.decode!(conn.resp_body)
    assert get_in(start_body, ["result", "structuredContent", "status"]) == "ok"

    list_call = %{
      "jsonrpc" => "2.0",
      "id" => "list",
      "method" => "tools/call",
      "params" => %{
        "name" => "lisp_session_list",
        "arguments" => %{"owner" => %{"transport" => "stdio", "instance_id" => "forged"}}
      }
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(list_call))
      |> auth()
      |> put_req_header("mcp-session-id", session_id)
      |> call()

    assert conn.status == 200
    list_body = Jason.decode!(conn.resp_body)
    assert [%{"session_id" => _}] = get_in(list_body, ["result", "structuredContent", "sessions"])
  end

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

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp call(%{host: host} = conn) when host in ["example.com", "www.example.com"],
    do: conn |> with_host("127.0.0.1") |> Router.call([])

  defp call(conn), do: Router.call(conn, [])

  defp with_host(conn, host), do: %{conn | host: host, port: 7332}

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

  defp initialize_session(protocol_version \\ nil) do
    params =
      case protocol_version do
        nil -> %{}
        version -> %{"protocolVersion" => version}
      end

    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => "i",
          "method" => "initialize",
          "params" => params
        })
      )
      |> auth()
      |> call()

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    session_id
  end

  defp start_ptc_sessions! do
    McpTestHelpers.stop_existing_registry(Registry)
    McpTestHelpers.stop_existing_registry(Supervisor)
    McpTestHelpers.stop_existing_registry(Names)

    cfg = %{SessionsConfig.defaults() | enabled: true}
    SessionsConfig.set(cfg)

    Enum.each(PtcRunnerMcp.Sessions.child_specs(), &start_supervised!/1)
  end

  defp read_jsonl(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp long_running_program do
    "((fn ack [m n] " <>
      "(cond (= m 0) (+ n 1) " <>
      "(= n 0) (ack (- m 1) 1) " <>
      ":else (ack (- m 1) (ack m (- n 1))))) 3 8)"
  end
end
