defmodule PtcRunnerMcp.HttpRouterTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias PtcRunnerMcp.Http.{Auth, Router, SessionRegistry}
  alias PtcRunnerMcp.Http.Config, as: HttpConfig
  alias PtcRunnerMcp.McpTestHelpers
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.{Names, Registry, Supervisor}

  @token String.duplicate("a", 32)

  setup context do
    McpTestHelpers.stop_existing_registry(SessionRegistry)
    {:ok, cfg} = HttpConfig.resolve(%{http: true, http_auth_token: @token})
    cfg = %{cfg | max_sessions: Map.get(context, :max_sessions, cfg.max_sessions)}
    Application.put_env(:ptc_runner_mcp, :http_config, cfg)
    start_supervised!({SessionRegistry, [config: cfg]})
    PtcRunnerMcp.ConcurrencyGate.init()
    on_exit(fn -> SessionsConfig.set(SessionsConfig.defaults()) end)
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

  test "session tools use transport owner even when client supplies owner" do
    start_ptc_sessions!()
    session_id = initialize_session()

    start_call = %{
      "jsonrpc" => "2.0",
      "id" => "start",
      "method" => "tools/call",
      "params" => %{
        "name" => "ptc_session_start",
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
      "params" => %{"name" => "ptc_session_list", "arguments" => %{}}
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

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)
  defp call(conn), do: Router.call(conn, [])

  defp initialize_session do
    conn =
      conn(
        :post,
        "/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "i", "method" => "initialize"})
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

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        receive do
        after
          5 -> do_wait_until(fun, deadline)
        end
      end
    end
  end
end
