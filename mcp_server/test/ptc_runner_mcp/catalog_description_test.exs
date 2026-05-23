defmodule PtcRunnerMcp.CatalogDescriptionTest do
  @moduledoc """
  Tests for mode-aware catalog description rendering.

  Spec: `Plans/ptc-runner-mcp-catalog-exposure.md` §5-§6.

  Covers the 8 scenarios from issue #910:
  1. Tiny fully-known fleet → auto chooses inline
  2. Large fleet (>40 tools) → auto chooses lazy
  3. Fleet with unknown catalog → auto chooses lazy
  4. Fleet over rendered char budget → auto chooses lazy
  5. Any fleet, mode=inline → forced inline
  6. Any fleet, mode=lazy → forced lazy
  7. Forced inline with unknown catalogs → inline + warnings + discovery
  8. Zero upstreams → no catalog section (nil)
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.CatalogDescription

  defp make_tools(count) do
    Enum.map(1..count, fn i ->
      %{
        name: "tool_#{i}",
        description: "Description for tool #{i}.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"arg" => %{"type" => "string"}},
          "required" => ["arg"]
        }
      }
    end)
  end

  defp small_fleet do
    [
      %{
        name: "github",
        tools: make_tools(8),
        impl: PtcRunnerMcp.Upstream.Stdio,
        metadata: %{
          description: "GitHub MCP server",
          capabilities: ["issues", "pull requests"]
        }
      },
      %{
        name: "filesystem",
        tools: make_tools(7),
        impl: PtcRunnerMcp.Upstream.Stdio,
        metadata: %{
          description: "Filesystem MCP server",
          capabilities: ["files", "directories"]
        }
      }
    ]
  end

  defp tiny_fleet do
    [
      %{
        name: "github",
        tools: make_tools(2),
        impl: PtcRunnerMcp.Upstream.Stdio,
        metadata: %{
          description: "GitHub MCP server",
          capabilities: ["issues", "pull requests"]
        }
      },
      %{
        name: "filesystem",
        tools: make_tools(1),
        impl: PtcRunnerMcp.Upstream.Stdio,
        metadata: %{
          description: "Filesystem MCP server",
          capabilities: ["files", "directories"]
        }
      }
    ]
  end

  defp large_fleet do
    [
      %{
        name: "github",
        tools: make_tools(25),
        impl: PtcRunnerMcp.Upstream.Stdio,
        metadata: %{description: "GitHub MCP server", capabilities: ["issues"]}
      },
      %{
        name: "linear",
        tools: make_tools(20),
        impl: PtcRunnerMcp.Upstream.Http,
        metadata: %{description: "Linear issue tracker", capabilities: ["issues", "projects"]}
      }
    ]
  end

  defp fleet_with_unknown do
    [
      %{
        name: "github",
        tools: make_tools(8),
        impl: PtcRunnerMcp.Upstream.Stdio,
        metadata: %{description: "GitHub MCP server", capabilities: ["issues"]}
      },
      %{
        name: "linear",
        tools: nil,
        impl: PtcRunnerMcp.Upstream.Http,
        metadata: %{description: "Linear issue tracker", capabilities: ["issues"]}
      }
    ]
  end

  defp default_config, do: PtcRunnerMcp.CatalogConfig.defaults()

  describe "render_for_entries/2 — scenario table" do
    test "scenario 1: tiny fully-known fleet, auto → inline" do
      result = CatalogDescription.render_for_entries(tiny_fleet(), default_config())

      assert result =~ "Synthetic discovery snapshot for configured upstreams:"
      assert result =~ "(mcp/servers)"
      assert result =~ ~s|(dir "filesystem" {:limit 20})|
      assert result =~ ~s|(dir "github" {:limit 20})|
      assert result =~ "filesystem.tool_1(arg: string)"
      assert result =~ ~s|(doc "filesystem/tool_1")|
      refute result =~ "catalog/search-tools"
    end

    test "scenario 2: large fleet (>40 tools), auto → lazy" do
      result = CatalogDescription.render_for_entries(large_fleet(), default_config())

      assert result =~ "Synthetic discovery snapshot for configured upstreams:"
      assert result =~ "(mcp/servers)"
      assert result =~ "github"
      assert result =~ "linear"
      refute result =~ "(dir "
      refute result =~ "catalog/search-tools"
    end

    test "scenario 3: fleet with unknown catalog, auto → lazy" do
      result = CatalogDescription.render_for_entries(fleet_with_unknown(), default_config())

      assert result =~ "Synthetic discovery snapshot for configured upstreams:"
      assert result =~ "(mcp/servers)"
      assert result =~ "github"
      assert result =~ "linear"
      assert result =~ ~s|"catalog_loaded" false|
      refute result =~ "(dir "
      refute result =~ "catalog/search-tools"
    end

    test "scenario 4: fleet over rendered char budget, auto → lazy" do
      verbose_fleet = [
        %{
          name: "big_server",
          tools: make_tools(35),
          impl: PtcRunnerMcp.Upstream.Stdio,
          metadata: %{
            description: String.duplicate("A verbose description. ", 50),
            capabilities: Enum.map(1..20, &"cap_#{&1}")
          }
        }
      ]

      config = %{default_config() | catalog_inline_max_chars: 500}
      result = CatalogDescription.render_for_entries(verbose_fleet, config)

      refute result =~ "(dir "
      refute result =~ "catalog/search-tools"
    end

    test "scenario 5: any fleet, mode=inline → forced inline" do
      config = %{default_config() | catalog_mode: :inline}
      result = CatalogDescription.render_for_entries(large_fleet(), config)

      assert result =~ ~s|(dir "github" {:limit 20})|
      assert result =~ "github.tool_1(arg: string)"
      refute result =~ "catalog/search-tools"
    end

    test "scenario 6: any fleet, mode=lazy → forced lazy" do
      config = %{default_config() | catalog_mode: :lazy}
      result = CatalogDescription.render_for_entries(small_fleet(), config)

      refute result =~ "(dir "
      assert result =~ "filesystem"
      assert result =~ "github"
      refute result =~ "catalog/search-tools"
    end

    test "scenario 7: forced inline with unknown catalogs → warnings + discovery" do
      config = %{default_config() | catalog_mode: :inline}
      result = CatalogDescription.render_for_entries(fleet_with_unknown(), config)

      assert result =~ ~s|(dir "github" {:limit 20})|
      assert result =~ "github.tool_1(arg: string)"
      assert result =~ ~s(Warning: catalog for "linear" not loaded yet.)
      assert result =~ ~s|"catalog_loaded" false|
      refute result =~ "catalog/search-tools"
    end

    test "scenario 8: zero upstreams → nil" do
      assert CatalogDescription.render_for_entries([], default_config()) == nil
    end
  end

  describe "resolve_mode/2" do
    test "auto with all known and under thresholds → inline" do
      assert {:inline, []} = CatalogDescription.resolve_mode(tiny_fleet(), default_config())
    end

    test "auto with unknown catalog → lazy" do
      assert :lazy = CatalogDescription.resolve_mode(fleet_with_unknown(), default_config())
    end

    test "auto with too many tools → lazy" do
      assert :lazy = CatalogDescription.resolve_mode(large_fleet(), default_config())
    end

    test "auto with too many chars → lazy" do
      config = %{default_config() | catalog_inline_max_chars: 10}
      assert :lazy = CatalogDescription.resolve_mode(small_fleet(), config)
    end

    test "auto budgets required-arg signatures before optional prose" do
      entries = [
        %{
          name: "observatory",
          tools: [
            %{
              name: "get_trace",
              description: String.duplicate("Very long prose. ", 200),
              input_schema: %{
                "properties" => %{"id" => %{"type" => "string"}},
                "required" => ["id"]
              }
            }
          ],
          metadata: %{}
        }
      ]

      config = %{default_config() | catalog_inline_max_chars: 500}

      assert {:inline, []} = CatalogDescription.resolve_mode(entries, config)
      result = CatalogDescription.render_for_entries(entries, config)
      assert result =~ "observatory.get_trace(id: string)"
      refute result =~ "Very long prose"
    end

    test "forced inline always returns inline" do
      config = %{default_config() | catalog_mode: :inline}
      assert {:inline, []} = CatalogDescription.resolve_mode(small_fleet(), config)
    end

    test "forced inline with unknown catalogs returns warning servers" do
      config = %{default_config() | catalog_mode: :inline}
      assert {:inline, ["linear"]} = CatalogDescription.resolve_mode(fleet_with_unknown(), config)
    end

    test "forced lazy always returns lazy" do
      config = %{default_config() | catalog_mode: :lazy}
      assert :lazy = CatalogDescription.resolve_mode(small_fleet(), config)
    end
  end

  describe "inline rendering format (§6.2)" do
    test "includes server description and capabilities from metadata" do
      config = %{default_config() | catalog_mode: :inline}
      result = CatalogDescription.render_for_entries(small_fleet(), config)

      assert result =~ ~s|"name" "github"|
      assert result =~ ~s|"description" "GitHub MCP server"|
      assert result =~ ~s|"tool_count" 8|
      assert result =~ ~s|"name" "filesystem"|
      assert result =~ ~s|"description" "Filesystem MCP server"|
      assert result =~ ~s|"tool_count" 7|
    end

    test "entries are sorted by server name" do
      entries = [
        %{name: "zulu", tools: [%{name: "t1", description: "d"}], metadata: %{}},
        %{name: "alpha", tools: [%{name: "t2", description: "d"}], metadata: %{}}
      ]

      result = CatalogDescription.render_for_entries(entries, default_config())
      alpha_pos = :binary.match(result, "alpha") |> elem(0)
      zulu_pos = :binary.match(result, "zulu") |> elem(0)
      assert alpha_pos < zulu_pos
    end

    test "tool entries include compact signature and description" do
      entries = [
        %{
          name: "srv",
          tools: [
            %{
              name: "do_thing",
              description: "Does something useful.",
              input_schema: %{
                "properties" => %{
                  "optional" => %{"type" => "integer"},
                  "required" => %{"type" => "string"}
                },
                "required" => ["required"]
              }
            },
            %{name: "no_desc", description: ""}
          ],
          metadata: %{}
        }
      ]

      result = CatalogDescription.render_for_entries(entries, default_config())

      assert result =~ "srv.do_thing(required: string, optional: integer?) Does something useful."

      assert result =~ "srv.no_desc()"
      refute result =~ "srv.no_desc() "
    end

    test "required schema keys render even when properties omit them" do
      entries = [
        %{
          name: "observatory",
          tools: [
            %{
              name: "get_trace",
              input_schema: %{"type" => "object", "required" => ["id"]}
            }
          ],
          metadata: %{}
        }
      ]

      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ "observatory.get_trace(id: any)"
    end

    test "known empty tools renders 0 tools" do
      entries = [%{name: "empty", tools: [], metadata: %{}}]
      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ ~s|"name" "empty"|
      assert result =~ ~s|"tool_count" 0|
      refute result =~ "(dir "
    end
  end

  describe "lazy rendering format (§6.3)" do
    test "lists configured servers without duplicating discovery syntax" do
      config = %{default_config() | catalog_mode: :lazy}
      result = CatalogDescription.render_for_entries(small_fleet(), config)

      assert result =~ "Synthetic discovery snapshot for configured upstreams:"
      assert result =~ "(mcp/servers)"
      assert result =~ ~s|"name" "filesystem"|
      assert result =~ ~s|"name" "github"|
      refute result =~ "(dir "
      refute result =~ "catalog/search-tools"
    end

    test "does not list individual tools" do
      config = %{default_config() | catalog_mode: :lazy}
      result = CatalogDescription.render_for_entries(small_fleet(), config)

      refute result =~ "tool_1"
      refute result =~ "(dir "
    end

    test "lazy mode lists configured server names" do
      config = %{default_config() | catalog_mode: :lazy}
      result = CatalogDescription.render_for_entries(fleet_with_unknown(), config)

      assert result =~ ~s|"name" "github"|
      assert result =~ ~s|"name" "linear"|
    end
  end

  describe "metadata handling" do
    test "uses operator description when present" do
      entries = [
        %{
          name: "srv",
          tools: make_tools(3),
          metadata: %{description: "Custom operator description"}
        }
      ]

      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ "Custom operator description"
    end

    test "handles string-keyed metadata" do
      entries = [
        %{
          name: "srv",
          tools: make_tools(3),
          metadata: %{"description" => "String keyed desc", "capabilities" => ["cap1"]}
        }
      ]

      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ "String keyed desc"
      refute result =~ "cap1."
    end

    test "renders cleanly without metadata" do
      entries = [%{name: "bare", tools: make_tools(2)}]
      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ ~s|"name" "bare"|
      assert result =~ ~s|"tool_count" 2|
    end

    test "renders cleanly with empty metadata" do
      entries = [%{name: "bare", tools: make_tools(2), metadata: %{}}]
      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ ~s|"name" "bare"|
      assert result =~ ~s|"tool_count" 2|
    end
  end

  describe "threshold behavior" do
    test "auto stays inline at exactly the tool threshold" do
      max_tools = default_config().catalog_inline_max_tools
      entries = [%{name: "srv", tools: make_tools(max_tools), metadata: %{}}]
      config = %{default_config() | catalog_inline_max_chars: 10_000}

      assert {:inline, []} = CatalogDescription.resolve_mode(entries, config)
    end

    test "auto switches to lazy at tool threshold + 1" do
      max_tools = default_config().catalog_inline_max_tools
      entries = [%{name: "srv", tools: make_tools(max_tools + 1), metadata: %{}}]
      config = %{default_config() | catalog_inline_max_chars: 10_000}

      assert :lazy = CatalogDescription.resolve_mode(entries, config)
    end

    test "auto respects custom thresholds" do
      entries = [%{name: "srv", tools: make_tools(5), metadata: %{}}]
      config = %{default_config() | catalog_inline_max_tools: 3}
      assert :lazy = CatalogDescription.resolve_mode(entries, config)
    end

    test "unknown catalog is not counted as zero tools in auto" do
      entries = [%{name: "srv", tools: nil, metadata: %{}}]
      assert :lazy = CatalogDescription.resolve_mode(entries, default_config())
    end
  end
end
