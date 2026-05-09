defmodule PtcRunnerMcp.Test.FakeHttpServer.Plug do
  @moduledoc false
  # Internal Plug for the FakeHttpServer fixture. Dispatches per
  # scenario (held by the controller agent).
  #
  # See `PtcRunnerMcp.Test.FakeHttpServer` for the scenario list and
  # `Plans/http-transport-credentials.md` §6 / §13.2 for the wire
  # format being emulated.

  @behaviour Plug

  import Plug.Conn

  alias PtcRunnerMcp.Test.FakeHttpServer

  @protocol_version "2025-06-18"
  @stream_chunk_payload :binary.copy("x", 2 * 1024)

  @impl Plug
  def init(%{controller: pid} = opts) when is_pid(pid), do: opts

  @impl Plug
  def call(conn, %{controller: controller}) do
    {:ok, body, conn} = read_full_body(conn)

    decoded =
      case Jason.decode(body) do
        {:ok, term} -> term
        _ -> nil
      end

    record = %{
      method: conn.method,
      path: conn.request_path,
      headers: conn.req_headers,
      body: body,
      decoded: decoded
    }

    :ok = FakeHttpServer.record_request(controller, record)

    %{scenario: scenario, opts: opts, session_id: session_id} =
      FakeHttpServer.snapshot(controller)

    dispatch(scenario, conn, decoded, %{
      controller: controller,
      session_id: session_id,
      opts: opts
    })
  end

  # Read the entire request body into memory. Bandit hands it to us
  # in chunks if it exceeds the read_length budget.
  defp read_full_body(conn, acc \\ <<>>) do
    case read_body(conn, length: 8 * 1024 * 1024, read_length: 1_000_000) do
      {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
      {:more, chunk, conn} -> read_full_body(conn, acc <> chunk)
      {:error, _} = err -> err
    end
  end

  # ───────── scenarios ─────────

  defp dispatch(:handshake_success, conn, decoded, ctx) do
    handle_2025_06_18(conn, decoded, ctx, fn ->
      json(conn, 200, success_tools_call_body(decoded), [])
    end)
  end

  defp dispatch(:handshake_malformed, conn, decoded, ctx) do
    case method(decoded) do
      "initialize" ->
        version =
          if Map.get(ctx.opts, :omit_protocol_version, false) do
            nil
          else
            Map.get(ctx.opts, :protocol_version, "1999-01-01")
          end

        result =
          %{
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "fake_http_server", "version" => "1.0"}
          }
          |> maybe_put("protocolVersion", version)

        json(conn, 200, %{"jsonrpc" => "2.0", "id" => id(decoded), "result" => result}, [
          {"mcp-session-id", ctx.session_id}
        ])

      _ ->
        json(conn, 200, %{"jsonrpc" => "2.0", "id" => id(decoded), "result" => %{}}, [])
    end
  end

  defp dispatch(:handshake_401, conn, _decoded, _ctx) do
    json(conn, 401, %{"error" => "unauthorized"}, [])
  end

  defp dispatch(:handshake_timeout, conn, _decoded, _ctx) do
    # Block forever — the test wraps the call with its own timeout.
    Process.sleep(:infinity)
    conn
  end

  defp dispatch(:no_session_id, conn, decoded, ctx) do
    handle_2025_06_18(conn, decoded, %{ctx | session_id: nil}, fn ->
      json(conn, 200, success_tools_call_body(decoded), [])
    end)
  end

  defp dispatch(:session_404_on_call, conn, decoded, ctx) do
    case method(decoded) do
      "tools/call" ->
        # Echo back the held session id so the impl can detect that
        # the 404 carries its own session id (i.e. session-loss).
        send_resp_with_headers(conn, 404, "session lost", [
          {"content-type", "text/plain"},
          {"mcp-session-id", ctx.session_id}
        ])

      _ ->
        handle_2025_06_18(conn, decoded, ctx, fn ->
          json(conn, 200, success_tools_call_body(decoded), [])
        end)
    end
  end

  defp dispatch(:notifications_returns_200, conn, decoded, ctx) do
    case method(decoded) do
      "initialize" ->
        json(conn, 200, initialize_result(decoded, @protocol_version), [
          {"mcp-session-id", ctx.session_id}
        ])

      "notifications/initialized" ->
        # Spec: MUST be 202. Return 200 to assert handshake rejection.
        json(conn, 200, %{"ok" => true}, [])

      _ ->
        json(conn, 200, %{"jsonrpc" => "2.0", "id" => id(decoded), "result" => %{}}, [])
    end
  end

  defp dispatch(:sse_response_single_message, conn, decoded, ctx) do
    handle_2025_06_18(conn, decoded, ctx, fn ->
      msg = %{
        "jsonrpc" => "2.0",
        "id" => id(decoded),
        "result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}
      }

      sse_one_event(conn, [msg])
    end)
  end

  defp dispatch(:sse_response_array_form, conn, decoded, ctx) do
    handle_2025_06_18(conn, decoded, ctx, fn ->
      messages = [
        %{"jsonrpc" => "2.0", "method" => "notifications/progress", "params" => %{"pct" => 50}},
        %{
          "jsonrpc" => "2.0",
          "id" => id(decoded),
          "result" => %{"content" => [%{"type" => "text", "text" => "ok"}]}
        }
      ]

      # Single SSE event whose data is a JSON ARRAY of messages —
      # the legacy/compat decode path.
      sse_one_event_array(conn, messages)
    end)
  end

  defp dispatch(:large_response_body, conn, decoded, ctx) do
    handle_2025_06_18(conn, decoded, ctx, fn ->
      # 4 MiB of payload — the impl's :max_response_bytes cap should
      # trip before this is fully buffered.
      blob = :binary.copy("x", 4 * 1024 * 1024)

      body = %{
        "jsonrpc" => "2.0",
        "id" => id(decoded),
        "result" => %{"content" => [%{"type" => "text", "text" => blob}]}
      }

      json(conn, 200, body, [])
    end)
  end

  defp dispatch(:large_sse_stream, conn, decoded, ctx) do
    handle_2025_06_18(conn, decoded, ctx, fn ->
      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_chunked(200)

      stream_chunks(conn)
    end)
  end

  defp dispatch(:server_error_5xx, conn, _decoded, _ctx) do
    send_resp_with_headers(conn, 503, ~s({"error":"unavailable"}), [
      {"content-type", "application/json"}
    ])
  end

  defp dispatch(:rate_limited_429, conn, _decoded, _ctx) do
    send_resp_with_headers(conn, 429, ~s({"error":"rate_limited"}), [
      {"content-type", "application/json"},
      {"retry-after", "1"}
    ])
  end

  defp dispatch(:tools_call_slow, conn, decoded, ctx) do
    handle_2025_06_18(conn, decoded, ctx, fn ->
      delay_ms = Map.get(ctx.opts, :delay_ms, 500)
      Process.sleep(delay_ms)
      json(conn, 200, success_tools_call_body(decoded), [])
    end)
  end

  defp dispatch(:tools_call_401, conn, decoded, ctx) do
    # Phase 3C (§4.3.1): post-handshake 401 on `tools/call` to drive
    # the auth-rotation abnormal-exit path. Handshake itself succeeds
    # so the impl reaches steady state; only the call gets rejected.
    case method(decoded) do
      "tools/call" ->
        send_resp_with_headers(conn, 401, ~s({"error":"unauthorized"}), [
          {"content-type", "application/json"}
        ])

      _ ->
        handle_2025_06_18(conn, decoded, ctx, fn ->
          json(conn, 200, success_tools_call_body(decoded), [])
        end)
    end
  end

  defp dispatch(:jsonrpc_error_4xx, conn, decoded, ctx) do
    case method(decoded) do
      "tools/call" ->
        body = %{
          "jsonrpc" => "2.0",
          "id" => id(decoded),
          "error" => %{"code" => -32_000, "message" => "tool failed"}
        }

        json(conn, 400, body, [])

      _ ->
        handle_2025_06_18(conn, decoded, ctx, fn ->
          json(conn, 200, success_tools_call_body(decoded), [])
        end)
    end
  end

  # ───────── 2025-06-18 happy-path handshake helper ─────────

  # Three-step handshake (initialize → notifications/initialized →
  # tools/list) plus tools/call fall-through. The `tools_call_fun`
  # zero-arity closure is invoked only when the request is a
  # `tools/call`, letting the caller customize that response.
  defp handle_2025_06_18(conn, decoded, ctx, tools_call_fun) do
    case method(decoded) do
      "initialize" ->
        headers =
          if ctx.session_id,
            do: [{"mcp-session-id", ctx.session_id}],
            else: []

        json(conn, 200, initialize_result(decoded, @protocol_version), headers)

      "notifications/initialized" ->
        # 2025-06-18 §6.2: notifications-only POST returns 202 with
        # no body.
        send_resp(conn, 202, "")

      "tools/list" ->
        tools = Map.get(ctx.opts, :toolset, [])

        body = %{
          "jsonrpc" => "2.0",
          "id" => id(decoded),
          "result" => %{"tools" => tools}
        }

        json(conn, 200, body, [])

      "tools/call" ->
        tools_call_fun.()

      _other ->
        body = %{
          "jsonrpc" => "2.0",
          "id" => id(decoded),
          "result" => %{}
        }

        json(conn, 200, body, [])
    end
  end

  defp initialize_result(decoded, version) do
    %{
      "jsonrpc" => "2.0",
      "id" => id(decoded),
      "result" => %{
        "protocolVersion" => version,
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "fake_http_server", "version" => "1.0"}
      }
    }
  end

  defp success_tools_call_body(decoded) do
    name =
      case decoded do
        %{"params" => %{"name" => n}} when is_binary(n) -> n
        _ -> "unknown"
      end

    %{
      "jsonrpc" => "2.0",
      "id" => id(decoded),
      "result" => %{
        "content" => [%{"type" => "text", "text" => "called #{name}"}]
      }
    }
  end

  defp method(%{"method" => m}) when is_binary(m), do: m
  defp method(_), do: nil

  defp id(%{"id" => id}), do: id
  defp id(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ───────── response writers ─────────

  defp json(conn, status, body, extra_headers) do
    payload = Jason.encode!(body)

    extra_headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_resp_header(acc, k, v) end)
    |> put_resp_header("content-type", "application/json")
    |> send_resp(status, payload)
  end

  defp send_resp_with_headers(conn, status, body, headers) do
    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_resp_header(acc, k, v) end)
    |> send_resp(status, body)
  end

  defp sse_one_event(conn, messages) when is_list(messages) do
    data_lines =
      Enum.map_join(messages, fn msg -> "data: " <> Jason.encode!(msg) <> "\n" end)

    body = data_lines <> "\n"

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, body)
  end

  defp sse_one_event_array(conn, messages) when is_list(messages) do
    body = "data: " <> Jason.encode!(messages) <> "\n\n"

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, body)
  end

  # 2 KiB chunk; loop forever, but bail out the moment a chunk send
  # fails (client closed the connection).
  defp stream_chunks(conn) do
    case chunk(conn, "data: " <> @stream_chunk_payload <> "\n\n") do
      {:ok, conn} ->
        Process.sleep(10)
        stream_chunks(conn)

      {:error, _reason} ->
        conn
    end
  end
end
