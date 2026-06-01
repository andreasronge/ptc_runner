defmodule PtcRunner.UpstreamRuntimeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Upstream.Credentials
  alias PtcRunner.Upstream.RunContext
  alias PtcRunner.Upstream.Runtime

  @schema Path.expand("../../mcp_server/test/fixtures/openapi/observatory.openapi.json", __DIR__)

  # The hand-rolled TCP fixtures read requests with a bounded recv timeout. Keep
  # it well above the client's `call_timeout_ms` (5s) so that under heavy parallel
  # test load a slow client send never makes the fixture give up mid-request and
  # crash on the `{:ok, chunk} =` match (which surfaced as a flaky empty step).
  @fixture_recv_timeout_ms 15_000

  test "starts a root runtime from OpenAPI config and exposes discovery" do
    {:ok, runtime} = Runtime.start_link(config: config())

    try do
      assert [%{"name" => "observatory", "tool_count" => 2}] = Runtime.catalog_snapshot(runtime)

      assert {:ok, step} = Runtime.run_lisp(runtime, "(tool/servers)")
      assert [%{"name" => "observatory", "tool_count" => 2}] = step.return

      assert {:ok, dir_step} = Runtime.run_lisp(runtime, "(dir 'observatory)")
      assert Enum.any?(dir_step.return, &String.contains?(&1, "observatory/list-traces"))

      assert {:ok, doc_step} = Runtime.run_lisp(runtime, "(doc 'observatory/list-traces)")
      assert doc_step.return =~ "observatory/list-traces"
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp creates fresh per-run tool counters and drains records" do
    {:ok, runtime} = Runtime.start_link(config: config())

    program = ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme"}})|

    try do
      {{:ok, first}, first_records} =
        Runtime.run_lisp_with_records(runtime, program, max_tool_calls: 0)

      {{:ok, second}, second_records} =
        Runtime.run_lisp_with_records(runtime, program, max_tool_calls: 0)

      assert first.return == %{ok: false, reason: :cap_exhausted, message: "cap_exhausted"}
      assert second.return == first.return

      assert [%{"status" => "error", "reason" => "cap_exhausted"}] = first_records
      assert [%{"status" => "error", "reason" => "cap_exhausted"}] = second_records

      refute_received {:upstream_call_recorded, _ref, _entry}
    after
      Runtime.stop(runtime)
    end
  end

  test "tool/call accepts qualified symbol form" do
    {:ok, runtime} = Runtime.start_link(config: config())

    program = ~S|(tool/call 'observatory/list-traces {:org_id "acme"})|

    try do
      {{:ok, step}, records} =
        Runtime.run_lisp_with_records(runtime, program, max_tool_calls: 0)

      assert step.return == %{ok: false, reason: :cap_exhausted, message: "cap_exhausted"}
      assert [%{"server" => "observatory", "tool" => "list-traces"}] = records
    after
      Runtime.stop(runtime)
    end
  end

  test "run_lisp executes OpenAPI tool calls and drains success records" do
    {:ok, server} =
      start_http_fixture(%{
        "traces" => [
          %{"id" => "trace-1", "org_id" => "acme"}
        ]
      })

    {:ok, runtime} =
      Runtime.start_link(config: config(base_url: server.base_url, allow_insecure_http: true))

    program =
      ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme" :limit 1}})|

    try do
      {{:ok, step}, records} = Runtime.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"traces" => [%{"id" => "trace-1", "org_id" => "acme"}]},
               value_kind: :json
             }

      assert [
               %{
                 "server" => "observatory",
                 "tool" => "list-traces",
                 "status" => "ok",
                 "oversize" => false
               }
             ] = records

      assert_receive {:http_fixture_request, request}, 1_000
      assert request =~ "GET /api/v1/traces?"
      assert request =~ "org_id=acme"
      assert request =~ "limit=1"
    after
      Runtime.stop(runtime)
    end
  end

  test "root runtime can call an MCP stdio upstream" do
    script = write_stdio_fixture!()

    config = stdio_fixture_config(script)

    {:ok, runtime} = Runtime.start_link(config: config, catalog_snapshot_mode: :frozen)

    try do
      assert [%{"name" => "fixture", "tool_count" => 1}] = Runtime.catalog_snapshot(runtime)

      program = ~S|(tool/call 'fixture/echo {:message "hello"})|
      {{:ok, step}, records} = Runtime.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"echo" => %{"message" => "hello"}},
               value_kind: :json
             }

      assert [%{"server" => "fixture", "tool" => "echo", "status" => "ok"}] = records
    after
      Runtime.stop(runtime)
    end
  end

  test "run context drains all records from pmap tool calls" do
    script = write_stdio_fixture!()

    config = stdio_fixture_config(script)

    {:ok, runtime} = Runtime.start_link(config: config, catalog_snapshot_mode: :frozen)

    program =
      ~S|(pmap (fn [message] (tool/call 'fixture/echo {:message message})) ["a" "b" "c" "d"])|

    try do
      {{:ok, step}, records} = Runtime.run_lisp_with_records(runtime, program)

      assert Enum.map(step.return, &get_in(&1, [:value, "echo", "message"])) == [
               "a",
               "b",
               "c",
               "d"
             ]

      assert length(records) == 4
      assert records |> Enum.map(& &1["server"]) |> Enum.uniq() == ["fixture"]
      assert records |> Enum.map(& &1["tool"]) |> Enum.uniq() == ["echo"]
      assert records |> Enum.map(& &1["status"]) |> Enum.uniq() == ["ok"]

      assert records |> Enum.map(&get_in(&1, ["result_overview", "value_kind"])) |> Enum.uniq() ==
               ["json"]
    after
      Runtime.stop(runtime)
    end
  end

  test "root runtime can call an MCP HTTP upstream" do
    {:ok, server} = start_mcp_http_fixture()

    config = %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)

    try do
      assert [%{"name" => "fixture", "tool_count" => 1}] = Runtime.catalog_snapshot(runtime)

      program = ~S|(tool/call 'fixture/echo {:message "hello"})|
      {{:ok, step}, records} = Runtime.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"echo" => %{"message" => "hello"}},
               value_kind: :json
             }

      assert [%{"server" => "fixture", "tool" => "echo", "status" => "ok"}] = records

      assert_receive {:mcp_http_fixture_request, "initialize", _headers}, 1_000
      assert_receive {:mcp_http_fixture_request, "notifications/initialized", headers}, 1_000

      assert Enum.any?(headers, fn {key, value} ->
               String.downcase(key) == "mcp-session-id" and value == "root-test-session"
             end)

      assert_receive {:mcp_http_fixture_request, "tools/list", _headers}, 1_000
      assert_receive {:mcp_http_fixture_request, "tools/call", _headers}, 1_000
    after
      Runtime.stop(runtime)
    end
  end

  test "root MCP HTTP transport normalizes SSE tool responses" do
    {:ok, server} = start_mcp_http_fixture(sse?: true)

    config = %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)

    try do
      program = ~S|(tool/call 'fixture/echo {:message "hello"})|
      {{:ok, step}, records} = Runtime.run_lisp_with_records(runtime, program)

      assert step.return == %{
               ok: true,
               value: %{"echo" => %{"message" => "hello"}},
               value_kind: :json
             }

      assert [%{"server" => "fixture", "tool" => "echo", "status" => "ok"}] = records
    after
      Runtime.stop(runtime)
    end
  end

  test "root MCP HTTP transport applies credential-backed auth headers" do
    {:ok, server} = start_mcp_http_fixture()

    config = %{
      "credentials" => %{
        "fixture-token" => %{
          "source" => "literal",
          "value" => "http-secret",
          "scheme_hint" => "bearer"
        }
      },
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => server.url,
          "allow_insecure_http" => true,
          "allow_insecure_auth" => true,
          "auth" => [%{"scheme" => "bearer", "binding" => "fixture-token"}]
        }
      }
    }

    {:ok, runtime} = Runtime.start_link(config: config)

    try do
      assert Runtime.scrub(runtime, "Authorization: Bearer http-secret") ==
               "Authorization: Bearer [REDACTED]"

      assert [%{"name" => "fixture", "catalog_loaded" => true}] =
               Runtime.catalog_snapshot(runtime)

      assert_receive {:mcp_http_fixture_request, "initialize", headers}, 1_000

      assert Enum.any?(headers, fn {key, value} ->
               String.downcase(key) == "authorization" and value == "Bearer http-secret"
             end)
    after
      Runtime.stop(runtime)
    end
  end

  test "root credential emitters support bearer, basic, and custom headers" do
    {:ok, credentials} =
      Credentials.new(%{
        "bearer" => %{"source" => "literal", "value" => "token"},
        "basic" => %{"source" => "literal", "value" => ~s({"user":"u","pass":"p"})},
        "custom" => %{"source" => "literal", "value" => "api-secret"}
      })

    assert {:ok,
            [
              {"authorization", "Bearer token"},
              {"authorization", "Basic dTpw"},
              {"X-Api-Token", "api-secret"}
            ]} =
             Credentials.headers(credentials, [
               %{"scheme" => "bearer", "binding" => "bearer"},
               %{"scheme" => "basic", "binding" => "basic"},
               %{"scheme" => "custom_header", "binding" => "custom", "header" => "X-Api-Token"}
             ])

    assert {:error, :upstream_unavailable, message} =
             Credentials.headers(credentials, [
               %{"scheme" => "custom_header", "binding" => "custom", "header" => "Authorization"}
             ])

    assert message =~ "invalid custom auth header"
  end

  test "old MCP transport names are rejected in root config" do
    assert {:error, {:upstream_unavailable, message}} =
             Runtime.start_link(config: %{"upstreams" => %{"fs" => %{"transport" => "stdio"}}})

    assert message =~ "use mcp_stdio or mcp_http"
  end

  test "root config rejects insecure URLs and reserved static headers" do
    assert {:error, {:upstream_unavailable, insecure_message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "remote" => %{"transport" => "mcp_http", "url" => "http://example.test/mcp"}
                 }
               }
             )

    assert insecure_message =~ "allow_insecure_http"

    assert {:error, {:upstream_unavailable, header_message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "remote" => %{
                     "transport" => "mcp_http",
                     "url" => "https://example.test/mcp",
                     "static_headers" => %{"Authorization" => "Bearer nope"}
                   }
                 }
               }
             )

    assert header_message =~ "reserved"
  end

  test "root OpenAPI config requires exactly one schema source" do
    assert {:error, {:upstream_unavailable, missing_message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "observatory" => %{
                     "transport" => "openapi",
                     "base_url" => "https://observatory.example",
                     "include_operations" => ["list_traces"]
                   }
                 }
               }
             )

    assert missing_message =~ "exactly one"

    assert {:error, {:upstream_unavailable, duplicate_message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "observatory" => %{
                     "transport" => "openapi",
                     "base_url" => "https://observatory.example",
                     "schema_file" => @schema,
                     "schema_url" => "https://observatory.example/openapi.json",
                     "include_operations" => ["list_traces"]
                   }
                 }
               }
             )

    assert duplicate_message =~ "exactly one"
  end

  test "root config validates auth binding references at load time" do
    assert {:error, {:upstream_unavailable, message}} =
             Runtime.start_link(
               config: %{
                 "upstreams" => %{
                   "remote" => %{
                     "transport" => "mcp_http",
                     "url" => "https://example.test/mcp",
                     "auth" => [%{"scheme" => "bearer", "binding" => "missing-token"}]
                   }
                 }
               }
             )

    assert message =~ "unknown credential binding missing-token"
  end

  test "run context close stops the collector" do
    {:ok, runtime} = Runtime.start_link(config: config())

    try do
      {:ok, context} = Runtime.run_context(runtime)

      assert :ok = RunContext.close(context)
      refute Process.alive?(context.collector.pid)
      assert :ok = RunContext.close(context)
    after
      Runtime.stop(runtime)
    end
  end

  test "with_run_context closes the collector when callback raises" do
    {:ok, runtime} = Runtime.start_link(config: config())
    parent = self()

    try do
      assert_raise RuntimeError, "boom", fn ->
        Runtime.with_run_context(runtime, [], fn context ->
          send(parent, {:collector, context.collector.pid})
          raise "boom"
        end)
      end

      assert_receive {:collector, pid}
      refute Process.alive?(pid)
    after
      Runtime.stop(runtime)
    end
  end

  test "catalog text honors lazy exposure mode and diagnostics expose runtime facts" do
    {:ok, runtime} =
      Runtime.start_link(
        config: config(),
        catalog_exposure_mode: :lazy,
        catalog_snapshot_mode: :frozen
      )

    try do
      assert Runtime.catalog_text(runtime) == "observatory (2 tools)"

      assert %{
               upstreams: ["observatory"],
               catalog_exposure_mode: :lazy,
               catalog_snapshot_mode: :frozen,
               transports: %{"observatory" => :openapi}
             } = Runtime.diagnostics(runtime)
    after
      Runtime.stop(runtime)
    end
  end

  test "runtime redactor scope scrubs credential material from diagnostics terms" do
    {:ok, runtime} = Runtime.start_link(config: credential_config())

    try do
      secret = "root-runtime-secret"

      assert Runtime.scrub(runtime, "Bearer #{secret}") == "Bearer [REDACTED]"

      assert Runtime.scrub(runtime, %{
               "error" => "request included #{secret}",
               "nested" => ["token=#{secret}"]
             }) == %{
               "error" => "request included [REDACTED]",
               "nested" => ["token=[REDACTED]"]
             }
    after
      Runtime.stop(runtime)
    end
  end

  test "catalog and discovery outputs scrub credential material" do
    secret = "catalog-secret-token"

    {:ok, runtime} =
      Runtime.start_link(
        config:
          credential_config(secret)
          |> put_in(["upstreams", "observatory", "description"], "server #{secret}")
          |> put_in(["upstreams", "observatory", "operation_overrides"], %{})
          |> put_in(
            ["upstreams", "observatory", "operation_overrides", "list_traces"],
            %{"description" => "tool #{secret}"}
          )
      )

    try do
      catalog_text = Runtime.catalog_text(runtime)
      refute catalog_text =~ secret
      assert catalog_text =~ "[REDACTED]"

      assert {:ok, servers_step} = Runtime.run_lisp(runtime, "(tool/servers)")
      refute inspect(servers_step.return) =~ secret

      assert {:ok, dir_step} = Runtime.run_lisp(runtime, "(dir 'observatory)")
      refute inspect(dir_step.return) =~ secret

      assert {:ok, doc_step} = Runtime.run_lisp(runtime, "(doc 'observatory/list-traces)")
      refute doc_step.return =~ secret

      assert {:ok, meta_step} = Runtime.run_lisp(runtime, "(meta 'observatory/list-traces)")
      refute inspect(meta_step.return) =~ secret
    after
      Runtime.stop(runtime)
    end
  end

  test "discovery results enforce max_catalog_result_bytes" do
    {:ok, runtime} = Runtime.start_link(config: config())

    try do
      assert {:ok, step} =
               Runtime.run_lisp(runtime, "(dir 'observatory)", max_catalog_result_bytes: 10)

      assert step.return == nil

      assert [
               %{
                 operation: :dir,
                 outcome: :nil_world_fault,
                 reason: :catalog_result_too_large
               }
             ] = step.catalog_ops
    after
      Runtime.stop(runtime)
    end
  end

  test "live snapshot mode does not eagerly start unavailable MCP client upstreams" do
    config = %{
      "upstreams" => %{
        "missing" => %{
          "transport" => "mcp_stdio",
          "command" => "/definitely/not/a/real/command"
        }
      }
    }

    assert {:ok, runtime} = Runtime.start_link(config: config, catalog_snapshot_mode: :live)

    try do
      assert [
               %{
                 "name" => "missing",
                 "catalog_loaded" => false,
                 "tool_count" => 0,
                 "tools" => []
               }
             ] = Runtime.catalog_snapshot(runtime)
    after
      Runtime.stop(runtime)
    end
  end

  test "multiple root runtimes keep redaction scopes separate" do
    {:ok, runtime_a} = Runtime.start_link(config: credential_config("secret-a"))
    {:ok, runtime_b} = Runtime.start_link(config: credential_config("secret-b"))

    try do
      assert Runtime.scrub(runtime_a, "secret-a secret-b") == "[REDACTED] secret-b"
      assert Runtime.scrub(runtime_b, "secret-a secret-b") == "secret-a [REDACTED]"
    after
      Runtime.stop(runtime_a)
      Runtime.stop(runtime_b)
    end
  end

  defp config(opts \\ []) do
    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => Keyword.get(opts, :base_url, "https://observatory.example"),
          "schema_file" => @schema,
          "include_operations" => ["list_traces", "get_trace"],
          "allow_insecure_http" => Keyword.get(opts, :allow_insecure_http, false)
        }
      }
    }
  end

  defp credential_config(secret \\ "root-runtime-secret") do
    config()
    |> Map.put("credentials", %{
      "observatory-token" => %{
        "source" => "literal",
        "value" => secret,
        "scheme_hint" => "bearer"
      }
    })
    |> put_in(["upstreams", "observatory", "auth"], [
      %{"scheme" => "bearer", "binding" => "observatory-token"}
    ])
  end

  defp start_http_fixture(response_body) do
    parent = self()
    response_json = Jason.encode!(response_body)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, request} = :gen_tcp.recv(socket, 0, @fixture_recv_timeout_ms)
        send(parent, {:http_fixture_request, request})

        response = [
          "HTTP/1.1 200 OK\r\n",
          "content-type: application/json\r\n",
          "content-length: #{byte_size(response_json)}\r\n",
          "connection: close\r\n",
          "\r\n",
          response_json
        ]

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, base_url: "http://127.0.0.1:#{port}"}}
  end

  defp write_stdio_fixture! do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc_runner_mcp_stdio_fixture_#{System.unique_integer([:positive])}.exs"
      )

    File.write!(path, ~S'''
    tools = [
      %{
        "name" => "echo",
        "description" => "Echo arguments",
        "inputSchema" => %{"type" => "object", "properties" => %{"message" => %{"type" => "string"}}}
      }
    ]

    for line <- IO.stream(:stdio, :line) do
      {:ok, frame} = Jason.decode(String.trim(line))
      id = frame["id"]

      response =
        case frame["method"] do
          "initialize" ->
            %{"jsonrpc" => "2.0", "id" => id, "result" => %{"capabilities" => %{}}}

          "notifications/initialized" ->
            nil

          "tools/list" ->
            %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => tools}}

          "tools/call" ->
            args = get_in(frame, ["params", "arguments"]) || %{}
            %{"jsonrpc" => "2.0", "id" => id, "result" => %{"structuredContent" => %{"echo" => args}}}
        end

      if response do
        IO.puts(Jason.encode!(response))
      end
    end
    ''')

    path
  end

  defp stdio_fixture_config(script) do
    # Derive Jason's ebin from the loaded module rather than hard-coding
    # `_build/test/lib/jason/ebin`, so the spawned `elixir` finds Jason even
    # under a custom MIX_BUILD_PATH (where deps compile outside `_build/test`).
    jason_ebin = Jason |> :code.which() |> to_string() |> Path.dirname()

    %{
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_stdio",
          "command" => System.find_executable("elixir"),
          "args" => ["-pa", jason_ebin, script],
          "cd" => File.cwd!()
        }
      }
    }
  end

  defp start_mcp_http_fixture(opts \\ []) do
    parent = self()

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_socket)

    pid =
      spawn_link(fn ->
        serve_mcp_http(parent, listen_socket, 4, opts)
        :gen_tcp.close(listen_socket)
      end)

    {:ok, %{pid: pid, url: "http://127.0.0.1:#{port}/mcp"}}
  end

  defp serve_mcp_http(_parent, _listen_socket, 0, _opts), do: :ok

  defp serve_mcp_http(parent, listen_socket, remaining, opts) do
    {:ok, socket} = :gen_tcp.accept(listen_socket)
    {:ok, request} = read_http_request(socket)
    method = get_in(request, [:decoded, "method"])
    send(parent, {:mcp_http_fixture_request, method, request.headers})
    send_mcp_http_response(socket, request.decoded, opts)
    :gen_tcp.close(socket)
    serve_mcp_http(parent, listen_socket, remaining - 1, opts)
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

  defp send_mcp_http_response(socket, %{"method" => "notifications/initialized"}, _opts) do
    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 202 Accepted\r\n",
        "mcp-session-id: root-test-session\r\n",
        "content-length: 0\r\n",
        "connection: close\r\n\r\n"
      ])
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

    if Keyword.get(opts, :sse?, false) do
      sse_response(socket, id, %{"structuredContent" => %{"echo" => args}})
    else
      json_response(socket, id, %{"structuredContent" => %{"echo" => args}})
    end
  end

  defp json_response(socket, id, result, opts \\ []) do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

    session_header =
      if Keyword.get(opts, :session?, false),
        do: "mcp-session-id: root-test-session\r\n",
        else: ""

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "content-type: application/json\r\n",
        session_header,
        "content-length: #{byte_size(body)}\r\n",
        "connection: close\r\n",
        "\r\n",
        body
      ])
  end

  defp sse_response(socket, id, result) do
    event =
      "data: " <> Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n\n"

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "content-type: text/event-stream\r\n",
        "content-length: #{byte_size(event)}\r\n",
        "connection: close\r\n",
        "\r\n",
        event
      ])
  end
end
