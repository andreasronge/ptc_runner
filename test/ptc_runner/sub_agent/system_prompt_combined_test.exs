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

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.SystemPrompt

  # Pin a few stable substrings from the static card so we can detect
  # presence/absence without coupling to the full prose.
  @card_def_form "(def name value)"
  @card_full_result_cached "full_result_cached"
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
      assert prompt =~ @card_def_form
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
      assert static =~ @card_def_form
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
      assert prompt =~ @card_def_form
      # No tools to list — the dynamic inventory section is omitted
      refute prompt =~ "<ptc_tools>"
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
      refute prompt =~ @card_def_form
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
