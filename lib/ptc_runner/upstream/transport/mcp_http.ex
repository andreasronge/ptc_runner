defmodule PtcRunner.Upstream.Transport.McpHttp do
  @moduledoc false

  @behaviour PtcRunner.Upstream.Transport

  use GenServer

  alias PtcRunner.Upstream.Credentials
  alias PtcRunner.Upstream.ResponseCap
  alias PtcRunner.Upstream.Transport
  alias PtcRunner.Upstream.Transport.McpHttp.SseDecoder
  alias PtcRunner.Upstream.Transport.McpResult

  @protocol_version "2025-06-18"

  @spec start_link(String.t(), map()) :: GenServer.on_start()
  def start_link(name, config), do: Transport.start_trapped(__MODULE__, name, config)

  @impl PtcRunner.Upstream.Transport
  def list_tools(%{client_pid: pid}) when is_pid(pid),
    do: GenServer.call(pid, :list_tools, 30_000)

  @impl PtcRunner.Upstream.Transport
  def call(%{client_pid: pid}, tool_name, args, opts) when is_pid(pid) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    max_bytes = Keyword.get(opts, :max_response_bytes, 2 * 1024 * 1024)
    GenServer.call(pid, {:call_tool, tool_name, args, timeout, max_bytes}, timeout + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout, "mcp_http call timed out"}
    :exit, _ -> {:error, :upstream_unavailable, "mcp_http client exited"}
  end

  @impl GenServer
  def init({name, config}) do
    with :ok <- ensure_req_loaded(),
         {:ok, state} <- initialize(%{name: name, config: config, next_id: 1, session_id: nil}) do
      {:ok, state}
    else
      {:error, reason, detail} -> {:stop, {reason, detail}}
    end
  end

  @impl GenServer
  def handle_call(:list_tools, _from, state), do: {:reply, {:ok, state.tools}, state}

  def handle_call({:call_tool, tool_name, args, timeout, max_bytes}, _from, state) do
    case request(
           state,
           "tools/call",
           %{"name" => tool_name, "arguments" => args},
           timeout,
           max_bytes
         ) do
      {:ok, result, state} -> {:reply, McpResult.normalize(result), state}
      {:error, reason, detail, state} -> {:reply, {:error, reason, detail}, state}
    end
  end

  defp initialize(state) do
    timeout = state.config.handshake_timeout_ms
    max_bytes = state.config.max_response_bytes

    with {:ok, _init, state} <-
           request(
             state,
             "initialize",
             %{
               "protocolVersion" => @protocol_version,
               "capabilities" => %{},
               "clientInfo" => %{"name" => "ptc_runner", "version" => "0.x"}
             },
             timeout,
             max_bytes
           ),
         {:ok, state} <- notify_initialized(state, timeout, max_bytes),
         {:ok, %{"tools" => tools}, state} <-
           request(state, "tools/list", %{}, timeout, max_bytes) do
      {:ok, Map.put(state, :tools, tools)}
    else
      {:ok, other, state} ->
        {:error, :upstream_error,
         "tools/list returned unexpected payload #{inspect(other, limit: 20)}", state}

      {:error, reason, detail, _state} ->
        {:error, reason, detail}
    end
  end

  defp request(state, method, params, timeout, max_bytes) do
    id = state.next_id
    body = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    case post(state, body, timeout, max_bytes) do
      {:ok, %{body: %{"id" => ^id, "result" => result}} = response} ->
        {:ok, result, update_session(%{state | next_id: id + 1}, response.headers)}

      {:ok, %{body: %{"id" => ^id, "error" => error}} = response} ->
        {:error, :upstream_error, error_message(error),
         update_session(%{state | next_id: id + 1}, response.headers)}

      {:ok, %{body: body} = response} ->
        {:error, :upstream_error, "unexpected JSON-RPC response #{inspect(body, limit: 20)}",
         update_session(%{state | next_id: id + 1}, response.headers)}

      {:error, reason, detail} ->
        {:error, reason, detail, state}
    end
  end

  defp notify_initialized(state, timeout, max_bytes) do
    body = %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}

    case post(state, body, timeout, max_bytes) do
      {:ok, %{status: 202} = response} ->
        {:ok, update_session(state, response.headers)}

      {:ok, %{status: status}} ->
        {:error, :upstream_error, "notifications/initialized returned http #{status}", state}

      {:error, reason, detail} ->
        {:error, reason, detail, state}
    end
  end

  defp post(state, body, timeout, max_bytes) do
    request_id = Map.get(body, "id")
    encoded = Jason.encode!(body)

    with {:ok, headers} <- request_headers(state) do
      headers =
        headers ++
          [
            {"content-type", "application/json"},
            {"accept", "application/json, text/event-stream"}
          ]

      opts = [
        url: state.config.url,
        method: :post,
        headers: headers,
        body: encoded,
        receive_timeout: min(timeout, state.config.request_timeout_ms),
        connect_options: [timeout: state.config.connect_timeout_ms],
        retry: false,
        decode_body: false,
        into: ResponseCap.collector(max_bytes)
      ]

      do_post(opts, max_bytes, request_id)
    end
  end

  defp do_post(opts, max_bytes, request_id) do
    case Req.request(opts) do
      {:ok, %{status: 202, headers: headers}} ->
        {:ok, %{status: 202, headers: normalize_headers(headers), body: nil}}

      {:ok, %{status: status, headers: headers} = resp} when status in 200..299 ->
        {body, overflow?} = ResponseCap.extract_body(resp)
        headers = normalize_headers(headers)

        cond do
          overflow? ->
            {:error, :response_too_large, "mcp_http response exceeded #{max_bytes} bytes"}

          sse_response?(headers) ->
            decode_sse_response(status, headers, body, request_id, max_bytes)

          true ->
            decode_json_response(status, headers, body)
        end

      {:ok, %{status: 401}} ->
        {:error, :auth_failed, "auth_failed"}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited, "rate_limited"}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, :upstream_unavailable, "http #{status}"}

      {:ok, %{status: status}} ->
        {:error, :upstream_error, "http #{status}"}

      {:error, %Req.TransportError{} = error} ->
        {:error, :upstream_unavailable, Exception.message(error)}

      {:error, error} when is_exception(error) ->
        {:error, :upstream_unavailable, Exception.message(error)}
    end
  end

  defp decode_json_response(status, headers, body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{status: status, headers: headers, body: decoded}}
      {:error, reason} -> {:error, :upstream_error, "invalid JSON response: #{inspect(reason)}"}
    end
  end

  defp decode_sse_response(status, headers, body, request_id, max_bytes) do
    case SseDecoder.decode_binary(body, request_id: request_id, max_bytes: max_bytes) do
      {:ok, decoded} -> {:ok, %{status: status, headers: headers, body: decoded}}
      {:error, reason, detail} -> {:error, reason, detail}
    end
  end

  defp sse_response?(headers) do
    headers
    |> Map.get("content-type", "")
    |> String.downcase()
    |> String.contains?("text/event-stream")
  end

  defp request_headers(state) do
    session_headers =
      if state.session_id do
        [{"mcp-session-id", state.session_id}]
      else
        []
      end

    with {:ok, auth_headers} <-
           Credentials.headers(state.config.credentials, Map.get(state.config, :auth, [])) do
      {:ok,
       [{"mcp-protocol-version", @protocol_version} | state.config.static_headers] ++
         auth_headers ++ session_headers}
    end
  end

  defp update_session(state, headers) do
    case Map.get(headers, "mcp-session-id") do
      nil -> state
      session_id -> %{state | session_id: session_id}
    end
  end

  defp normalize_headers(headers) do
    Enum.reduce(headers, %{}, fn {key, values}, acc ->
      value = if is_list(values), do: List.first(values), else: values
      Map.put(acc, String.downcase(to_string(key)), to_string(value))
    end)
  end

  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error), do: inspect(error, limit: 20, printable_limit: 200)

  defp ensure_req_loaded do
    if Code.ensure_loaded?(Req),
      do: :ok,
      else: {:error, :upstream_unavailable, "req library not loaded"}
  end
end
