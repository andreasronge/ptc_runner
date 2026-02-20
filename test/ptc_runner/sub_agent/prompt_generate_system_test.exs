defmodule PtcRunner.SubAgent.PromptGenerateSystemTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.SystemPrompt

  describe "generate_system/2" do
    test "returns only static sections (language ref and output format)" do
      agent = SubAgent.new(prompt: "Test task", tools: %{"search" => fn _ -> [] end})

      system = SystemPrompt.generate_system(agent)

      # Should have static sections
      assert system =~ "<role>"
      assert system =~ "<output_format>"

      # Should NOT have dynamic sections
      refute system =~ "# Data Inventory"
      refute system =~ "# Available Tools"
      refute system =~ "# Expected Output"
      refute system =~ "<mission>"
    end

    test "returns stable output for same agent config" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      system1 = SystemPrompt.generate_system(agent)
      system2 = SystemPrompt.generate_system(agent)

      assert system1 == system2
    end

    test "uses single_shot language spec for max_turns: 1" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      system = SystemPrompt.generate_system(agent)

      # Single-shot should not have multi-turn memory docs
      refute system =~ "Memory: Persisting Data Between Turns"
    end

    test "uses multi_turn language spec for max_turns > 1" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      system = SystemPrompt.generate_system(agent)

      # Multi-turn should have state persistence docs
      assert system =~ "<state>"
    end

    test "applies customization prefix and suffix" do
      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{prefix: "PREFIX:", suffix: ":SUFFIX"}
        )

      system = SystemPrompt.generate_system(agent)

      assert String.starts_with?(system, "PREFIX:")
      assert String.ends_with?(system, ":SUFFIX")
    end

    test "string override replaces static sections" do
      agent = SubAgent.new(prompt: "Test", system_prompt: "Custom system prompt")

      system = SystemPrompt.generate_system(agent)

      assert system == "Custom system prompt"
    end

    test "function transformer is applied" do
      agent = SubAgent.new(prompt: "Test", system_prompt: fn p -> "<<" <> p <> ">>" end)

      system = SystemPrompt.generate_system(agent)

      assert String.starts_with?(system, "<<")
      assert String.ends_with?(system, ">>")
    end

    test "journal sections absent by default (journaling: false)" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      system = SystemPrompt.generate_system(agent)

      refute system =~ "<journaled_tasks>"
      refute system =~ "<semantic_progress>"
      refute system =~ "step-done"
      refute system =~ "task-reset"
    end

    test "journal sections present when journaling: true" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5, journaling: true)

      system = SystemPrompt.generate_system(agent)

      assert system =~ "<journaled_tasks>"
      assert system =~ "<semantic_progress>"
      assert system =~ "step-done"
      assert system =~ "task-reset"
    end
  end

  describe "generate_static/2" do
    test "is an alias for generate_system/2" do
      agent = SubAgent.new(prompt: "Test task", tools: %{"search" => fn _ -> [] end})

      assert SystemPrompt.generate_static(agent) == SystemPrompt.generate_system(agent)
    end
  end
end
