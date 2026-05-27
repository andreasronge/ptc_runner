defmodule PtcRunnerMcp.Upstream.OpenApiTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias PtcRunnerMcp.{AggregatorConfig, Credentials, Limits, Tools}
  alias PtcRunnerMcp.Application, as: McpApplication
  alias PtcRunnerMcp.Upstream.{OpenApi, Registry}
  alias PtcRunnerMcp.Upstream.OpenApi.Compiler
  alias PtcRunnerMcp.Upstream.OpenApi.SchemaLoader

  defmodule ApiPlug do
    @behaviour Plug

    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/api/traces"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"traces" => [%{"id" => "t1"}], "query_string" => conn.query_string})
      )
    end

    def call(%Plug.Conn{request_path: "/api/traces/t1"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"id" => "t1", "status" => "ok"}))
    end

    def call(%Plug.Conn{request_path: "/api/huge"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"data" => String.duplicate("x", 2_000)}))
    end

    def call(%Plug.Conn{request_path: "/huge-openapi.json"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"openapi" => String.duplicate("x", 2_000)}))
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    stop_registry()
    {:ok, _pid} = Registry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())

    on_exit(fn ->
      stop_registry()
      Limits.set(Limits.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
    end)

    :ok
  end

  test "compiler exposes kebab-case tool names and keeps operationId provenance" do
    schema = schema("https://observatory.example")

    assert {:ok, [tool]} =
             Compiler.compile(schema, %{
               base_url: "https://observatory.example",
               include_operations: ["list_traces"],
               operation_overrides: %{}
             })

    assert tool["name"] == "list-traces"
    assert tool["_ptc"]["operationId"] == "list_traces"
    assert tool["_ptc"]["transport"] == "openapi"
  end

  test "Observatory fixture compiles curated read-only operations" do
    schema =
      "test/fixtures/openapi/observatory.openapi.json"
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, tools} =
             Compiler.compile(schema, %{
               base_url: "https://observatory.example",
               include_operations: [
                 "list_traces",
                 "get_trace",
                 "list_trace_steps",
                 "get_trace_cost"
               ],
               operation_overrides: %{}
             })

    assert Enum.map(tools, & &1["name"]) == [
             "list-traces",
             "get-trace",
             "list-trace-steps",
             "get-trace-cost"
           ]

    assert Enum.all?(tools, &(get_in(&1, ["_ptc", "transport"]) == "openapi"))
  end

  test "schema_url auth failure aborts before fetch" do
    creds = start_creds(%{})

    config = %{
      schema_url: "http://127.0.0.1:1/openapi.json",
      static_headers: [],
      auth: [%{scheme: :bearer, binding: "missing", header: nil}],
      credentials: creds,
      request_timeout_ms: 50,
      schema_max_bytes: 1_000
    }

    assert {:error, :upstream_unavailable, detail} = SchemaLoader.load(config)
    assert detail =~ "schema auth resolution_failed: missing"
  end

  test "schema_url enforces raw byte cap before decode" do
    {_server, base_url} = start_api_server()

    config = %{
      schema_url: "#{base_url}/huge-openapi.json",
      static_headers: [],
      auth: [],
      request_timeout_ms: 2_000,
      schema_max_bytes: 64
    }

    assert {:error, :response_too_large, detail} = SchemaLoader.load(config)
    assert detail =~ "schema response exceeded 64 bytes"
  end

  test "OpenAPI call enforces raw response cap before decode" do
    {_server, base_url} = start_api_server()
    name = "observatory-#{System.unique_integer([:positive])}"
    schema_path = write_schema!(schema(base_url))

    config = %{
      base_url: base_url,
      schema_file: schema_path,
      static_headers: [],
      auth: [],
      request_timeout_ms: 2_000,
      connect_timeout_ms: 2_000,
      max_response_bytes: 128,
      schema_max_bytes: 1_000_000,
      include_operations: ["huge_response"],
      operation_overrides: %{}
    }

    {:ok, _pid} = OpenApi.start_link(name, config)
    on_exit(fn -> OpenApi.stop(name) end)

    assert {:error, :response_too_large, detail} =
             OpenApi.call(name, "huge-response", %{}, timeout: 2_000, max_response_bytes: 128)

    assert detail =~ "response exceeded 128 bytes"
  end

  test "OpenAPI call omits empty query and rejects array query values" do
    {_server, base_url} = start_api_server()
    name = "observatory-#{System.unique_integer([:positive])}"
    schema_path = write_schema!(schema(base_url))

    config = openapi_config(base_url, schema_path, ["list_traces"])

    {:ok, _pid} = OpenApi.start_link(name, config)
    on_exit(fn -> OpenApi.stop(name) end)

    assert {:ok, %{"structuredContent" => %{"query_string" => ""}}} =
             OpenApi.call(name, "list-traces", %{}, timeout: 2_000)

    assert {:error, :upstream_error, detail} =
             OpenApi.call(name, "list-traces", %{"limit" => [1, 2]}, timeout: 2_000)

    assert detail =~ "unsupported query arg 'limit'"
  end

  test "compiler strips required args supplied by x-ptc-default-args" do
    schema =
      put_in(
        schema("https://observatory.example"),
        ["paths", "/api/traces/{id}", "get", "x-ptc-default-args"],
        %{"id" => "t1"}
      )

    assert {:ok, [tool]} =
             Compiler.compile(schema, %{
               base_url: "https://observatory.example",
               include_operations: ["get_trace"],
               operation_overrides: %{}
             })

    assert get_in(tool, ["inputSchema", "required"]) == []
    assert get_in(tool, ["_ptc", "defaultArgs"]) == %{"id" => "t1"}
  end

  test "compiler rejects missing path parameter declarations" do
    broken =
      put_in(
        schema("https://observatory.example"),
        ["paths", "/api/traces/{id}", "get", "parameters"],
        []
      )

    assert {:error, :upstream_unavailable, detail} =
             Compiler.compile(broken, %{
               base_url: "https://observatory.example",
               include_operations: ["get_trace"],
               operation_overrides: %{}
             })

    assert detail =~ "missing declared path parameter"
    assert detail =~ "id"
  end

  test "compiler rejects non-JSON 2xx responses" do
    broken =
      put_in(
        schema("https://observatory.example"),
        ["paths", "/api/traces", "get", "responses", "200", "content"],
        %{"text/plain" => %{"schema" => %{"type" => "string"}}}
      )

    assert {:error, :upstream_unavailable, detail} =
             Compiler.compile(broken, %{
               base_url: "https://observatory.example",
               include_operations: ["list_traces"],
               operation_overrides: %{}
             })

    assert detail =~ "no JSON 2xx response"
  end

  test "openapi config parser validates schema source and include operations" do
    assert_raise RuntimeError, ~r/must set exactly one of `schema_file:` or `schema_url:`/, fn ->
      McpApplication.parse_openapi_upstream(
        "observatory",
        %{
          "transport" => "openapi",
          "base_url" => "https://observatory.example",
          "schema_file" => "/tmp/openapi.json",
          "schema_url" => "https://observatory.example/openapi.json",
          "include_operations" => ["list_traces"]
        },
        "test.json"
      )
    end

    assert_raise RuntimeError, ~r/include_operations:` must be a non-empty list/, fn ->
      McpApplication.parse_openapi_upstream(
        "observatory",
        %{
          "transport" => "openapi",
          "base_url" => "https://observatory.example",
          "schema_file" => "/tmp/openapi.json",
          "include_operations" => []
        },
        "test.json"
      )
    end

    assert %{
             impl: OpenApi,
             config: %{base_url: "https://observatory.example", schema_file: "/tmp/openapi.json"}
           } =
             McpApplication.parse_openapi_upstream(
               "observatory",
               %{
                 "transport" => "openapi",
                 "base_url" => "https://observatory.example",
                 "schema_file" => "/tmp/openapi.json",
                 "include_operations" => ["list_traces"]
               },
               "test.json"
             )
  end

  test "OpenAPI upstream is callable through symbol-shaped tool/call" do
    {_server, base_url} = start_api_server()
    schema_path = write_schema!(schema(base_url))

    upstream = %{
      name: "observatory",
      impl: PtcRunnerMcp.Upstream.OpenApi,
      config: %{
        base_url: base_url,
        schema_file: schema_path,
        static_headers: [],
        auth: [],
        request_timeout_ms: 2_000,
        connect_timeout_ms: 2_000,
        max_response_bytes: 1_000_000,
        schema_max_bytes: 1_000_000,
        include_operations: ["list_traces", "get_trace"],
        operation_overrides: %{}
      },
      metadata: %{}
    }

    stop_registry()
    {:ok, _pid} = Registry.start_link(name: @registry_name, upstreams: [upstream])

    :ok =
      PtcRunnerMcp.Upstream.Supervisor.eager_start_upstreams(
        upstreams: [upstream],
        registry_name: @registry_name
      )

    :ok =
      PtcRunnerMcp.Upstream.Supervisor.freeze_catalog(
        upstreams: [upstream],
        registry_name: @registry_name
      )

    env = Tools.call_with_gate(%{"program" => ~S|(tool/call 'observatory/list-traces {})|})

    assert env["isError"] == false, inspect(env, limit: :infinity)
    assert get_in(env, ["structuredContent", "status"]) == "ok"

    assert get_in(env, ["structuredContent", "upstream_calls", Access.at(0), "server"]) ==
             "observatory"

    assert get_in(env, ["structuredContent", "upstream_calls", Access.at(0), "tool"]) ==
             "list-traces"

    assert get_in(env, ["structuredContent", "result"]) =~ "t1"
  end

  defp schema(base_url) do
    %{
      "openapi" => "3.0.3",
      "info" => %{"title" => "Observatory", "version" => "1.0.0"},
      "servers" => [%{"url" => base_url}],
      "paths" => %{
        "/api/traces" => %{
          "get" => %{
            "operationId" => "list_traces",
            "summary" => "List traces",
            "parameters" => [
              %{"name" => "limit", "in" => "query", "schema" => %{"type" => "integer"}}
            ],
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{
                    "schema" => %{"type" => "object"}
                  }
                }
              }
            }
          }
        },
        "/api/huge" => %{
          "get" => %{
            "operationId" => "huge_response",
            "summary" => "Huge response",
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{"schema" => %{"type" => "object"}}
                }
              }
            }
          }
        },
        "/api/traces/{id}" => %{
          "get" => %{
            "operationId" => "get_trace",
            "summary" => "Get trace",
            "parameters" => [
              %{
                "name" => "id",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "string"}
              }
            ],
            "responses" => %{
              "200" => %{
                "content" => %{
                  "application/json" => %{"schema" => %{"type" => "object"}}
                }
              }
            }
          }
        }
      }
    }
  end

  defp write_schema!(schema) do
    path = Path.join(System.tmp_dir!(), "ptc-openapi-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(schema))
    path
  end

  defp openapi_config(base_url, schema_path, include_operations) do
    %{
      base_url: base_url,
      schema_file: schema_path,
      static_headers: [],
      auth: [],
      request_timeout_ms: 2_000,
      connect_timeout_ms: 2_000,
      max_response_bytes: 1_000_000,
      schema_max_bytes: 1_000_000,
      include_operations: include_operations,
      operation_overrides: %{}
    }
  end

  defp start_api_server do
    server =
      start_supervised!(
        {Bandit, plug: ApiPlug, scheme: :http, port: 0, ip: {127, 0, 0, 1}, startup_log: false},
        id: {ApiPlug, System.unique_integer([:positive])}
      )

    {:ok, {_addr, port}} = ThousandIsland.listener_info(server)
    {server, "http://127.0.0.1:#{port}"}
  end

  defp start_creds(bindings) do
    name = :"openapi_creds_#{System.unique_integer([:positive])}"
    _pid = start_supervised!({Credentials, [name: name, bindings: bindings]})
    name
  end

  defp stop_registry do
    case Process.whereis(@registry_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end
end
