defmodule PtcRunnerMcp.ToolsPhase0Test do
  @moduledoc """
  Phase 0 acceptance tests for §11.1 / §11.4 / §12.1: profile-aware
  description and outputSchema contracts.

  Spec: `Plans/ptc-runner-mcp-aggregator.md` §11.1, §11.4, §12.1.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.Tools

  @fixture_path Path.expand("../fixtures/tool_entry_v1.json", __DIR__)
  @external_resource @fixture_path

  describe "tool_entry/0 contract (§12.1 #1)" do
    test "preserves stable v1 schema fields without freezing prompt prose" do
      fixture = Jason.decode!(File.read!(@fixture_path))
      live = Tools.tool_entry()

      assert live["name"] == fixture["name"]
      assert live["inputSchema"] == fixture["inputSchema"]
      assert live["outputSchema"] == fixture["outputSchema"]
      assert live["annotations"] == fixture["annotations"]
      assert is_binary(live["description"])
      assert live["description"] =~ "No app tools are available inside the program."
    end
  end

  describe "advertised_description/2 (§11.1)" do
    test ":mcp_no_tools profile returns the registry-rendered description" do
      assert Tools.advertised_description(:mcp_no_tools, catalog: nil) ==
               PtcRunnerMcp.PromptRegistry.render(:mcp_no_tools_description, [])
    end

    test ":mcp_no_tools accepts an opts list (catalog seam)" do
      # The opts seam exists in Phase 0 so Phase 3 can inject a catalog
      # without changing the function signature again.
      assert is_binary(Tools.advertised_description(:mcp_no_tools, catalog: nil))
      assert is_binary(Tools.advertised_description(:mcp_no_tools, []))
    end

    test "default opts arg" do
      assert Tools.advertised_description(:mcp_no_tools) ==
               Tools.advertised_description(:mcp_no_tools, [])
    end
  end

  describe "output_schema_for/1 (§11.4)" do
    test ":mcp_no_tools returns the v1 schema" do
      v1_schema = Jason.decode!(File.read!(@fixture_path))["outputSchema"]
      # `output_schema_for/1` returns plain Elixir map (string keys); the
      # round-trip via fixture decoding equals byte-equal.
      assert Tools.output_schema_for(:mcp_no_tools) == v1_schema
    end

    test "tool_entry/0 sources outputSchema via output_schema_for/1" do
      assert Tools.tool_entry()["outputSchema"] ==
               Tools.output_schema_for(:mcp_no_tools)
    end
  end
end
