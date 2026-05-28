defmodule PtcRunnerMcp.RootUpstreamRuntimeTest do
  use ExUnit.Case, async: false

  alias PtcRunner.Upstream.Runtime
  alias PtcRunnerMcp.AgenticConfig
  alias PtcRunnerMcp.Application
  alias PtcRunnerMcp.CatalogConfig
  alias PtcRunnerMcp.Credentials.Redactor
  alias PtcRunnerMcp.PromptRegistry
  alias PtcRunnerMcp.RootUpstreamRuntime
  alias PtcRunnerMcp.Tools

  @schema Path.expand("../fixtures/openapi/observatory.openapi.json", __DIR__)

  setup do
    Runtime.stop(RootUpstreamRuntime.name())
    AgenticConfig.set(AgenticConfig.defaults())
    CatalogConfig.set(CatalogConfig.defaults())

    on_exit(fn ->
      Runtime.stop(RootUpstreamRuntime.name())
      AgenticConfig.set(AgenticConfig.defaults())
      CatalogConfig.set(CatalogConfig.defaults())
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
