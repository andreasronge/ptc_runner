defmodule PtcRunnerMcp.Http.RouterDispatchTest do
  use PtcRunnerMcp.Http.RouterCase

  alias PtcRunnerMcp.ConcurrencyGate
  alias PtcRunnerMcp.Http.Auth
  alias PtcRunnerMcp.Http.SessionRegistry
  alias PtcRunnerMcp.McpTestHelpers
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.{Names, Owner, Registry, Supervisor}

  test "authenticated GET /mcp returns 405 with Allow" do
    conn = call(auth(conn(:get, "/mcp")))
    assert conn.status == 405
    assert get_resp_header(conn, "allow") == ["POST, DELETE"]
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

    wait_until(fn -> map_size(:sys.get_state(meta.pid).in_flight) == 1 end, 5_000)
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

    wait_until(fn -> map_size(:sys.get_state(meta.pid).in_flight) == 1 end, 5_000)
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

    wait_until(fn -> map_size(:sys.get_state(meta.pid).in_flight) == 1 end, 5_000)
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

  defp start_ptc_sessions! do
    McpTestHelpers.stop_existing_registry(Registry)
    McpTestHelpers.stop_existing_registry(Supervisor)
    McpTestHelpers.stop_existing_registry(Names)

    cfg = %{SessionsConfig.defaults() | enabled: true}
    SessionsConfig.set(cfg)

    Enum.each(PtcRunnerMcp.Sessions.child_specs(), &start_supervised!/1)
  end

  defp long_running_program do
    "((fn ack [m n] " <>
      "(cond (= m 0) (+ n 1) " <>
      "(= n 0) (ack (- m 1) 1) " <>
      ":else (ack (- m 1) (ack m (- n 1))))) 3 8)"
  end
end
