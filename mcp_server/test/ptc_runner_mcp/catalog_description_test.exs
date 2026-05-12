defmodule PtcRunnerMcp.CatalogDescriptionTest do
  @moduledoc """
  Tests for mode-aware catalog description rendering.

  Spec: `Plans/ptc-runner-mcp-catalog-exposure.md` §5-§6.

  Covers the 8 scenarios from issue #910:
  1. Small fully-known fleet → auto chooses inline
  2. Large fleet (>40 tools) → auto chooses lazy
  3. Fleet with unknown catalog → auto chooses lazy
  4. Fleet with rendered >12k chars → auto chooses lazy
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
    test "scenario 1: small fully-known fleet, auto → inline" do
      result = CatalogDescription.render_for_entries(small_fleet(), default_config())

      assert result =~ "Configured upstream MCP servers:"
      assert result =~ "- filesystem:"
      assert result =~ "- github:"
      assert result =~ "Tools:"
      assert result =~ "- tool_1:"
      refute result =~ "catalog/search-tools"
    end

    test "scenario 2: large fleet (>40 tools), auto → lazy" do
      result = CatalogDescription.render_for_entries(large_fleet(), default_config())

      assert result =~ "Configured upstream MCP servers:"
      assert result =~ "- github:"
      assert result =~ "25 tools."
      assert result =~ "- linear:"
      assert result =~ "20 tools."
      refute result =~ "Tools:"
      assert result =~ "catalog/search-tools"
      assert result =~ "catalog/list-tools"
      assert result =~ "catalog/describe-tool"
    end

    test "scenario 3: fleet with unknown catalog, auto → lazy" do
      result = CatalogDescription.render_for_entries(fleet_with_unknown(), default_config())

      assert result =~ "Configured upstream MCP servers:"
      assert result =~ "Catalog loads on first use."
      refute result =~ "Tools:"
      assert result =~ "catalog/search-tools"
    end

    test "scenario 4: fleet with rendered >12k chars, auto → lazy" do
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

      refute result =~ "Tools:"
      assert result =~ "catalog/search-tools"
    end

    test "scenario 5: any fleet, mode=inline → forced inline" do
      config = %{default_config() | catalog_mode: :inline}
      result = CatalogDescription.render_for_entries(large_fleet(), config)

      assert result =~ "Tools:"
      assert result =~ "- tool_1:"
      refute result =~ "catalog/search-tools"
    end

    test "scenario 6: any fleet, mode=lazy → forced lazy" do
      config = %{default_config() | catalog_mode: :lazy}
      result = CatalogDescription.render_for_entries(small_fleet(), config)

      refute result =~ "Tools:"
      assert result =~ "catalog/search-tools"
      assert result =~ "8 tools."
      assert result =~ "7 tools."
    end

    test "scenario 7: forced inline with unknown catalogs → warnings + discovery" do
      config = %{default_config() | catalog_mode: :inline}
      result = CatalogDescription.render_for_entries(fleet_with_unknown(), config)

      assert result =~ "Tools:"
      assert result =~ "- tool_1:"
      assert result =~ ~s(Warning: catalog for "linear" not loaded yet.)
      assert result =~ "Catalog loads on first use."
      assert result =~ "catalog/search-tools"
      assert result =~ "catalog/describe-tool"
    end

    test "scenario 8: zero upstreams → nil" do
      assert CatalogDescription.render_for_entries([], default_config()) == nil
    end
  end

  describe "resolve_mode/2" do
    test "auto with all known and under thresholds → inline" do
      assert {:inline, []} = CatalogDescription.resolve_mode(small_fleet(), default_config())
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
      result = CatalogDescription.render_for_entries(small_fleet(), default_config())

      assert result =~ "- github: GitHub MCP server. 8 tools. issues, pull requests."
      assert result =~ "- filesystem: Filesystem MCP server. 7 tools. files, directories."
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

    test "tool entries include name and description" do
      entries = [
        %{
          name: "srv",
          tools: [
            %{name: "do_thing", description: "Does something useful."},
            %{name: "no_desc", description: ""}
          ],
          metadata: %{}
        }
      ]

      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ "  - do_thing: Does something useful."
      assert result =~ "  - no_desc:"
      refute result =~ "  - no_desc: "
    end

    test "known empty tools renders 0 tools" do
      entries = [%{name: "empty", tools: [], metadata: %{}}]
      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ "- empty: 0 tools."
    end
  end

  describe "lazy rendering format (§6.3)" do
    test "includes discovery syntax examples" do
      config = %{default_config() | catalog_mode: :lazy}
      result = CatalogDescription.render_for_entries(small_fleet(), config)

      assert result =~ ~s|(catalog/search-tools "query" {:limit 8})|
      assert result =~ ~s|(catalog/list-tools "server-name" {:limit 20})|
      assert result =~ ~s|(catalog/describe-tool "server-name" "tool-name")|
      assert result =~ ~s|(tool/mcp-call {:server "server-name" :tool "tool-name" :args {...}})|
    end

    test "does not list individual tools" do
      config = %{default_config() | catalog_mode: :lazy}
      result = CatalogDescription.render_for_entries(small_fleet(), config)

      refute result =~ "tool_1"
      refute result =~ "Tools:"
    end

    test "unknown server shows catalog loads on first use" do
      config = %{default_config() | catalog_mode: :lazy}
      result = CatalogDescription.render_for_entries(fleet_with_unknown(), config)

      assert result =~ "- linear: Linear issue tracker. Catalog loads on first use."
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
      assert result =~ "cap1."
    end

    test "renders cleanly without metadata" do
      entries = [%{name: "bare", tools: make_tools(2)}]
      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ "- bare: 2 tools."
    end

    test "renders cleanly with empty metadata" do
      entries = [%{name: "bare", tools: make_tools(2), metadata: %{}}]
      result = CatalogDescription.render_for_entries(entries, default_config())
      assert result =~ "- bare: 2 tools."
    end
  end

  describe "threshold behavior" do
    test "auto stays inline at exactly the tool threshold" do
      entries = [%{name: "srv", tools: make_tools(40), metadata: %{}}]
      assert {:inline, []} = CatalogDescription.resolve_mode(entries, default_config())
    end

    test "auto switches to lazy at tool threshold + 1" do
      entries = [%{name: "srv", tools: make_tools(41), metadata: %{}}]
      assert :lazy = CatalogDescription.resolve_mode(entries, default_config())
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
