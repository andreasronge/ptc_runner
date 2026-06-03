defmodule PtcRunner.UpstreamTransportFaultTest do
  # async: false — each test spins up a loopback TCP server on an ephemeral
  # port. The fixtures are self-contained (no named processes / global state),
  # but the target is declared async: false to stay conservative about the
  # spawned ports and Req's shared Finch pool.
  use ExUnit.Case, async: false

  alias PtcRunner.Upstream.Eval
  alias PtcRunner.Upstream.OpenAPI
  alias PtcRunner.Upstream.Runtime

  @schema Path.expand("../../mcp_server/test/fixtures/openapi/observatory.openapi.json", __DIR__)

  # Keep the fixture recv timeout well above the client call_timeout so a slow
  # client send never makes the loopback server give up mid-request.
  @fixture_recv_timeout_ms 15_000

  describe "McpHttp tools/call error -> recoverable reason mapping" do
    test "a JSON-RPC error envelope on tools/call maps to :upstream_error" do
      {:ok, server} =
        start_mcp_http_fixture(
          tool_call_response: fn socket, id, _args ->
            # A 200 OK carrying a JSON-RPC `error` member (NOT isError) is a
            # protocol-level failure; the transport must surface it as
            # :upstream_error with the server's message text.
            json_rpc_error(socket, id, %{"code" => -32_001, "message" => "boom from server"})
          end
        )

      {:ok, runtime} = Runtime.start_link(config: mcp_http_config(server))

      try do
        {{:ok, step}, records} = run_echo(runtime)

        assert step.return.ok == false
        assert step.return.reason == :upstream_error
        assert step.return.message =~ "boom from server"

        assert [%{"status" => "error", "reason" => "upstream_error"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "HTTP 401 on tools/call maps to :auth_failed" do
      {:ok, server} =
        start_mcp_http_fixture(
          tool_call_response: fn socket, _id, _args ->
            raw_http_response(socket, "401 Unauthorized", "nope")
          end
        )

      {:ok, runtime} = Runtime.start_link(config: mcp_http_config(server))

      try do
        {{:ok, step}, records} = run_echo(runtime)

        assert step.return.ok == false
        assert step.return.reason == :auth_failed
        assert [%{"status" => "error", "reason" => "auth_failed"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "HTTP 429 on tools/call maps to :rate_limited" do
      {:ok, server} =
        start_mcp_http_fixture(
          tool_call_response: fn socket, _id, _args ->
            raw_http_response(socket, "429 Too Many Requests", "slow down")
          end
        )

      {:ok, runtime} = Runtime.start_link(config: mcp_http_config(server))

      try do
        {{:ok, step}, records} = run_echo(runtime)

        assert step.return.ok == false
        assert step.return.reason == :rate_limited
        assert [%{"status" => "error", "reason" => "rate_limited"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "HTTP 5xx on tools/call maps to :upstream_unavailable" do
      # NOTE: do_post maps status >= 500 to :upstream_unavailable (the upstream
      # is presumed transiently down), distinct from the generic non-2xx
      # :upstream_error bucket. Assert the actual source contract.
      {:ok, server} =
        start_mcp_http_fixture(
          tool_call_response: fn socket, _id, _args ->
            raw_http_response(socket, "503 Service Unavailable", "down")
          end
        )

      {:ok, runtime} = Runtime.start_link(config: mcp_http_config(server))

      try do
        {{:ok, step}, records} = run_echo(runtime)

        assert step.return.ok == false
        assert step.return.reason == :upstream_unavailable
        assert step.return.message =~ "http 503"
        assert [%{"status" => "error", "reason" => "upstream_unavailable"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "a generic non-2xx (4xx other than 401/429) maps to :upstream_error" do
      {:ok, server} =
        start_mcp_http_fixture(
          tool_call_response: fn socket, _id, _args ->
            raw_http_response(socket, "418 I'm a teapot", "short and stout")
          end
        )

      {:ok, runtime} = Runtime.start_link(config: mcp_http_config(server))

      try do
        {{:ok, step}, records} = run_echo(runtime)

        assert step.return.ok == false
        assert step.return.reason == :upstream_error
        assert step.return.message =~ "http 418"
        assert [%{"status" => "error", "reason" => "upstream_error"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "an oversized 2xx body on tools/call maps to :response_too_large" do
      {:ok, server} =
        start_mcp_http_fixture(
          tool_call_response: fn socket, id, _args ->
            # A success envelope whose encoded body far exceeds the per-run byte
            # cap must be halted by the streaming collector and surfaced as a
            # recoverable :response_too_large, never buffered whole.
            big = %{"structuredContent" => %{"blob" => String.duplicate("x", 4_000)}}
            json_response(socket, id, big)
          end
        )

      {:ok, runtime} = Runtime.start_link(config: mcp_http_config(server))

      try do
        {{:ok, step}, records} =
          Eval.run_lisp_with_records(runtime, echo_program(), max_response_bytes: 64)

        assert step.return.ok == false
        assert step.return.reason == :response_too_large

        assert [%{"status" => "error", "reason" => "response_too_large", "oversize" => true}] =
                 records
      after
        Runtime.stop(runtime)
      end
    end

    test "a non-JSON 2xx body on tools/call maps to :upstream_error" do
      {:ok, server} =
        start_mcp_http_fixture(
          tool_call_response: fn socket, _id, _args ->
            # 200 OK with content-type application/json but a body that is not
            # valid JSON: the decode failure must surface as :upstream_error,
            # not crash the transport GenServer.
            raw_http_response(socket, "200 OK", "this is not json", "application/json")
          end
        )

      {:ok, runtime} = Runtime.start_link(config: mcp_http_config(server))

      try do
        {{:ok, step}, records} = run_echo(runtime)

        assert step.return.ok == false
        assert step.return.reason == :upstream_error
        assert step.return.message =~ "invalid JSON response"
        assert [%{"status" => "error", "reason" => "upstream_error"}] = records
      after
        Runtime.stop(runtime)
      end
    end
  end

  describe "McpHttp handshake fault -> upstream stays unloaded" do
    test "a non-202 notifications/initialized response aborts the handshake (catalog_loaded false)" do
      parent = self()

      {:ok, server} =
        start_mcp_http_fixture(
          notify_response: fn socket ->
            # The MCP spec requires 202 Accepted for the notification POST. A
            # 200 here is a handshake violation that must abort init() rather
            # than be treated as success.
            send(parent, :served_notify)
            raw_http_response(socket, "200 OK", "")
          end
        )

      {:ok, runtime} = Runtime.start_link(config: mcp_http_config(server))

      try do
        # In :live snapshot mode the client is started lazily here; the failed
        # handshake leaves the upstream unloaded instead of crashing the runtime.
        assert [%{"name" => "fixture", "catalog_loaded" => false, "tool_count" => 0}] =
                 Runtime.catalog_snapshot(runtime)

        assert_receive :served_notify, 1_000
      after
        Runtime.stop(runtime)
      end
    end
  end

  describe "OpenAPI HTTP status -> reason mapping" do
    test "204 No Content maps to a nil-valued success" do
      {:ok, server} = start_openapi_fixture("", status: "204 No Content")
      runtime = start_openapi_runtime(server)

      try do
        {{:ok, step}, records} = run_list_traces(runtime)

        assert step.return == %{ok: true, value: nil, value_kind: :json}
        assert [%{"status" => "ok"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "400 Bad Request maps to :tool_error and slices the problem body" do
      {:ok, server} =
        start_openapi_fixture(~s({"error":"bad input"}), status: "400 Bad Request")

      runtime = start_openapi_runtime(server)

      try do
        {{:ok, step}, records} = run_list_traces(runtime)

        assert step.return.ok == false
        assert step.return.reason == :tool_error
        assert step.return.message =~ "bad input"
        assert [%{"status" => "error", "reason" => "tool_error"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "401 Unauthorized maps to :auth_failed" do
      {:ok, server} = start_openapi_fixture("", status: "401 Unauthorized")
      runtime = start_openapi_runtime(server)

      try do
        {{:ok, step}, records} = run_list_traces(runtime)

        assert step.return.ok == false
        assert step.return.reason == :auth_failed
        assert [%{"status" => "error", "reason" => "auth_failed"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "403 Forbidden maps to :tool_error" do
      {:ok, server} = start_openapi_fixture(~s({"detail":"forbidden"}), status: "403 Forbidden")
      runtime = start_openapi_runtime(server)

      try do
        {{:ok, step}, _records} = run_list_traces(runtime)

        assert step.return.ok == false
        assert step.return.reason == :tool_error
        assert step.return.message =~ "forbidden"
      after
        Runtime.stop(runtime)
      end
    end

    test "404 Not Found maps to :tool_error" do
      {:ok, server} = start_openapi_fixture(~s({"detail":"missing"}), status: "404 Not Found")
      runtime = start_openapi_runtime(server)

      try do
        {{:ok, step}, _records} = run_list_traces(runtime)

        assert step.return.ok == false
        assert step.return.reason == :tool_error
        assert step.return.message =~ "missing"
      after
        Runtime.stop(runtime)
      end
    end

    test "429 Too Many Requests maps to :rate_limited" do
      {:ok, server} =
        start_openapi_fixture(~s({"detail":"slow"}), status: "429 Too Many Requests")

      runtime = start_openapi_runtime(server)

      try do
        {{:ok, step}, records} = run_list_traces(runtime)

        assert step.return.ok == false
        assert step.return.reason == :rate_limited
        assert [%{"status" => "error", "reason" => "rate_limited"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "5xx maps to :upstream_unavailable" do
      {:ok, server} = start_openapi_fixture("", status: "500 Internal Server Error")
      runtime = start_openapi_runtime(server)

      try do
        {{:ok, step}, records} = run_list_traces(runtime)

        assert step.return.ok == false
        assert step.return.reason == :upstream_unavailable
        assert step.return.message =~ "http 500"
        assert [%{"status" => "error", "reason" => "upstream_unavailable"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "a malformed JSON body on a 2xx response maps to :upstream_error" do
      {:ok, server} = start_openapi_fixture("not-json-at-all", status: "200 OK")
      runtime = start_openapi_runtime(server)

      try do
        {{:ok, step}, records} = run_list_traces(runtime)

        assert step.return.ok == false
        assert step.return.reason == :upstream_error
        assert step.return.message =~ "malformed JSON response"
        assert [%{"status" => "error", "reason" => "upstream_error"}] = records
      after
        Runtime.stop(runtime)
      end
    end

    test "an unknown OpenAPI tool name maps to :upstream_error without a request" do
      # OpenAPI.call dispatches directly (no client/runtime needed); an unknown
      # operation must short-circuit to :upstream_error before any HTTP work.
      upstream = %{operations: %{}, config: %{base_url: "https://example.test"}}

      assert {:error, :upstream_error, message} =
               OpenAPI.call(upstream, "does-not-exist", %{}, [])

      assert message =~ "unknown OpenAPI tool 'does-not-exist'"
    end
  end

  describe "Runtime lifecycle and credential redaction" do
    test "child_spec/0 builds a worker spec wired to start_supervised" do
      spec = Runtime.child_spec(config: config(), id: :fault_runtime)

      assert %{id: :fault_runtime, type: :worker, start: {Runtime, :start_supervised, [opts]}} =
               spec

      assert Keyword.get(opts, :id) == :fault_runtime
    end

    test "child_spec/0 defaults its id to the module" do
      spec = Runtime.child_spec(config: config())
      assert spec.id == Runtime
    end

    test "stop/1 on a dead pid is a no-op (does not raise)" do
      {:ok, runtime} = Runtime.start_link(config: config())
      pid = runtime.pid
      ref = Process.monitor(pid)

      Runtime.stop(runtime)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      # Stopping an already-dead pid must swallow the exit and return :ok.
      assert :ok = Runtime.stop(pid)
      assert :ok = Runtime.stop(runtime)
    end

    test "stop/1 on an unregistered name is a no-op" do
      refute Process.whereis(:fault_runtime_absent_name)
      assert :ok = Runtime.stop(:fault_runtime_absent_name)
    end

    test "an upstream error path scrubs credential material from step.return and records" do
      secret = "fault-openapi-secret"
      {:ok, server} = start_openapi_fixture(~s({"error":"#{secret}"}), status: "400 Bad Request")

      config =
        config(base_url: server.base_url, allow_insecure_http: true)
        |> Map.put("credentials", %{
          "observatory-token" => %{
            "source" => "literal",
            "value" => secret,
            "scheme_hint" => "bearer"
          }
        })
        |> put_in(["upstreams", "observatory", "allow_insecure_auth"], true)
        |> put_in(["upstreams", "observatory", "auth"], [
          %{"scheme" => "bearer", "binding" => "observatory-token"}
        ])

      {:ok, runtime} = Runtime.start_link(config: config)

      try do
        {{:ok, step}, records} = run_list_traces(runtime)

        # The 400 body echoes the bearer secret; both the program-visible message
        # and the diagnostics record must be redacted on the error path.
        assert step.return.ok == false
        assert step.return.reason == :tool_error
        refute step.return.message =~ secret
        assert step.return.message =~ "[REDACTED]"
        refute inspect(records) =~ secret
      after
        Runtime.stop(runtime)
      end
    end
  end

  # ---- shared run helpers -------------------------------------------------

  defp echo_program, do: ~S|(tool/call 'fixture/echo {:message "hello"})|

  defp run_echo(runtime), do: Eval.run_lisp_with_records(runtime, echo_program())

  defp list_traces_program,
    do: ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme"}})|

  defp run_list_traces(runtime), do: Eval.run_lisp_with_records(runtime, list_traces_program())

  defp mcp_http_config(server) do
    %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true
        }
      }
    }
  end

  defp config(opts \\ []) do
    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => Keyword.get(opts, :base_url, "https://observatory.example"),
          "schema_file" => @schema,
          "include_operations" => Keyword.get(opts, :operations, ["list_traces"]),
          "allow_insecure_http" => Keyword.get(opts, :allow_insecure_http, false)
        }
      }
    }
  end

  defp start_openapi_runtime(server) do
    {:ok, runtime} =
      Runtime.start_link(config: config(base_url: server.base_url, allow_insecure_http: true))

    runtime
  end

  # ---- OpenAPI loopback fixture (single GET) ------------------------------

  defp start_openapi_fixture(body, opts) do
    parent = self()
    status_line = Keyword.fetch!(opts, :status)

    {:ok, listen_socket} = tcp_listen()
    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn(fn ->
        case :gen_tcp.accept(listen_socket) do
          {:ok, socket} ->
            {:ok, request} = :gen_tcp.recv(socket, 0, @fixture_recv_timeout_ms)
            send(parent, {:http_fixture_request, request})

            response = [
              "HTTP/1.1 #{status_line}\r\n",
              "content-type: application/json\r\n",
              "content-length: #{byte_size(body)}\r\n",
              "connection: close\r\n",
              "\r\n",
              body
            ]

            :gen_tcp.send(socket, response)
            :gen_tcp.close(socket)

          _ ->
            :ok
        end

        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, base_url: "http://127.0.0.1:#{port}"}}
  end

  # ---- MCP HTTP loopback fixture (handshake + tools/call) -----------------

  defp start_mcp_http_fixture(opts) do
    parent = self()
    {:ok, listen_socket} = tcp_listen()
    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn(fn ->
        serve_mcp_http(parent, listen_socket, 4, opts)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, url: "http://127.0.0.1:#{port}/mcp"}}
  end

  defp serve_mcp_http(_parent, _listen_socket, 0, _opts), do: :ok

  defp serve_mcp_http(parent, listen_socket, remaining, opts) do
    case :gen_tcp.accept(listen_socket, @fixture_recv_timeout_ms) do
      {:ok, socket} ->
        {:ok, request} = read_http_request(socket)
        method = get_in(request, [:decoded, "method"])
        send(parent, {:mcp_http_fixture_request, method})
        send_mcp_http_response(socket, request.decoded, opts)
        :gen_tcp.close(socket)
        serve_mcp_http(parent, listen_socket, remaining - 1, opts)

      _ ->
        :ok
    end
  end

  defp send_mcp_http_response(socket, %{"method" => "notifications/initialized"}, opts) do
    case Keyword.get(opts, :notify_response) do
      fun when is_function(fun, 1) ->
        fun.(socket)

      nil ->
        :gen_tcp.send(socket, [
          "HTTP/1.1 202 Accepted\r\n",
          "mcp-session-id: fault-test-session\r\n",
          "content-length: 0\r\n",
          "connection: close\r\n\r\n"
        ])
    end
  end

  defp send_mcp_http_response(socket, %{"id" => id, "method" => "initialize"}, _opts) do
    json_response(socket, id, %{"protocolVersion" => "2025-06-18", "capabilities" => %{}},
      session?: true
    )
  end

  defp send_mcp_http_response(socket, %{"id" => id, "method" => "tools/list"}, _opts) do
    json_response(socket, id, %{
      "tools" => [
        %{
          "name" => "echo",
          "description" => "Echo arguments",
          "inputSchema" => %{"type" => "object"}
        }
      ]
    })
  end

  defp send_mcp_http_response(socket, %{"id" => id, "method" => "tools/call"} = frame, opts) do
    args = get_in(frame, ["params", "arguments"]) || %{}

    case Keyword.get(opts, :tool_call_response) do
      fun when is_function(fun, 3) -> fun.(socket, id, args)
      nil -> json_response(socket, id, %{"structuredContent" => %{"echo" => args}})
    end
  end

  # ---- low-level wire helpers ---------------------------------------------

  defp tcp_listen do
    :gen_tcp.listen(0, [
      :binary,
      packet: :raw,
      active: false,
      reuseaddr: true,
      ip: {127, 0, 0, 1}
    ])
  end

  defp read_http_request(socket) do
    {:ok, head} = read_until(socket, "\r\n\r\n", "")
    [header_text, rest] = String.split(head, "\r\n\r\n", parts: 2)
    [_request_line | header_lines] = String.split(header_text, "\r\n")

    headers =
      Enum.map(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.trim(key), String.trim(value)}
      end)

    content_length =
      headers
      |> Enum.find_value("0", fn {key, value} ->
        if String.downcase(key) == "content-length", do: value
      end)
      |> String.to_integer()

    body = read_body(socket, rest, content_length)
    {:ok, %{headers: headers, body: body, decoded: Jason.decode!(body)}}
  end

  defp read_until(socket, marker, acc) do
    if String.contains?(acc, marker) do
      {:ok, acc}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, @fixture_recv_timeout_ms)
      read_until(socket, marker, acc <> chunk)
    end
  end

  defp read_body(_socket, buffered, length) when byte_size(buffered) >= length do
    binary_part(buffered, 0, length)
  end

  defp read_body(socket, buffered, length) do
    {:ok, chunk} = :gen_tcp.recv(socket, length - byte_size(buffered), @fixture_recv_timeout_ms)
    read_body(socket, buffered <> chunk, length)
  end

  defp json_response(socket, id, result, opts \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    send_http_json(socket, "200 OK", body, opts)
  end

  defp json_rpc_error(socket, id, error) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "error" => error})
    send_http_json(socket, "200 OK", body, [])
  end

  defp send_http_json(socket, status_line, body, opts) do
    session_header =
      if Keyword.get(opts, :session?, false),
        do: "mcp-session-id: fault-test-session\r\n",
        else: ""

    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status_line}\r\n",
      "content-type: application/json\r\n",
      session_header,
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ])
  end

  defp raw_http_response(socket, status_line, body, content_type \\ "text/plain") do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status_line}\r\n",
      "content-type: #{content_type}\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ])
  end
end
