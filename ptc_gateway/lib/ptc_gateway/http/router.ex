defmodule PtcGateway.HTTP.Router do
  @moduledoc """
  Streamable HTTP front door for the MCP gateway.

  POST `/mcp` carries JSON-RPC. An absent `Origin` is allowed; a present
  `Origin` must exactly match the configured allowlist. `Host` must match the
  configured authority's host and port. `X-Forwarded-*` and `Forwarded` are
  ignored. `/health` is unauthenticated; `/ready` and `/mcp` require bearer
  authentication. `notifications/cancelled` is unsupported over HTTP.
  """

  use Plug.Router

  alias PtcGateway.Admission
  alias PtcGateway.HTTP.Auth
  alias PtcGateway.Protocol
  alias PtcGateway.RequestOwner

  plug(:match)
  plug(:dispatch)

  @impl Plug
  def call(conn, opts) when is_list(opts), do: call(conn, Map.new(opts))

  def call(conn, %{} = config) do
    token = Map.fetch!(config, :token)

    conn
    |> Plug.Conn.put_private(:ptc_gateway_token, token)
    |> Plug.Conn.assign(:gateway, Map.delete(config, :token))
    |> super(config)
    |> clear_token()
  end

  get "/health" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  get "/ready" do
    conn
    |> authenticate()
    |> respond_ready()
  end

  post "/mcp" do
    conn
    |> authenticate()
    |> dispatch_mcp()
  end

  match _ do
    send_json(conn, 404, %{"error" => "not found"})
  end

  defp authenticate(%Plug.Conn{halted: true} = conn), do: conn

  defp authenticate(conn) do
    with :ok <- origin(conn),
         :ok <- host(conn),
         :ok <- bearer(conn) do
      conn
    else
      {:error, status, body} ->
        conn
        |> send_json(status, body)
        |> Plug.Conn.halt()
    end
  end

  defp origin(conn) do
    allowlist = conn.assigns.gateway.origin_allowlist

    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        if origin in allowlist,
          do: :ok,
          else: {:error, 403, %{"error" => "origin rejected"}}

      _multiple ->
        {:error, 403, %{"error" => "origin rejected"}}
    end
  end

  defp host(conn) do
    {expected_host, expected_port} = conn.assigns.gateway.authority

    case Plug.Conn.get_req_header(conn, "host") do
      [header] ->
        case parse_host(header) do
          {:ok, ^expected_host, ^expected_port} ->
            :ok

          _other ->
            {:error, 403, %{"error" => "host rejected"}}
        end

      _other ->
        {:error, 403, %{"error" => "host rejected"}}
    end
  end

  defp parse_host("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [host, ":" <> port] -> parse_host_port(host, port)
      [host, ""] -> {:ok, host, 80}
      _other -> :error
    end
  end

  defp parse_host(header) when is_binary(header) do
    case String.split(header, ":", parts: 2) do
      [host, port] -> parse_host_port(host, port)
      [host] -> {:ok, host, 80}
    end
  end

  defp parse_host(_header), do: :error

  defp parse_host_port(host, port) when host != "" do
    case Integer.parse(port) do
      {int, ""} when int in 1..65_535 -> {:ok, host, int}
      _other -> :error
    end
  end

  defp parse_host_port(_host, _port), do: :error

  defp bearer(conn) do
    token = conn.private.ptc_gateway_token

    if is_binary(token) and Auth.authorized?(conn, token) do
      :ok
    else
      {:error, 401, %{"error" => "unauthorized"}}
    end
  end

  defp clear_token(conn) do
    %{conn | private: Map.delete(conn.private, :ptc_gateway_token)}
  end

  defp respond_ready(%Plug.Conn{halted: true} = conn), do: conn

  defp respond_ready(conn) do
    admission = conn.assigns.gateway.admission

    if is_pid(admission) and Process.alive?(admission) do
      send_json(conn, 200, %{"status" => "ready"})
    else
      send_json(conn, 503, %{"status" => "unready"})
    end
  end

  defp dispatch_mcp(%Plug.Conn{halted: true} = conn), do: conn

  defp dispatch_mcp(conn) do
    case Plug.Conn.read_body(conn, length: Protocol.max_frame_bytes()) do
      {:ok, body, conn} ->
        case Protocol.decode_line(body) do
          {:ok, inbound} -> handle_inbound(conn, inbound)
          {:error, kind} -> send_rpc(conn, Protocol.encode_rpc_error(nil, kind))
        end

      {:more, _partial, conn} ->
        send_rpc(conn, Protocol.encode_rpc_error(nil, :parse))

      {:error, _reason} ->
        send_rpc(conn, Protocol.encode_rpc_error(nil, :parse))
    end
  end

  defp handle_inbound(conn, {:notification, "notifications/cancelled", _params}) do
    send_json(conn, 400, %{"error" => "cancellation unsupported over HTTP"})
  end

  defp handle_inbound(conn, {:notification, _method, _params}) do
    send_json(conn, 202, %{})
  end

  defp handle_inbound(conn, {:request, id, "server/discover", _params}) do
    send_rpc(conn, Protocol.encode_result(id, Protocol.discover_result()))
  end

  defp handle_inbound(conn, {:request, id, "tools/list", _params}) do
    send_rpc(
      conn,
      Protocol.encode_result(id, Protocol.tools_list_result(conn.assigns.gateway.catalog))
    )
  end

  defp handle_inbound(conn, {:request, id, "tools/call", params}) do
    call_tool(conn, id, params)
  end

  defp handle_inbound(conn, {:request, id, _method, _params}) do
    send_rpc(conn, Protocol.encode_rpc_error(id, :method_not_found))
  end

  defp call_tool(conn, id, params) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})
    tools = conn.assigns.gateway.tools

    cond do
      not is_binary(name) or not is_map(arguments) or is_struct(arguments) ->
        send_rpc(conn, Protocol.encode_rpc_error(id, :invalid_params))

      not Map.has_key?(tools, name) ->
        send_rpc(conn, Protocol.encode_rpc_error(id, :unknown_tool))

      true ->
        admit_call(conn, id, Map.fetch!(tools, name), arguments)
    end
  end

  defp admit_call(conn, id, tool, arguments) do
    admission = conn.assigns.gateway.admission
    owner = RequestOwner.start(self(), admission, id, tool, arguments)

    case Admission.checkout(admission, owner) do
      :ok ->
        send(owner, :go)
        await_call(conn, owner, id)

      :saturated ->
        send(owner, :abort)
        send_rpc(conn, Protocol.encode_rpc_error(id, :admission))
    end
  end

  defp await_call(conn, owner, id) do
    receive do
      {:request_finished, ^owner, ^id, result} ->
        frame =
          case result do
            {:ok, value} when is_map(value) -> Protocol.encode_call_success(id, value)
            {:error, kind} when is_atom(kind) -> call_error_frame(id, kind)
            _other -> Protocol.encode_call_error(id, :execution)
          end

        send_rpc(conn, frame)
    end
  end

  defp call_error_frame(id, kind) do
    if PtcGateway.Errors.jsonrpc?(kind) do
      Protocol.encode_rpc_error(id, kind)
    else
      Protocol.encode_call_error(id, kind)
    end
  end

  defp send_rpc(conn, frame) do
    body = String.trim_trailing(frame, "\n")
    send_json(conn, 200, Jason.decode!(body))
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
