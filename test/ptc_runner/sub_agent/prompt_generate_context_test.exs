defmodule PtcRunner.SubAgent.PromptGenerateContextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.SystemPrompt

  describe "generate_context/2" do
    test "includes dynamic sections in compact format" do
      agent = SubAgent.new(prompt: "Test", tools: %{"search" => fn _ -> [] end})
      context = %{user: "Alice", count: 5}

      context_prompt = SystemPrompt.generate_context(agent, context: context)

      # Should have compact format sections
      assert context_prompt =~ ";; === tools ==="
      assert context_prompt =~ ";; === data/ ==="
      assert context_prompt =~ "data/user"
      assert context_prompt =~ "data/count"
      assert context_prompt =~ "tool/search"

      # Should NOT have static sections
      refute context_prompt =~ "## Role"
      refute context_prompt =~ "# Output Format"
      # Should NOT have old markdown format
      refute context_prompt =~ "# Data Inventory"
      refute context_prompt =~ "# Available Tools"
    end

    test "does not include mission" do
      agent = SubAgent.new(prompt: "This is the mission")

      context_prompt = SystemPrompt.generate_context(agent, context: %{})

      refute context_prompt =~ "# Mission"
      refute context_prompt =~ "This is the mission"
    end

    test "includes Expected Output when signature is present" do
      agent = SubAgent.new(prompt: "Test", signature: "(x :int) -> {count :int}")

      context_prompt = SystemPrompt.generate_context(agent, context: %{x: 5})

      assert context_prompt =~ "# Expected Output"
      assert context_prompt =~ "{count :int}"
    end

    test "return/fail are NOT in context (they are in system prompt)" do
      # return/fail are documented in system prompt, not in user context
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      context_prompt = SystemPrompt.generate_context(agent, context: %{})

      # return/fail should NOT be in context - they're in system prompt
      refute context_prompt =~ "### return"
      refute context_prompt =~ "### fail"
    end

    test "merges field descriptions from upstream" do
      agent = SubAgent.new(prompt: "Test", context_descriptions: %{user: "Local desc"})

      context_prompt =
        SystemPrompt.generate_context(agent,
          context: %{user: "Alice", items: [1, 2]},
          received_field_descriptions: %{items: "Received desc"}
        )

      # Both descriptions should appear
      assert context_prompt =~ "Local desc"
      assert context_prompt =~ "Received desc"
    end
  end
end
