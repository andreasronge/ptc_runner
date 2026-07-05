defmodule PtcRunnerMcp.RootUpstreamRuntimeTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Upstream.Runtime
  alias PtcRunnerMcp.AgenticConfig
  alias PtcRunnerMcp.Application
  alias PtcRunnerMcp.CatalogConfig
  alias PtcRunnerMcp.Credentials.Redactor
  alias PtcRunnerMcp.PromptRegistry
  alias PtcRunnerMcp.RootUpstreamRuntime
  alias PtcRunnerMcp.Sessions.Config, as: SessionsConfig
  alias PtcRunnerMcp.Sessions.Policy
  alias PtcRunnerMcp.Test.FakeHttpServer
  alias PtcRunnerMcp.TestSupport.SoakHelpers
  alias PtcRunnerMcp.Tools

  @schema Path.expand("../fixtures/openapi/observatory.openapi.json", __DIR__)
  @fixture_recv_timeout_ms 5_000

  setup do
    Runtime.stop(RootUpstreamRuntime.name())
    AgenticConfig.set(AgenticConfig.defaults())
    CatalogConfig.set(CatalogConfig.defaults())
    SessionsConfig.reset()

    on_exit(fn ->
      Runtime.stop(RootUpstreamRuntime.name())
      AgenticConfig.set(AgenticConfig.defaults())
      CatalogConfig.set(CatalogConfig.defaults())
      SessionsConfig.reset()
    end)

    :ok
  end

  test "MCP server config loader routes root transport names to root runtime opts" do
    path =
      write_config!(%{
        "upstreams" => %{
          "api" => %{
            "transport" => "openapi",
            "base_url" => "https://observatory.example",
            "schema_file" => @schema,
            "include_operations" => ["list_traces"]
          },
          "fixture" => %{
            "transport" => "mcp_http",
            "url" => "http://127.0.0.1:9/mcp",
            "allow_insecure_http" => true
          }
        }
      })

    result = Application.load_aggregator_config(%{upstreams_config: path})

    assert result.upstreams == []
    assert result.credentials == %{}
    assert result.root_runtime_opts[:config_path] == path
    assert result.root_runtime_opts[:catalog_snapshot_mode] == :frozen

    children = Application.build_children([], %{}, %{}, result.root_runtime_opts)
    assert Enum.any?(children, &match?({PtcRunner.Upstream.Runtime, _}, &1))
  end

  test "MCP tools surface uses a running root upstream runtime" do
    {:ok, _pid} =
      Runtime.start_supervised(
        config: root_config(),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    assert RootUpstreamRuntime.configured?()
    assert Tools.configured_aggregator_mode?()

    entry = Tools.tool_entry()
    assert entry["description"] =~ "observatory"
    assert entry["description"] =~ "list-traces"
  end

  test "stateless lisp_eval executes through root upstream runtime" do
    {:ok, _pid} =
      Runtime.start_supervised(
        config: root_config(),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    result = Tools.call_validated("(tool/servers)", %{}, nil)

    assert %{"isError" => false, "content" => [%{"text" => text}]} = result
    assert text =~ "observatory"
    assert text =~ "tool_count"
  end

  test "agentic prompt and tool description use root catalog snapshot" do
    {:ok, _pid} =
      Runtime.start_supervised(
        config: root_config(),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    :ok = AgenticConfig.set(%{enabled: true, model: "stub:model"})

    task = Enum.find(Tools.list()["tools"], &(&1["name"] == "lisp_task"))
    assert task["description"] =~ "observatory"
    assert task["description"] =~ "list-traces"

    prompt = PromptRegistry.render(:mcp_agentic_task_prompt, [])
    assert prompt =~ "observatory"
    assert prompt =~ "list-traces"
  end

  test "root runtime credentials are registered with MCP redaction defense in depth" do
    secret = "root-runtime-secret-#{System.unique_integer([:positive])}"

    config =
      root_config()
      |> Map.put("credentials", %{
        "api_token" => %{"source" => "literal", "value" => secret, "scheme_hint" => "bearer"}
      })
      |> put_in(
        ["upstreams", "observatory", "auth"],
        [%{"scheme" => "bearer", "binding" => "api_token"}]
      )

    {:ok, supervisor} =
      Supervisor.start_link(
        Application.build_children([], %{}, %{}, config: config, catalog_snapshot_mode: :frozen),
        strategy: :rest_for_one
      )

    try do
      assert Redactor.scrub("upstream echoed Authorization: Bearer #{secret}") ==
               "upstream echoed Authorization: Bearer [REDACTED]"
    after
      Supervisor.stop(supervisor)
    end
  end

  test "stateful sessions use role-projected root runtime credentials" do
    SoakHelpers.setup_sessions(%{enabled: true})

    {:ok, policy} =
      Policy.from_map(%{
        "default_role" => "analyst",
        "roles" => %{
          "analyst" => %{
            "credentials" => []
          }
        }
      })

    SessionsConfig.set(%{SessionsConfig.get() | policy: policy})

    {:ok, _pid} =
      Runtime.start_supervised(
        config: credential_root_config("session-secret"),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    start = Tools.call(%{"name" => "lisp_session_start", "arguments" => %{"role" => "analyst"}})
    session_id = start["structuredContent"]["session_id"]

    result =
      Tools.call(%{
        "name" => "lisp_session_eval",
        "arguments" => %{
          "session_id" => session_id,
          "program" =>
            ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme"}})|
        }
      })

    assert result["isError"] == false
    assert result["structuredContent"]["status"] == "ok"
    assert result["structuredContent"]["result"] =~ "credential unavailable for this role"
    refute result["structuredContent"]["result"] =~ "api_token"
    refute inspect(result) =~ "session-secret"
  end

  test "stateful sessions can use root credentials granted to their role" do
    SoakHelpers.setup_sessions(%{enabled: true})
    {:ok, server} = start_http_fixture(%{"traces" => [%{"id" => "trace-1", "org_id" => "acme"}]})

    {:ok, policy} =
      Policy.from_map(%{
        "default_role" => "analyst",
        "roles" => %{
          "analyst" => %{
            "credentials" => ["api_token"]
          }
        }
      })

    SessionsConfig.set(%{SessionsConfig.get() | policy: policy})

    {:ok, _pid} =
      Runtime.start_supervised(
        config:
          credential_root_config("session-secret",
            base_url: server.base_url,
            allow_insecure_http: true,
            allow_insecure_auth: true
          ),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    try do
      start = Tools.call(%{"name" => "lisp_session_start", "arguments" => %{"role" => "analyst"}})
      session_id = start["structuredContent"]["session_id"]

      result =
        Tools.call(%{
          "name" => "lisp_session_eval",
          "arguments" => %{
            "session_id" => session_id,
            "program" =>
              ~S|(tool/call {:server "observatory" :tool "list-traces" :args {:org_id "acme" :limit 1}})|
          }
        })

      assert result["isError"] == false
      assert result["structuredContent"]["status"] == "ok"
      assert result["structuredContent"]["result"] =~ "trace-1"
      refute inspect(result) =~ "session-secret"

      assert_receive {:http_fixture_request, request}, 1_000
      assert request =~ "authorization: Bearer session-secret"
    after
      Process.exit(server.pid, :kill)
    end
  end

  test "stateful sessions denied MCP HTTP credentials do not reuse root client" do
    SoakHelpers.setup_sessions(%{enabled: true})

    server =
      start_supervised!(
        {FakeHttpServer,
         scenario: :handshake_success,
         opts: %{
           toolset: [
             %{
               "name" => "echo",
               "description" => "Echo arguments",
               "inputSchema" => %{"type" => "object"}
             }
           ]
         }}
      )

    url = "http://127.0.0.1:#{FakeHttpServer.port(server)}/mcp"

    {:ok, policy} =
      Policy.from_map(%{
        "default_role" => "analyst",
        "roles" => %{
          "analyst" => %{
            "credentials" => []
          }
        }
      })

    SessionsConfig.set(%{SessionsConfig.get() | policy: policy})

    {:ok, _pid} =
      Runtime.start_supervised(
        config: mcp_http_credential_root_config("session-secret", url),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    requests = FakeHttpServer.received_requests(server)

    assert Enum.map(requests, &get_in(&1, [:decoded, "method"])) == [
             "initialize",
             "notifications/initialized",
             "tools/list"
           ]

    initialize = hd(requests)

    assert Enum.any?(initialize.headers, fn {key, value} ->
             String.downcase(key) == "authorization" and value == "Bearer session-secret"
           end)

    start = Tools.call(%{"name" => "lisp_session_start", "arguments" => %{"role" => "analyst"}})
    session_id = start["structuredContent"]["session_id"]

    result =
      Tools.call(%{
        "name" => "lisp_session_eval",
        "arguments" => %{
          "session_id" => session_id,
          "program" => ~S|(tool/call {:server "fixture" :tool "echo" :args {:message "denied"}})|
        }
      })

    assert result["isError"] == false
    assert result["structuredContent"]["status"] == "ok"
    assert result["structuredContent"]["result"] =~ "upstream fixture is unavailable"
    refute result["structuredContent"]["result"] =~ "api_token"
    refute inspect(result) =~ "session-secret"

    assert FakeHttpServer.received_requests(server) == requests
  end

  test "stateful sessions reject roles with unknown root credential grants" do
    SoakHelpers.setup_sessions(%{enabled: true})

    {:ok, policy} =
      Policy.from_map(%{
        "default_role" => "analyst",
        "roles" => %{
          "analyst" => %{
            "credentials" => ["missing_token"]
          }
        }
      })

    SessionsConfig.set(%{SessionsConfig.get() | policy: policy})

    {:ok, _pid} =
      Runtime.start_supervised(
        config: credential_root_config("session-secret"),
        name: RootUpstreamRuntime.name(),
        catalog_snapshot_mode: :frozen
      )

    result = Tools.call(%{"name" => "lisp_session_start", "arguments" => %{"role" => "analyst"}})

    assert result["isError"] == true
    assert result["structuredContent"]["reason"] == "session_args_error"

    assert result["structuredContent"]["message"] =~
             "role analyst grants unknown credential(s): missing_token"

    refute inspect(result) =~ "session-secret"
  end

  test "MCP catalog mode and inline caps are applied to root runtime descriptions" do
    CatalogConfig.set(%{
      catalog_mode: :lazy,
      catalog_inline_max_chars: 1,
      catalog_inline_max_tools: 1
    })

    {:ok, supervisor} =
      Supervisor.start_link(
        Application.build_children([], %{}, %{},
          config: root_config(),
          catalog_snapshot_mode: :frozen
        ),
        strategy: :rest_for_one
      )

    try do
      entry = Tools.tool_entry()

      assert entry["description"] =~ "observatory (1 tools)"
      refute entry["description"] =~ "observatory/list-traces"
    after
      Supervisor.stop(supervisor)
    end
  end

  defp root_config do
    %{
      "upstreams" => %{
        "observatory" => %{
          "transport" => "openapi",
          "base_url" => "https://observatory.example",
          "schema_file" => @schema,
          "include_operations" => ["list_traces"]
        }
      }
    }
  end

  defp credential_root_config(secret, opts \\ []) do
    root_config()
    |> Map.put("credentials", %{
      "api_token" => %{"source" => "literal", "value" => secret, "scheme_hint" => "bearer"}
    })
    |> put_in(
      ["upstreams", "observatory", "base_url"],
      Keyword.get(opts, :base_url, "https://observatory.example")
    )
    |> put_in(
      ["upstreams", "observatory", "allow_insecure_http"],
      Keyword.get(opts, :allow_insecure_http, false)
    )
    |> put_in(
      ["upstreams", "observatory", "allow_insecure_auth"],
      Keyword.get(opts, :allow_insecure_auth, false)
    )
    |> put_in(
      ["upstreams", "observatory", "auth"],
      [%{"scheme" => "bearer", "binding" => "api_token"}]
    )
  end

  defp mcp_http_credential_root_config(secret, url) do
    %{
      "credentials" => %{
        "api_token" => %{"source" => "literal", "value" => secret, "scheme_hint" => "bearer"}
      },
      "upstreams" => %{
        "fixture" => %{
          "transport" => "mcp_http",
          "url" => url,
          "allow_insecure_http" => true,
          "allow_insecure_auth" => true,
          "auth" => [%{"scheme" => "bearer", "binding" => "api_token"}]
        }
      }
    }
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

  defp write_config!(config) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ptc_runner_mcp_root_runtime_#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(config))
    path
  end
end
