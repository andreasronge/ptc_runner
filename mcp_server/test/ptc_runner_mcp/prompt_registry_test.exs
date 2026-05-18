defmodule PtcRunnerMcp.PromptRegistryTest do
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.PromptRegistry

  @forbidden_runtime_patterns [
    "<!--",
    "PTC_PROMPT_START",
    "PTC_PROMPT_END",
    "docs/",
    "Plans/",
    "priv/prompts/README.md",
    "hexdocs.pm/ptc_runner",
    "Full reference:",
    "see docs"
  ]

  @required_card_fields MapSet.new([
                          :audience,
                          :budget_profile,
                          :dimensions,
                          :dynamic_boundary,
                          :id,
                          :placement,
                          :profile,
                          :surface,
                          :trust
                        ])

  @dimensions MapSet.new([
                :catalog_discovery,
                :completion_contract,
                :dialect,
                :execution_surface,
                :trust_boundary
              ])

  @audiences MapSet.new([
               :mcp_agentic_planner_system_prompt,
               :mcp_tool_description
             ])

  @budget_profiles MapSet.new([
                     :compact,
                     :minimal,
                     :standard
                   ])

  @dynamic_boundaries MapSet.new([
                        :before_dynamic_catalog,
                        :dynamic_catalog,
                        :operator_text,
                        :static_card,
                        :terminal_authoritative_card
                      ])

  @profiles MapSet.new([
              :mcp_aggregator,
              :mcp_agentic_task,
              :mcp_no_tools,
              :mcp_session
            ])

  @surfaces MapSet.new([
              :mcp_agentic_task,
              :mcp_direct_ptc_lisp_execute,
              :mcp_session
            ])

  @trust_levels MapSet.new([
                  :authoritative,
                  :operator_text,
                  :untrusted_data
                ])

  test "all cards expose complete contract metadata using the MCP vocabulary" do
    Enum.each(PromptRegistry.card_keys(), fn key ->
      metadata = PromptRegistry.card_metadata(key)

      assert metadata.id == key
      assert MapSet.subset?(@required_card_fields, metadata |> Map.keys() |> MapSet.new())
      assert MapSet.member?(@audiences, metadata.audience)
      assert MapSet.member?(@budget_profiles, metadata.budget_profile)
      assert MapSet.member?(@dynamic_boundaries, metadata.dynamic_boundary)
      assert MapSet.member?(@profiles, metadata.profile)
      assert MapSet.member?(@surfaces, metadata.surface)
      assert MapSet.member?(@trust_levels, metadata.trust)

      assert is_list(metadata.dimensions)
      assert metadata.dimensions != []
      assert MapSet.subset?(MapSet.new(metadata.dimensions), @dimensions)
      refute Map.has_key?(metadata, :prompt_fun)
    end)
  end

  test "all profiles reference registered cards and expose metadata in render order" do
    cards = MapSet.new(PromptRegistry.card_keys())

    Enum.each(PromptRegistry.profile_keys(), fn profile ->
      parts = PromptRegistry.profile_parts!(profile)

      assert parts != []
      assert MapSet.subset?(MapSet.new(parts), cards)
      assert Enum.map(PromptRegistry.profile_metadata(profile), & &1.id) == parts
    end)
  end

  test "prompt keys include every profile and card key" do
    expected =
      PromptRegistry.profile_keys()
      |> Kernel.++(PromptRegistry.card_keys())
      |> MapSet.new()

    assert MapSet.new(PromptRegistry.prompt_keys()) == expected
  end

  test "rendered MCP tool descriptions exclude metadata, markers, and authoring references" do
    for key <- [
          :mcp_no_tools_description,
          :mcp_aggregator_description,
          :mcp_session_start_description,
          :mcp_session_eval_description
        ] do
      rendered = PromptRegistry.render(key, catalog: nil)

      assert is_binary(rendered)
      assert byte_size(rendered) <= 2_000

      Enum.each(@forbidden_runtime_patterns, fn pattern ->
        refute String.contains?(rendered, pattern),
               "#{key} contains forbidden runtime prompt pattern #{inspect(pattern)}"
      end)
    end
  end

  test "file-backed MCP cards are extracted before rendering" do
    for key <- [
          :mcp_no_tools_authoring_card,
          :mcp_aggregator_authoring_card,
          :mcp_session_authoring_card
        ] do
      text = PromptRegistry.card_text(key)

      assert is_binary(text)
      assert text != ""
      refute text =~ "<!--"
      refute text =~ "PTC_PROMPT_START"
      refute text =~ "PTC_PROMPT_END"
    end
  end
end
