defmodule PtcRunnerMcp.Http.Router do
  @moduledoc false

  use Plug.Router

  alias PtcRunnerMcp.Http.{Auth, Origin, Session, SessionRegistry}
  alias PtcRunnerMcp.{JsonRpc, Limits, Version}

  plug(:match)
  plug(:dispatch)

  get "/health" do
    json(conn, 200, %{"status" => "ok"})
  end

  get "/ready" do
    cfg = config(conn)

    cond do
      registry_down?() ->
        json(conn, 503, %{"status" => "draining"})

      SessionRegistry.draining?() ->
        json(conn, 503, %{"status" => "draining"})

      SessionRegistry.saturated?() ->
        json(conn, 503, %{"status" => "saturated"})

      true ->
        json(conn, 200, %{"status" => "ready", "instance" => cfg.instance_label})
    end
  end

  match _ do
    cfg = config(conn)
    request_id = request_id(conn)
    conn = Plug.Conn.put_resp_header(conn, "x-request-id", request_id)

    if conn.request_path == cfg.path do
      route_mcp(conn, cfg)
    else
      Plug.Conn.send_resp(conn, 404, "not found")
    end
  end

  defp route_mcp(%{method: "GET"} = conn, _cfg) do
    conn
    |> Plug.Conn.put_resp_header("allow", "POST, DELETE")
    |> Plug.Conn.send_resp(405, "")
  end

  defp route_mcp(%{method: "DELETE"} = conn, cfg) do
    with {:ok, owner} <- authenticate(conn, cfg),
         {:ok, session_id} <- session_id(conn) do
      case SessionRegistry.delete(session_id, owner) do
        :ok -> Plug.Conn.send_resp(conn, 202, "")
        {:error, :not_found} -> Plug.Conn.send_resp(conn, 404, "")
      end
    else
      {:error, {:auth, reason}} -> auth_error(conn, reason)
      {:error, :missing_session} -> Plug.Conn.send_resp(conn, 400, "missing MCP-Session-Id")
      {:error, :origin} -> Plug.Conn.send_resp(conn, 403, "forbidden")
    end
  end

  defp route_mcp(%{method: "POST"} = conn, cfg) do
    with {:ok, owner} <- authenticate(conn, cfg),
         {:ok, body, conn} <- read_body_capped(conn, cfg),
         {:ok, decoded} <- decode_body(body) do
      handle_post(conn, cfg, owner, decoded)
    else
      {:error, {:auth, reason}} ->
        auth_error(conn, reason)

      {:error, :origin} ->
        Plug.Conn.send_resp(conn, 403, "forbidden")

      {:error, :empty_body} ->
        Plug.Conn.send_resp(conn, 400, "empty body")

      {:error, :too_large} ->
        Plug.Conn.send_resp(conn, 413, "payload too large")

      {:error, :parse_error} ->
        json(conn, 200, JsonRpc.dispatch({:error, :parse_error}) |> elem(1))
    end
  end

  defp route_mcp(conn, _cfg) do
    conn
    |> Plug.Conn.put_resp_header("allow", "POST, DELETE")
    |> Plug.Conn.send_resp(405, "")
  end

  defp handle_post(
         conn,
         _cfg,
         owner,
         %{"method" => "initialize", "id" => id} = frame
       ) do
    cond do
      has_session_id?(conn) ->
        Plug.Conn.send_resp(conn, 400, "initialize must not include MCP-Session-Id")

      Map.get(frame, "jsonrpc") != "2.0" ->
        json(conn, 200, invalid_request_reply(nil))

      true ->
        params = Map.get(frame, "params")
        protocol_version = negotiate(params)

        case SessionRegistry.create(owner, protocol_version) do
          {:ok, meta} ->
            case Session.request(meta.pid, frame) do
              {:reply, reply} ->
                conn
                |> Plug.Conn.put_resp_header("mcp-session-id", meta.id)
                |> json(200, reply)

              :accepted ->
                Plug.Conn.send_resp(conn, 202, "")
            end

          {:error, :max_sessions_per_owner} ->
            json(conn, 429, server_error(id, "session owner limit exceeded"))

          {:error, _} ->
            json(conn, 503, server_error(id, "server saturated"))
        end
    end
  end

  defp handle_post(conn, _cfg, owner, %{"method" => _method} = frame) do
    with {:ok, session_id} <- session_id(conn),
         {:ok, meta} <- SessionRegistry.lookup(session_id, owner),
         :ok <- protocol_version_ok(conn, meta.protocol_version) do
      if Map.has_key?(frame, "id") do
        case Session.request(meta.pid, frame) do
          {:reply, reply} ->
            json(conn, 200, reply)

          :accepted ->
            await_reply(conn, meta.pid, Map.get(frame, "id"), worker_await_timeout_ms(frame))
        end
      else
        _ = Session.notify_or_response(meta.pid, frame)
        Plug.Conn.send_resp(conn, 202, "")
      end
    else
      {:error, :missing_session} ->
        Plug.Conn.send_resp(conn, 400, "missing MCP-Session-Id")

      {:error, :not_found} ->
        Plug.Conn.send_resp(conn, 404, "")

      {:error, :bad_protocol_version} ->
        Plug.Conn.send_resp(conn, 400, "bad MCP-Protocol-Version")
    end
  end

  defp handle_post(conn, _cfg, owner, %{"id" => _, "result" => _} = frame),
    do: handle_response(conn, owner, frame)

  defp handle_post(conn, _cfg, owner, %{"id" => _, "error" => _} = frame),
    do: handle_response(conn, owner, frame)

  defp handle_post(conn, _cfg, _owner, _decoded) do
    json(conn, 200, invalid_request_reply(nil))
  end

  defp handle_response(conn, owner, frame) do
    with {:ok, session_id} <- session_id(conn),
         {:ok, meta} <- SessionRegistry.lookup(session_id, owner),
         :ok <- protocol_version_ok(conn, meta.protocol_version) do
      _ = Session.notify_or_response(meta.pid, frame)
      Plug.Conn.send_resp(conn, 202, "")
    else
      {:error, :missing_session} ->
        Plug.Conn.send_resp(conn, 400, "missing MCP-Session-Id")

      {:error, :not_found} ->
        Plug.Conn.send_resp(conn, 404, "")

      {:error, :bad_protocol_version} ->
        Plug.Conn.send_resp(conn, 400, "bad MCP-Protocol-Version")
    end
  end

  defp await_reply(conn, session_pid, id, timeout_ms) do
    receive do
      {:ptc_http_reply, ^id, reply} -> json(conn, 200, reply)
    after
      timeout_ms ->
        _ = Session.cancel(session_pid, id, :await_timeout)
        json(conn, 200, server_error(id, "request timed out"))
    end
  end

  defp authenticate(conn, cfg) do
    if Origin.allowed?(conn, cfg) do
      case Auth.authenticate(conn, cfg) do
        {:ok, owner} -> {:ok, owner}
        {:error, reason} -> {:error, {:auth, reason}}
      end
    else
      {:error, :origin}
    end
  end

  defp auth_error(conn, reason) do
    {status, header} = Auth.challenge(reason)

    conn
    |> Plug.Conn.put_resp_header("www-authenticate", header)
    |> Plug.Conn.send_resp(status, "")
  end

  defp read_body_capped(conn, cfg) do
    case Plug.Conn.read_body(conn,
           length: cfg.max_body_bytes,
           read_length: min(cfg.max_body_bytes, 1_000_000)
         ) do
      {:ok, "", _conn} -> {:error, :empty_body}
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :too_large}
      {:error, _} -> {:error, :parse_error}
    end
  end

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _} -> {:ok, :invalid_request}
      {:error, _} -> {:error, :parse_error}
    end
  end

  defp session_id(conn) do
    case Plug.Conn.get_req_header(conn, "mcp-session-id") do
      [id | _] when id != "" -> {:ok, id}
      _ -> {:error, :missing_session}
    end
  end

  defp has_session_id?(conn), do: match?({:ok, _}, session_id(conn))

  defp protocol_version_ok(conn, negotiated) do
    case Plug.Conn.get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [^negotiated | _] ->
        :ok

      [version | _] ->
        if version in Version.supported(), do: :ok, else: {:error, :bad_protocol_version}
    end
  end

  defp negotiate(params) do
    requested =
      case params do
        %{"protocolVersion" => version} when is_binary(version) -> version
        _ -> nil
      end

    Version.negotiate(requested)
  end

  defp worker_await_timeout_ms(%{"params" => %{"name" => "ptc_task"}}),
    do: PtcRunnerMcp.AgenticConfig.get().task_timeout_ms + 1_000

  defp worker_await_timeout_ms(_frame), do: Limits.program_timeout_ms() + 1_000

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp server_error(id, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32_000, "message" => message}}
  end

  defp invalid_request_reply(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_600, "message" => "Invalid Request"}
    }
  end

  defp request_id(conn) do
    case Plug.Conn.get_req_header(conn, "x-request-id") do
      [id | _] when byte_size(id) <= 128 -> id
      _ -> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    end
  end

  defp registry_down?, do: Process.whereis(SessionRegistry) == nil

  defp config(conn),
    do: conn.private[:ptc_http_config] || Application.fetch_env!(:ptc_runner_mcp, :http_config)
end
