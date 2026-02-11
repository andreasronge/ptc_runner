defmodule PtcRunner.SubAgent.PromptGenerateTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.SystemPrompt

  doctest PtcRunner.SubAgent.SystemPrompt

  describe "generate/2" do
    test "generates complete system prompt with all sections" do
      agent = SubAgent.new(prompt: "Process data", tools: %{"search" => fn _ -> [] end})
      context = %{user: "Alice"}

      prompt = SystemPrompt.generate(agent, context: context)

      # Check all major sections are present
      assert prompt =~ "## Role"
      assert prompt =~ "Write programs that accomplish the user's mission"
      refute prompt =~ "thinking:"
      assert prompt =~ ";; === data/ ==="
      assert prompt =~ ";; === tools ==="
      assert prompt =~ "## PTC-Lisp"
      assert prompt =~ "# Output Format"
      assert prompt =~ "# Mission"
    end

    test "includes context variables in data inventory" do
      agent = SubAgent.new(prompt: "Test")
      context = %{user_id: 123, name: "Bob"}

      prompt = SystemPrompt.generate(agent, context: context)

      assert prompt =~ "data/user_id"
      assert prompt =~ "data/name"
    end

    test "includes tools in tool schemas" do
      tools = %{"search" => fn _ -> [] end, "fetch" => fn _ -> %{} end}
      agent = SubAgent.new(prompt: "Test", tools: tools)

      prompt = SystemPrompt.generate(agent, context: %{})

      assert prompt =~ "tool/search"
      assert prompt =~ "tool/fetch"
    end

    test "expands mission template with context" do
      agent = SubAgent.new(prompt: "Find emails for {{user}}")
      context = %{user: "Alice"}

      prompt = SystemPrompt.generate(agent, context: context)

      assert prompt =~ "Find emails for Alice"
    end

    test "handles missing template variables gracefully" do
      agent = SubAgent.new(prompt: "Find emails for {{user}}")
      context = %{}

      prompt = SystemPrompt.generate(agent, context: context)

      # Should keep original template if expansion fails
      assert prompt =~ "Find emails for {{user}}"
    end

    test "works with empty context and no tools" do
      agent = SubAgent.new(prompt: "Simple task")

      prompt = SystemPrompt.generate(agent, context: %{})

      assert prompt =~ "# Role"
      assert prompt =~ "Simple task"
    end
  end

  describe "error_recovery_prompt" do
    test "generates error recovery prompt" do
      error = %{type: :parse_error, message: "Unexpected token at position 45"}

      recovery = SystemPrompt.generate_error_recovery_prompt(error)

      assert recovery =~ "# Previous Turn Error"
      assert recovery =~ "parse_error"
      assert recovery =~ "Unexpected token at position 45"
      assert recovery =~ "```clojure code block"
    end

    test "handles missing error fields" do
      error = %{}

      recovery = SystemPrompt.generate_error_recovery_prompt(error)

      assert recovery =~ "# Previous Turn Error"
      assert recovery =~ "unknown_error"
    end

    test "error context is appended to prompt" do
      agent = SubAgent.new(prompt: "Test")
      error = %{type: :parse_error, message: "Bad syntax"}

      prompt = SystemPrompt.generate(agent, context: %{}, error_context: error)

      assert prompt =~ "# Role"
      assert prompt =~ "# Previous Turn Error"
      assert prompt =~ "Bad syntax"
    end
  end

  describe "truncation" do
    test "does not truncate when no limit set" do
      long_prompt = String.duplicate("x", 10_000)

      result = SystemPrompt.truncate_if_needed(long_prompt, nil)

      assert result == long_prompt
    end

    test "does not truncate when under limit" do
      short_prompt = "Short prompt"

      result = SystemPrompt.truncate_if_needed(short_prompt, %{max_chars: 1000})

      assert result == short_prompt
    end

    @tag :capture_log
    test "truncates when over limit" do
      long_prompt = String.duplicate("x", 1000)

      result = SystemPrompt.truncate_if_needed(long_prompt, %{max_chars: 100})

      assert String.length(result) > 100
      assert String.length(result) < 300
      assert result =~ "truncated"
    end

    @tag :capture_log
    test "truncation preserves beginning of prompt" do
      prompt = "# Role\n\nImportant content" <> String.duplicate("x", 1000)

      result = SystemPrompt.truncate_if_needed(prompt, %{max_chars: 100})

      assert result =~ "# Role"
      assert result =~ "Important content"
    end

    @tag :capture_log
    test "truncation with agent applies to final prompt" do
      # Create an agent with lots of tools and data
      tools =
        Map.new(1..50, fn i ->
          {"tool_#{i}", fn _ -> :ok end}
        end)

      agent =
        SubAgent.new(
          prompt: "Process everything",
          tools: tools,
          prompt_limit: %{max_chars: 500}
        )

      context = Map.new(1..50, fn i -> {"key_#{i}", "value_#{i}"} end)

      prompt = SystemPrompt.generate(agent, context: context)

      assert String.length(prompt) < 1000
      assert prompt =~ "truncated"
    end
  end

  describe "integration" do
    test "E2E: generates complete prompt for realistic agent" do
      tools = %{
        "search" => fn _ -> [] end,
        "send_email" => fn _ -> :ok end
      }

      agent =
        SubAgent.new(
          prompt: "Find urgent emails for {{user}} and send replies",
          signature: "(user :string) -> {count :int}",
          tools: tools
        )

      context = %{user: "Alice", emails: [%{id: 1, subject: "Urgent"}]}

      prompt = SystemPrompt.generate(agent, context: context)

      # Role section
      assert prompt =~ "## Role"

      # Data inventory
      assert prompt =~ "data/user"
      assert prompt =~ "data/emails"

      # Tools
      assert prompt =~ "search"
      assert prompt =~ "send_email"

      # Mission with expanded template
      assert prompt =~ "Find urgent emails for Alice"

      # PTC-Lisp reference (tool/ syntax for tool invocation)
      assert prompt =~ "(tool/search"

      # Output format
      assert prompt =~ "```clojure"
    end

    test "includes Expected Output section when signature is present" do
      agent =
        SubAgent.new(
          prompt: "Test",
          signature: "(x :int) -> {count :int, ids [:string]}"
        )

      prompt = SystemPrompt.generate(agent, context: %{x: 10})

      assert prompt =~ "# Expected Output"
      assert prompt =~ "Your final answer must match this format: `{count :int, ids [:string]}`"
      assert prompt =~ "Call `(return {:count 42, :ids []})` when complete."
    end

    test "omits Expected Output section when signature is nil" do
      agent = SubAgent.new(prompt: "Test")
      prompt = SystemPrompt.generate(agent, context: %{})

      refute prompt =~ "# Expected Output"
    end

    test "handles different return types in examples" do
      # Int
      agent = SubAgent.new(prompt: "T", signature: ":int")
      assert SystemPrompt.generate(agent) =~ "(return 42)"

      # String
      agent = SubAgent.new(prompt: "T", signature: ":string")
      assert SystemPrompt.generate(agent) =~ "(return \"result\")"

      # Boolean
      agent = SubAgent.new(prompt: "T", signature: ":bool")
      assert SystemPrompt.generate(agent) =~ "(return true)"

      # List
      agent = SubAgent.new(prompt: "T", signature: "[:int]")
      assert SystemPrompt.generate(agent) =~ "(return [])"

      # Nested Map
      agent = SubAgent.new(prompt: "T", signature: "{a {b :int}}")
      assert SystemPrompt.generate(agent) =~ "(return {:a {:b 42}})"
    end

    test "handles firewalled fields in signatures" do
      # Firewalled fields should be visible in the expected output format
      agent = SubAgent.new(prompt: "T", signature: "{_id :int, status :string}")
      prompt = SystemPrompt.generate(agent)

      assert prompt =~ "{_id :int, status :string}"
      assert prompt =~ "(return {:_id 42, :status \"result\"})"
    end

    test "handles agent with signature but no tools" do
      agent =
        SubAgent.new(
          prompt: "Calculate {{x}} + {{y}}",
          signature: "(x :int, y :int) -> :int"
        )

      context = %{x: 5, y: 3}

      prompt = SystemPrompt.generate(agent, context: context)

      assert prompt =~ "Calculate 5 + 3"
      assert prompt =~ "data/x"
      assert prompt =~ "data/y"
    end

    test "handles very long tool names gracefully" do
      tools = %{
        "very_long_named_tool_with_lots_of_words" => fn _ -> "result" end
      }

      agent = SubAgent.new(prompt: "Test", tools: tools)

      prompt = SystemPrompt.generate(agent, context: %{})

      # Should not error and should include the tool
      assert prompt =~ "very_long_named_tool_with_lots_of_words"
    end

    test "handles large nested maps in context" do
      context = %{
        config: %{
          setting1: "value1",
          setting2: "value2",
          setting3: "value3",
          setting4: "value4"
        }
      }

      prompt = SystemPrompt.generate(SubAgent.new(prompt: "Test"), context: context)

      # Should handle gracefully without erroring
      assert prompt =~ "data/config"
    end
  end
end
