defmodule PtcRunnerMcp.CatalogIntegrationTest do
  @moduledoc """
  Integration tests for size-aware MCP catalog exposure.

  Spec: `Plans/ptc-runner-mcp-catalog-exposure.md` §12 integration tests.

  These test the full pipeline — tools/list rendering or PTC-Lisp
  execution — not individual modules. Each test starts its own
  `Upstream.Registry` under the production name so `Tools` functions
  find it, freezes a catalog snapshot for description rendering, and
  cleans up on exit.

  Tests 1–3: tools/list rendering (inline, lazy, unloaded).
  Tests 4–6: PTC-Lisp execution flows (discovery, unloaded discovery,
             direct call bypass).
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.McpTestHelpers, only: [stop_existing_registry: 1]

  alias PtcRunnerMcp.{AggregatorConfig, CatalogConfig, Limits, Tools}
  alias PtcRunnerMcp.Upstream.{Catalog, Registry}

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    stop_existing_registry(@registry_name)

    {:ok, _pid} = Registry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())
    CatalogConfig.set(CatalogConfig.defaults())

    on_exit(fn ->
      stop_existing_registry(@registry_name)
      Limits.set(Limits.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
      CatalogConfig.set(CatalogConfig.defaults())
      Catalog.clear_frozen()
    end)

    :ok
  end

  # ============================================================
  # § 12 integration test 1: inline rendering in tools/list
  # ============================================================

  describe "inline rendering in tools/list" do
    test "small fleet under both thresholds renders inline catalog" do
      put_fake_with_tools("alpha", 3, "Alpha server", ["search"])
      put_fake_with_tools("beta", 2, "Beta server", ["files"])

      freeze_snapshot()

      entry = Tools.tool_entry()
      description = entry["description"]

      assert String.starts_with?(description, "Tools below. For details:")
      assert description =~ "Configured upstream MCP servers:"
      assert description =~ "alpha:"
      assert description =~ "beta:"
      assert description =~ "3 tools."
      assert description =~ "2 tools."
      assert description =~ "Tools:"
      assert description =~ "alpha.tool_1(key: string?)"
    end
  end

  # ============================================================
  # § 12 integration test 2: lazy rendering in tools/list
  # ============================================================

  describe "lazy rendering in tools/list" do
    test "large fleet over tool threshold renders lazy instructions" do
      put_fake_with_tools("srv_a", 25, "Service A", [])
      put_fake_with_tools("srv_b", 20, "Service B", [])

      freeze_snapshot()

      entry = Tools.tool_entry()
      description = entry["description"]

      assert String.starts_with?(description, "Tools below. For details:")
      assert description =~ "Configured upstream MCP servers:"
      assert description =~ "srv_a"
      assert description =~ "srv_b"
      assert description =~ "catalog/search-tools"
      assert description =~ "catalog/list-tools"
      assert description =~ "catalog/describe-tool"
      refute description =~ "  Tools:"
    end
  end

  # ============================================================
  # § 12 integration test 3: unloaded upstreams in tools/list
  # ============================================================

  describe "unloaded upstreams in tools/list" do
    test "unloaded upstream fleet renders lazy instructions" do
      put_fake_unloaded("gamma", "Gamma server")
      put_fake_unloaded("delta", "Delta server")

      freeze_snapshot_unloaded(["gamma", "delta"])

      entry = Tools.tool_entry()
      description = entry["description"]

      assert String.starts_with?(description, "Tools below. For details:")
      assert description =~ "Configured upstream MCP servers:"
      assert description =~ "gamma"
      assert description =~ "delta"
      assert description =~ "catalog/search-tools"
      refute description =~ "  Tools:"
    end
  end

  # ============================================================
  # § 12 integration test 4: PTC-Lisp discovery flow
  # ============================================================

  describe "PTC-Lisp discovery flow" do
    test "search → describe → mcp-call returns compact result" do
      put_fake_with_tools("warehouse", 3, "Warehouse inventory", ["stock"],
        handler: fn _tool_name ->
          fn args, _opts -> {:ok, %{"structuredContent" => %{"count" => args["item_id"]}}} end
        end
      )

      {:ok, _} = Registry.ensure_started("warehouse")
      freeze_snapshot()

      env =
        call(~S"""
        (let [results (catalog/search-tools "warehouse" {:limit 5})
              first_line (first results)
              server (first (clojure.string/split first_line #"\."))
              first_tool (first (clojure.string/split (second (clojure.string/split first_line #"\.")) #"\("))
              detail (catalog/describe-tool server first_tool)]
          (tool/mcp-call {:server server
                          :tool first_tool
                          :args {:item_id "abc"}}))
        """)

      assert env["isError"] == false
      assert structured(env)["status"] == "ok"
      assert structured(env)["result"] =~ "abc"

      upstream = upstream_calls(env)
      assert length(upstream) == 1
      [entry] = upstream
      assert entry["server"] == "warehouse"
      assert entry["status"] == "ok"
    end
  end

  # ============================================================
  # § 12 integration test 5: unloaded discovery flow
  # ============================================================

  describe "unloaded discovery flow" do
    test "search server-level → list-tools → describe → mcp-call" do
      put_fake_with_tools("analytics", 2, "Analytics platform", ["metrics"],
        handler: fn tool_name ->
          fn _args, _opts ->
            {:ok, %{"structuredContent" => %{"tool" => tool_name, "value" => 42}}}
          end
        end
      )

      freeze_snapshot_unloaded(["analytics"])

      env =
        call(~S"""
        (let [search (catalog/search-tools "analytics" {:limit 5})
              server (first (clojure.string/split (first search) #":"))
              tools (catalog/list-tools server {:limit 10})
              first_tool (first (clojure.string/split (second (clojure.string/split (first tools) #"\.")) #"\("))
              detail (catalog/describe-tool server first_tool)]
          (tool/mcp-call {:server server
                          :tool first_tool
                          :args {:query "test"}}))
        """)

      assert env["isError"] == false
      assert structured(env)["status"] == "ok"
      assert structured(env)["result"] =~ "42"

      upstream = upstream_calls(env)
      assert length(upstream) == 1
      assert hd(upstream)["server"] == "analytics"
    end
  end

  # ============================================================
  # § 12 integration test 6: direct call in inline mode
  # ============================================================

  describe "direct call in inline mode" do
    test "mcp-call works without catalog builtins in inline mode" do
      put_fake_with_tools("storage", 2, "Storage backend", ["blobs"])

      freeze_snapshot()

      env =
        call(~S"""
        (tool/mcp-call {:server "storage"
                        :tool "tool_1"
                        :args {:key "myfile"}})
        """)

      assert env["isError"] == false
      assert structured(env)["status"] == "ok"

      upstream = upstream_calls(env)
      assert length(upstream) == 1
      assert hd(upstream)["server"] == "storage"
      assert hd(upstream)["tool"] == "tool_1"
      assert hd(upstream)["status"] == "ok"
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp put_fake_with_tools(name, count, description, capabilities, opts \\ []) do
    handler_fn =
      Keyword.get(opts, :handler, fn _tool_name ->
        fn args, _opts -> {:ok, %{"result" => args}} end
      end)

    tool_schemas =
      Enum.map(1..count, fn i ->
        tool_name = "tool_#{i}"

        %{
          name: tool_name,
          description: "Description for #{tool_name}.",
          input_schema: %{
            "type" => "object",
            "properties" => %{"key" => %{"type" => "string"}},
            "required" => []
          }
        }
      end)

    tools =
      Map.new(tool_schemas, fn schema ->
        {schema.name, {schema, handler_fn.(schema.name)}}
      end)

    metadata = %{description: description, capabilities: capabilities}
    config = %{tools: tools, metadata: metadata}

    :ok = Registry.put_fake(name, config, @registry_name)

    register_fake_tracking(name, tool_schemas, metadata)
  end

  defp put_fake_unloaded(name, description) do
    tool_schemas = [%{name: "placeholder", description: "Placeholder.", input_schema: %{}}]

    config = %{
      tools: %{
        "placeholder" =>
          {%{name: "placeholder", input_schema: %{}},
           fn _args, _opts -> {:ok, %{"ok" => true}} end}
      },
      init_delay_ms: 0,
      metadata: %{
        description: description,
        capabilities: []
      }
    }

    :ok = Registry.put_fake(name, config, @registry_name)

    metadata = %{description: description, capabilities: []}
    register_fake_tracking(name, tool_schemas, metadata)
  end

  defp freeze_snapshot do
    entries = build_loaded_snapshot()
    Catalog.freeze_snapshot(entries)
  end

  defp freeze_snapshot_unloaded(server_names) do
    loaded = build_loaded_snapshot()

    entries =
      Enum.map(server_names, fn name ->
        case Enum.find(loaded, &(&1.name == name)) do
          %{metadata: metadata} ->
            %{name: name, tools: nil, metadata: metadata}

          _ ->
            %{name: name, tools: nil, metadata: %{}}
        end
      end)

    Catalog.freeze_snapshot(entries)
  end

  defp build_loaded_snapshot do
    Enum.map(registered_fakes(), fn {name, tools, metadata} ->
      %{name: name, tools: tools, metadata: metadata}
    end)
  end

  defp registered_fakes do
    Process.get(:test_fakes, [])
  end

  defp register_fake_tracking(name, tools, metadata) do
    fakes = Process.get(:test_fakes, [])
    Process.put(:test_fakes, fakes ++ [{name, tools, metadata}])
  end

  defp call(program) do
    Tools.call_with_gate(%{"program" => program})
  end

  defp structured(env), do: env["structuredContent"]

  defp upstream_calls(env), do: structured(env)["upstream_calls"] || []
end
