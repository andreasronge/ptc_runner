defmodule PtcGateway.MCP do
  @moduledoc "Strict, stateless MCP 2026-07-28 discovery and static listing boundary."
  @behaviour Plug
  import Plug.Conn
  alias PtcRunner.Kernel.{DeterministicJSON, StrictJSON, WarmProviderRuntime}

  @revision "2026-07-28"
  @body_limit 2_097_152
  @response_limit 4_194_304
  @safe_integer 9_007_199_254_740_991
  @critical ~w(host origin authorization content-type accept mcp-protocol-version mcp-method mcp-name)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    with :ok <- valid_method(conn),
         :ok <- bounded_headers(conn),
         :ok <- valid_authority(conn, opts),
         :ok <- valid_origin(conn, opts),
         :ok <- authenticated(conn, opts),
         :ok <- valid_content_type(conn),
         :ok <- valid_accept(conn),
         {:ok, body, conn} <- read_bounded_body(conn),
         {:ok, request} <- decode(body, conn),
         {:ok, id, method, params} <- envelope(request, conn),
         :ok <- valid_metadata(conn, id, method, params),
         {:ok, result} <- dispatch(conn, id, method, params, opts) do
      json_reply(conn, 200, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
    else
      {:fixed, conn, status, value, headers} ->
        fixed_reply(conn, status, value, headers)

      {:rpc, conn, status, code, message, id, data} ->
        rpc_error(conn, status, code, message, id, data)
    end
  rescue
    _ -> rpc_error(conn, 500, -32603, "Internal error", nil, nil)
  catch
    _, _ -> rpc_error(conn, 500, -32603, "Internal error", nil, nil)
  end

  defp valid_method(%{method: "POST"}), do: :ok
  defp valid_method(conn), do: {:fixed, conn, 405, "method_not_allowed", [{"allow", "POST"}]}

  defp bounded_headers(conn) do
    duplicate? = Enum.any?(@critical, &(length(get_req_header(conn, &1)) > 1))

    bytes =
      Enum.reduce(conn.req_headers, 0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value) + 4
      end)

    if length(conn.req_headers) <= 64 and bytes <= 32_768 and not duplicate?,
      do: :ok,
      else: {:fixed, conn, 431, "request_headers_too_large", []}
  end

  defp valid_authority(conn, opts) do
    if PtcGateway.Policy.valid_authority?(conn, opts[:listen]),
      do: :ok,
      else: {:fixed, conn, 400, "invalid_authority", []}
  end

  defp valid_origin(conn, opts) do
    if PtcGateway.Policy.allowed_origin?(conn, opts[:listen]),
      do: :ok,
      else: {:fixed, conn, 403, "origin_forbidden", []}
  end

  defp authenticated(conn, opts) do
    valid? =
      case get_req_header(conn, "authorization") do
        [value] ->
          case Regex.run(~r/^([^ \t]+)[ \t]+([^ \t]+)$/u, value, capture: :all_but_first) do
            [scheme, token] ->
              String.downcase(scheme) == "bearer" and
                WarmProviderRuntime.authenticate(opts[:warm], token)

            _ ->
              false
          end

        _ ->
          false
      end

    if valid?,
      do: :ok,
      else: {:fixed, conn, 401, "unauthorized", [{"www-authenticate", "Bearer"}]}
  end

  defp valid_content_type(conn) do
    valid? =
      case get_req_header(conn, "content-type") do
        [value] ->
          Regex.match?(
            ~r/^application\/json(?:[ \t]*;[ \t]*charset[ \t]*=[ \t]*(?:utf-8|"utf-8"))?$/iu,
            value
          )

        _ ->
          false
      end

    if valid?, do: :ok, else: {:fixed, conn, 415, "unsupported_media_type", []}
  end

  defp valid_accept(conn) do
    valid? =
      case get_req_header(conn, "accept") do
        [value] ->
          accepts?(value, "application", "json") and accepts?(value, "text", "event-stream")

        _ ->
          false
      end

    if valid?, do: :ok, else: {:fixed, conn, 406, "not_acceptable", []}
  end

  defp accepts?(header, wanted_type, wanted_subtype) do
    header
    |> String.split(",")
    |> Enum.any?(fn range ->
      [media | params] = String.split(range, ";")

      case String.split(String.trim(media), "/", parts: 2) do
        [type, subtype] ->
          type = String.downcase(type)
          subtype = String.downcase(subtype)
          quality = Enum.find_value(params, 1.0, &quality/1)
          quality > 0 and type in ["*", wanted_type] and subtype in ["*", wanted_subtype]

        _ ->
          false
      end
    end)
  end

  defp quality(param) do
    case String.split(String.trim(param), "=", parts: 2) do
      [name, value] when name in ["q", "Q"] ->
        case Float.parse(value) do
          {quality, ""} when quality >= 0 and quality <= 1 -> quality
          _ -> -1.0
        end

      _ ->
        nil
    end
  end

  defp read_bounded_body(conn) do
    case read_body(conn, length: @body_limit + 1, read_length: 64_000) do
      {:ok, body, conn} when byte_size(body) <= @body_limit -> {:ok, body, conn}
      {:ok, _body, conn} -> {:fixed, conn, 413, "request_too_large", []}
      {:more, _body, conn} -> {:fixed, conn, 413, "request_too_large", []}
      {:error, _reason} -> {:rpc, conn, 500, -32603, "Internal error", nil, nil}
    end
  end

  defp decode(body, conn) do
    case StrictJSON.decode(body, max_depth: 64, max_nodes: 100_000) do
      {:ok, value} -> {:ok, value}
      _ -> {:rpc, conn, 400, -32700, "Parse error", nil, nil}
    end
  end

  defp envelope(
         %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params} = request,
         conn
       )
       when map_size(request) == 4 and is_binary(method) and is_map(params) do
    if valid_id?(id), do: {:ok, id, method, params}, else: invalid_envelope(conn, nil)
  end

  defp envelope(request, conn) when is_map(request),
    do: invalid_envelope(conn, valid_id(request["id"]))

  defp envelope(_request, conn), do: invalid_envelope(conn, nil)
  defp invalid_envelope(conn, id), do: {:rpc, conn, 400, -32600, "Invalid Request", id, nil}

  defp valid_id?(id) when is_binary(id), do: byte_size(id) in 1..256 and String.valid?(id)
  defp valid_id?(id) when is_integer(id), do: id in -@safe_integer..@safe_integer
  defp valid_id?(_id), do: false
  defp valid_id(id), do: if(valid_id?(id), do: id)

  defp valid_metadata(conn, id, method, params) do
    meta = params["_meta"]
    version = is_map(meta) && meta["io.modelcontextprotocol/protocolVersion"]
    capabilities = is_map(meta) && meta["io.modelcontextprotocol/clientCapabilities"]

    cond do
      not is_map(meta) or not is_binary(version) or not is_map(capabilities) or
        not valid_client_info?(meta) or encoded_size(meta) > 65_536 ->
        {:rpc, conn, 200, -32602, "Invalid Params", id, nil}

      single(conn, "mcp-protocol-version") != version or single(conn, "mcp-method") != method or
          get_req_header(conn, "mcp-name") != [] ->
        {:rpc, conn, 400, -32020, "Header mismatch", id, nil}

      version != @revision ->
        {:rpc, conn, 400, -32022, "Unsupported protocol version", id,
         %{"requested" => version, "supported" => [@revision]}}

      true ->
        :ok
    end
  end

  defp valid_client_info?(meta) do
    case Map.fetch(meta, "io.modelcontextprotocol/clientInfo") do
      :error -> true
      {:ok, %{"name" => name, "version" => version}} -> is_binary(name) and is_binary(version)
      _ -> false
    end
  end

  defp single(conn, header) do
    case get_req_header(conn, header) do
      [value] -> value
      _ -> nil
    end
  end

  defp dispatch(conn, id, "server/discover", params, _opts) do
    if Map.keys(params) == ["_meta"] do
      {:ok,
       %{
         "resultType" => "complete",
         "supportedVersions" => [@revision],
         "capabilities" => %{"tools" => %{"listChanged" => false}},
         "ttlMs" => 0,
         "cacheScope" => "private"
       }}
    else
      {:rpc, conn, 200, -32602, "Invalid Params", id, nil}
    end
  end

  defp dispatch(conn, id, "tools/list", params, opts) do
    if not WarmProviderRuntime.snapshot(opts[:warm]).ready do
      {:rpc, conn, 503, -32002, "Server unavailable", id, nil}
    else
      list_tools(conn, id, params, opts)
    end
  end

  defp dispatch(conn, id, _method, _params, _opts),
    do: {:rpc, conn, 404, -32601, "Method not found", id, nil}

  defp list_tools(conn, id, params, opts) do
    if Map.keys(params) == ["_meta"] do
      {:ok,
       %{
         "resultType" => "complete",
         "tools" => opts[:tools],
         "ttlMs" => 0,
         "cacheScope" => "private"
       }}
    else
      {:rpc, conn, 200, -32602, "Invalid Params", id, nil}
    end
  end

  defp encoded_size(value) do
    case DeterministicJSON.encode(value) do
      {:ok, body} -> byte_size(body)
      _ -> @response_limit + 1
    end
  end

  defp fixed_reply(conn, status, value, headers) do
    headers
    |> Enum.reduce(conn, fn {name, header_value}, acc ->
      put_resp_header(acc, name, header_value)
    end)
    |> json_reply(status, %{"error" => value})
  end

  defp rpc_error(conn, status, code, message, id, data) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    response = %{"jsonrpc" => "2.0", "error" => error}
    response = if is_nil(id), do: response, else: Map.put(response, "id", id)
    json_reply(conn, status, response)
  end

  defp json_reply(conn, status, value) do
    case DeterministicJSON.encode(value) do
      {:ok, body} when byte_size(body) <= @response_limit ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(status, body)

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(
          500,
          ~s({"error":{"code":-32603,"message":"Internal error"},"jsonrpc":"2.0"})
        )
    end
  end
end
