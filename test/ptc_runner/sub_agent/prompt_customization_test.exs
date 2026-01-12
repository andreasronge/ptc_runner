defmodule PtcRunner.SubAgent.PromptCustomizationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.SystemPrompt

  describe "customization" do
    test "prefix prepends to generated prompt" do
      agent =
        SubAgent.new(
          prompt: "Analyze data",
          system_prompt: %{prefix: "You are an expert analyst."}
        )

      prompt = SystemPrompt.generate(agent, context: %{data: [1, 2, 3]})

      assert String.starts_with?(prompt, "You are an expert analyst.")
      assert prompt =~ "# Role"
      assert prompt =~ "data/data"
    end

    test "suffix appends to generated prompt" do
      agent =
        SubAgent.new(
          prompt: "Analyze data",
          system_prompt: %{suffix: "Always explain your reasoning."}
        )

      prompt = SystemPrompt.generate(agent, context: %{data: [1, 2, 3]})

      assert String.ends_with?(prompt, "Always explain your reasoning.")
      assert prompt =~ "# Role"
      assert prompt =~ "data/data"
    end

    test "prefix and suffix work together" do
      agent =
        SubAgent.new(
          prompt: "Analyze data",
          system_prompt: %{
            prefix: "You are an expert analyst.",
            suffix: "Always explain your reasoning."
          }
        )

      prompt = SystemPrompt.generate(agent, context: %{data: [1, 2, 3]})

      assert String.starts_with?(prompt, "You are an expert analyst.")
      assert String.ends_with?(prompt, "Always explain your reasoning.")
      assert prompt =~ "data/data"
    end

    test "language_spec replaces language section" do
      custom_lang = "Use Python-like syntax only."

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{language_spec: custom_lang}
        )

      prompt = SystemPrompt.generate(agent, context: %{})

      assert prompt =~ custom_lang
      refute prompt =~ "Clojure-inspired"
    end

    test "language_spec atom resolves to prompt profile" do
      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{language_spec: :single_shot}
        )

      prompt = SystemPrompt.generate(agent, context: %{})
      assert prompt =~ "PTC-Lisp"
      assert prompt =~ "PTC Extensions"
      # single_shot should not have memory docs
      refute prompt =~ "Memory: Persisting Data Between Turns"
    end

    test "language_spec callback receives resolution context" do
      callback = fn ctx ->
        "turn:#{ctx.turn}"
      end

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{language_spec: callback}
        )

      prompt =
        SystemPrompt.generate(agent,
          context: %{},
          resolution_context: %{turn: 2, model: :test, memory: %{}, messages: []}
        )

      assert prompt =~ "turn:2"
    end

    test "output_format replaces output section" do
      custom_output = "Return JSON only."

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{output_format: custom_output}
        )

      prompt = SystemPrompt.generate(agent, context: %{})

      assert prompt =~ custom_output
      # Check the Output Format section was replaced (not in code examples elsewhere)
      refute prompt =~ "# Output Format\n\nRespond with a single ```clojure"
    end

    test "function transformer modifies prompt" do
      transformer = fn prompt -> String.upcase(prompt) end

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: transformer
        )

      prompt = SystemPrompt.generate(agent, context: %{})

      assert prompt == String.upcase(prompt)
      assert prompt =~ "# ROLE"
    end

    test "string override bypasses generation entirely" do
      override = "Custom prompt completely replacing default"

      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: override
        )

      prompt = SystemPrompt.generate(agent, context: %{data: 123})

      assert prompt == override
      refute prompt =~ "# Role"
    end

    test "nil system_prompt uses default generation" do
      agent = SubAgent.new(prompt: "Test", system_prompt: nil)

      prompt = SystemPrompt.generate(agent, context: %{})

      assert prompt =~ "## Role"
      assert prompt =~ "thinking:"
    end
  end
end
