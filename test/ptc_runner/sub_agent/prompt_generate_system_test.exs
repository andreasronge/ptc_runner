defmodule PtcRunner.SubAgent.PromptGenerateSystemTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Prompt

  describe "generate_system/2" do
    test "returns only static sections (language ref and output format)" do
      agent = SubAgent.new(prompt: "Test task", tools: %{"search" => fn _ -> [] end})

      system = Prompt.generate_system(agent)

      # Should have static sections
      assert system =~ "## Role"
      assert system =~ "# Output Format"

      # Should NOT have dynamic sections
      refute system =~ "# Data Inventory"
      refute system =~ "# Available Tools"
      refute system =~ "# Expected Output"
      refute system =~ "# Mission"
    end

    test "returns stable output for same agent config" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      system1 = Prompt.generate_system(agent)
      system2 = Prompt.generate_system(agent)

      assert system1 == system2
    end

    test "uses single_shot language spec for max_turns: 1" do
      agent = SubAgent.new(prompt: "Test", max_turns: 1)

      system = Prompt.generate_system(agent)

      # Single-shot should not have multi-turn memory docs
      refute system =~ "Memory: Persisting Data Between Turns"
    end

    test "uses multi_turn language spec for max_turns > 1" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      system = Prompt.generate_system(agent)

      # Multi-turn should have state persistence docs
      assert system =~ "### State Persistence"
    end

    test "applies customization prefix and suffix" do
      agent =
        SubAgent.new(
          prompt: "Test",
          system_prompt: %{prefix: "PREFIX:", suffix: ":SUFFIX"}
        )

      system = Prompt.generate_system(agent)

      assert String.starts_with?(system, "PREFIX:")
      assert String.ends_with?(system, ":SUFFIX")
    end

    test "string override replaces static sections" do
      agent = SubAgent.new(prompt: "Test", system_prompt: "Custom system prompt")

      system = Prompt.generate_system(agent)

      assert system == "Custom system prompt"
    end

    test "function transformer is applied" do
      agent = SubAgent.new(prompt: "Test", system_prompt: fn p -> "<<" <> p <> ">>" end)

      system = Prompt.generate_system(agent)

      assert String.starts_with?(system, "<<")
      assert String.ends_with?(system, ">>")
    end
  end
end
