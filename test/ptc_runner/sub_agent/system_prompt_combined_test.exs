defmodule PtcRunner.SubAgent.SystemPromptCombinedTest do
  @moduledoc """
  Tier 3e — combined-mode (`output: :text, ptc_transport: :tool_call`)
  system-prompt tests.

  Validates that the compact PTC-Lisp reference card is appended to
  combined-mode prompts only, that the dynamic tool inventory lists
  `:both`- and `:ptc_lisp`-exposed tools, and that pure text and pure
  PTC-Lisp prompts are unaffected.

  Per Addendum #19, the static card MUST be present even when zero
  PTC-callable tools exist.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.PromptRegistry
  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.SystemPrompt

  # Pin a few stable substrings from the static card so we can detect
  # presence/absence without coupling to the full prose.
  @card_core_form "`def`"
  @card_full_result_cached "full_result_cached"
  @card_unsupported_forms "No `let*`, `lambda`"
  @card_section_open "<ptc_lisp_reference>"

  describe "combined mode (output: :text, ptc_transport: :tool_call)" do
    test "generate/2 appends the compact reference card" do
      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text,
          ptc_transport: :tool_call
        )

      prompt = SystemPrompt.generate(agent)

      assert prompt =~ @card_section_open
      assert prompt =~ @card_core_form
      assert prompt =~ @card_unsupported_forms
      assert prompt =~ @card_full_result_cached
    end

    test "generate_system/2 (static path) also includes the card" do
      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text,
          ptc_transport: :tool_call
        )

      static = SystemPrompt.generate_system(agent)

      assert static =~ @card_section_open
      assert static =~ @card_unsupported_forms
    end

    test "compact card is sourced from the internal prompt registry" do
      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text,
          ptc_transport: :tool_call
        )

      assert SystemPrompt.combined_mode_reference_card(agent) ==
               PromptRegistry.render(:ptc_text_mode_compact_reference)

      metadata = PromptRegistry.card_metadata(:ptc_text_mode_compact_reference)
      assert metadata.surface == :combined_text_ptc
      assert metadata.audience == :combined_text_ptc_system_prompt
      assert metadata.dynamic_boundary == :before_dynamic_tool_inventory
      assert metadata.placement == :combined_ptc_reference
    end

    test ":both-exposed tools are listed in the PTC tool inventory" do
      tools = %{
        "search_logs" =>
          {fn _ -> [] end,
           signature: "(query :string) -> [:any]",
           description: "Search logs",
           expose: :both,
           cache: true}
      }

      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text,
          ptc_transport: :tool_call,
          tools: tools
        )

      prompt = SystemPrompt.generate(agent)

      assert prompt =~ "<ptc_tools>"
      assert prompt =~ "(tool/search_logs {...})"
    end

    test ":ptc_lisp-only tools are listed in the inventory (only place advertised)" do
      tools = %{
        "compute_score" =>
          {fn _ -> 0.0 end,
           signature: "(x :int) -> :float", description: "Compute a score", expose: :ptc_lisp}
      }

      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text,
          ptc_transport: :tool_call,
          tools: tools
        )

      prompt = SystemPrompt.generate(agent)

      assert prompt =~ "<ptc_tools>"
      assert prompt =~ "(tool/compute_score {...})"
    end

    test ":native-only tools are NOT listed in the PTC inventory" do
      tools = %{
        "fire_missile" => {fn _ -> :ok end, signature: "() -> :string", expose: :native}
      }

      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text,
          ptc_transport: :tool_call,
          tools: tools
        )

      prompt = SystemPrompt.generate(agent)

      # Static card always included
      assert prompt =~ @card_section_open
      # Native-only tool must not appear in the PTC inventory section
      refute prompt =~ "(tool/fire_missile {...})"
    end

    test "card is included even with zero :both/:ptc_lisp tools (Addendum #19)" do
      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text,
          ptc_transport: :tool_call
        )

      prompt = SystemPrompt.generate(agent)

      # Static reference card MUST be present
      assert prompt =~ @card_section_open
      assert prompt =~ @card_unsupported_forms
      # No tools to list — the dynamic inventory section is omitted
      refute prompt =~ "<ptc_tools>"
    end

    test "compact card does not include MCP aggregator-only call semantics" do
      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text,
          ptc_transport: :tool_call
        )

      prompt = SystemPrompt.generate(agent)

      refute prompt =~ "tool/call"
      refute prompt =~ ":json-null"
      refute prompt =~ "World-fault"
      refute prompt =~ "upstream_calls"
    end
  end

  describe "non-combined modes do NOT receive the card" do
    test "pure text mode (no ptc_transport) does NOT include the card" do
      agent =
        SubAgent.new(
          prompt: "do work",
          output: :text
        )

      prompt = SystemPrompt.generate(agent)

      refute prompt =~ @card_section_open
      refute prompt =~ @card_unsupported_forms
    end

    test "pure :ptc_lisp mode prompt does NOT include the card" do
      agent =
        SubAgent.new(
          prompt: "do work",
          output: :ptc_lisp
        )

      prompt = SystemPrompt.generate(agent)

      refute prompt =~ @card_section_open
    end

    test ":ptc_lisp + ptc_transport: :tool_call also does NOT include the card" do
      # Combined-mode card is text-mode-only; tool_call PTC-Lisp transport
      # already has its own reference plumbing.
      agent =
        SubAgent.new(
          prompt: "do work",
          output: :ptc_lisp,
          ptc_transport: :tool_call
        )

      prompt = SystemPrompt.generate(agent)

      refute prompt =~ @card_section_open
    end
  end
end
