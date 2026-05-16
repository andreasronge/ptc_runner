defmodule PtcRunnerMcp.Http.Router do
  @moduledoc false

  use Plug.Router

  alias PtcRunnerMcp.Http.{Auth, Origin, Session, SessionRegistry, Telemetry}
  alias PtcRunnerMcp.{JsonRpc, Limits, Log, Version}

  plug(:match)
  plug(:instrument_request)
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
      conn =
        put_http_private(conn,
          owner_hash: owner.hash,
          session_hash: Telemetry.hash_id(session_id)
        )

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
      if registry_draining?() do
        json(conn, 503, server_error(frame_id(decoded), "server draining"))
      else
        handle_post(conn, cfg, owner, decoded)
      end
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
            conn = put_session_private(conn, owner, meta)

            case Session.request(meta.pid, frame, request_context(conn, owner, meta)) do
              {:reply, reply} ->
                conn
                |> Plug.Conn.put_resp_header("mcp-session-id", meta.id)
                |> json(200, reply)

              :accepted ->
                Plug.Conn.send_resp(conn, 202, "")
            end

          {:error, :max_sessions_per_owner} ->
            conn = put_http_private(conn, owner_hash: owner.hash)
            json(conn, 429, server_error(id, "session owner limit exceeded"))

          {:error, _} ->
            conn = put_http_private(conn, owner_hash: owner.hash)
            json(conn, 503, server_error(id, "server saturated"))
        end
    end
  end

  defp handle_post(conn, _cfg, owner, %{"method" => _method} = frame) do
    with {:ok, session_id} <- session_id(conn),
         {:ok, meta} <- SessionRegistry.lookup(session_id, owner),
         :ok <- protocol_version_ok(conn, meta.protocol_version) do
      conn = put_session_private(conn, owner, meta)

      if Map.has_key?(frame, "id") do
        case Session.request(meta.pid, frame, request_context(conn, owner, meta)) do
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
      conn = put_session_private(conn, owner, meta)
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
        {:ok, owner} ->
          {:ok, owner}

        {:error, reason} ->
          Telemetry.emit([:auth, :failure], %{count: 1}, base_meta(conn, cfg, %{reason: reason}))
          {:error, {:auth, reason}}
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

      [_version | _] ->
        {:error, :bad_protocol_version}
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

  defp instrument_request(conn, _opts) do
    cfg = config(conn)
    request_id = request_id(conn)
    start = System.monotonic_time()

    conn =
      conn
      |> Plug.Conn.put_private(:ptc_http_request_id, request_id)
      |> Plug.Conn.put_private(:ptc_http_started_at, start)
      |> Plug.Conn.put_resp_header("x-request-id", request_id)

    Telemetry.emit([:request, :start], %{system_time: System.system_time()}, base_meta(conn, cfg))

    Plug.Conn.register_before_send(conn, fn conn ->
      duration = System.monotonic_time() - start
      duration_ms = System.convert_time_unit(duration, :native, :millisecond)

      metadata =
        base_meta(conn, cfg, %{status: conn.status, error_class: error_class(conn.status)})

      Telemetry.emit([:request, :stop], %{duration: duration}, metadata)

      Log.log(:info, "http_request_stop", %{
        request_id: request_id,
        instance: cfg.instance_label,
        method: conn.method,
        path: conn.request_path,
        status: conn.status,
        duration_ms: duration_ms,
        owner_hash: conn.private[:ptc_http_owner_hash],
        session_hash: conn.private[:ptc_http_session_hash],
        error_class: error_class(conn.status)
      })

      conn
    end)
  end

  defp put_session_private(conn, owner, meta) do
    put_http_private(conn,
      owner_hash: owner.hash,
      session_hash: Telemetry.hash_id(meta.id),
      protocol_version: meta.protocol_version
    )
  end

  defp put_http_private(conn, opts) do
    Enum.reduce(opts, conn, fn
      {:owner_hash, value}, acc ->
        Plug.Conn.put_private(acc, :ptc_http_owner_hash, value)

      {:session_hash, value}, acc ->
        Plug.Conn.put_private(acc, :ptc_http_session_hash, value)

      {:protocol_version, value}, acc ->
        Plug.Conn.put_private(acc, :ptc_http_protocol_version, value)
    end)
  end

  defp request_context(conn, owner, meta) do
    [
      transport: :http,
      transport_request_id: conn.private[:ptc_http_request_id],
      owner_hash: owner.hash,
      mcp_session_hash: Telemetry.hash_id(meta.id)
    ]
  end

  defp base_meta(conn, cfg, extra \\ %{}) do
    %{
      instance: cfg.instance_label,
      request_id: conn.private[:ptc_http_request_id],
      method: conn.method,
      path: conn.request_path,
      owner_hash: conn.private[:ptc_http_owner_hash],
      session_hash: conn.private[:ptc_http_session_hash]
    }
    |> Map.merge(extra)
  end

  defp frame_id(%{"id" => id}), do: id
  defp frame_id(_), do: nil

  defp error_class(status) when is_integer(status) and status >= 500, do: :server_error
  defp error_class(status) when is_integer(status) and status >= 400, do: :client_error
  defp error_class(_), do: nil

  defp request_id(conn) do
    case Plug.Conn.get_req_header(conn, "x-request-id") do
      [id | _] when byte_size(id) <= 128 -> id
      _ -> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    end
  end

  defp registry_down?, do: Process.whereis(SessionRegistry) == nil

  defp registry_draining? do
    Process.whereis(SessionRegistry) != nil and SessionRegistry.draining?()
  end

  defp config(conn),
    do: conn.private[:ptc_http_config] || Application.fetch_env!(:ptc_runner_mcp, :http_config)
end
