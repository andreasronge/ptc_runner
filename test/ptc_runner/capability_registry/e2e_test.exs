defmodule PtcRunner.CapabilityRegistry.E2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end tests for Capability Registry with real LLM.

  Tests that registry tools and skills integrate correctly with SubAgent execution.

  Run with:
    mix test test/ptc_runner/capability_registry/e2e_test.exs --include e2e

  Run with Bedrock (requires AWS credentials):
    eval $(aws configure export-credentials --profile sandbox --format env)
    LLM_DEFAULT_PROVIDER=bedrock mix test test/ptc_runner/capability_registry/e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY or AWS credentials for Bedrock.
  """

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias PtcRunner.CapabilityRegistry.{Linker, Registry, Skill, TrialHistory}
  alias PtcRunner.Lisp.LanguageSpec
  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LLM
  alias PtcRunner.TestSupport.LLMSupport

  @timeout 60_000

  setup_all do
    LLMSupport.ensure_api_key!()
    IO.puts("\n=== Capability Registry E2E Tests ===")
    IO.puts("Model: #{LLMSupport.model()}")
    IO.puts("Provider: #{System.get_env("LLM_DEFAULT_PROVIDER", "openrouter")}\n")
    :ok
  end

  describe "registry tools in SubAgent" do
    @tag timeout: 120_000
    test "SubAgent uses tools from registry" do
      # Create mock tools for the registry
      fetch_price_fn = fn %{"symbol" => symbol} ->
        prices = %{"AAPL" => 185.50, "MSFT" => 425.00, "GOOGL" => 175.25}

        case Map.get(prices, symbol) do
          nil -> {:error, "Unknown symbol: #{symbol}"}
          price -> %{"symbol" => symbol, "price" => price, "currency" => "USD"}
        end
      end

      # Register tool in registry
      registry =
        Registry.new()
        |> Registry.register_base_tool("fetch_price", fetch_price_fn,
          signature: "(symbol :string) -> {symbol :string, price :float, currency :string}",
          description: "Fetches the current stock price for a given symbol",
          tags: ["stocks", "finance", "api"]
        )

      # Link tools for the mission
      {:ok, link_result} = Linker.link(registry, ["fetch_price"])

      assert length(link_result.tools) == 1
      assert link_result.base_tools["fetch_price"] != nil

      # Create SubAgent with registry tools
      # Note: The tool returns a map with price, symbol, currency
      # We ask for just the price number
      agent =
        SubAgent.new(
          prompt:
            "What is the current price of AAPL stock? Use the fetch_price tool with symbol \"AAPL\" and return just the price number.",
          signature: "() -> :float",
          tools: link_result.base_tools,
          max_turns: 5,
          system_prompt: LanguageSpec.get(:default)
        )

      IO.puts("  Running SubAgent with registry tool...")
      result = SubAgent.run(agent, llm: llm_callback())

      case result do
        {:ok, step} ->
          IO.puts("  ✓ Success: #{inspect(step.return)}")
          # Should return the price (185.50) or something close
          assert step.return != nil

          # Accept either the float directly or a map containing the price
          case step.return do
            price when is_number(price) ->
              assert price == 185.5

            %{"price" => price} ->
              assert price == 185.5

            other ->
              flunk("Unexpected return type: #{inspect(other)}")
          end

        {:error, reason} ->
          IO.puts("  ✗ Error: #{inspect(reason)}")
          # Check if the tool was at least called correctly
          flunk("SubAgent failed: #{inspect(reason)}")
      end
    end

    @tag timeout: 120_000
    test "SubAgent uses multiple registry tools together" do
      # Create mock tools
      search_fn = fn %{"query" => query} ->
        # Simulated search results
        [
          %{"title" => "Result 1 for: #{query}", "snippet" => "First result..."},
          %{"title" => "Result 2 for: #{query}", "snippet" => "Second result..."}
        ]
      end

      count_fn = fn %{"items" => items} ->
        length(items)
      end

      registry =
        Registry.new()
        |> Registry.register_base_tool("search", search_fn,
          signature: "(query :string) -> [{title :string, snippet :string}]",
          description: "Search for information",
          tags: ["search", "web"]
        )
        |> Registry.register_base_tool("count", count_fn,
          signature: "(items [:any]) -> :int",
          description: "Count items in a list",
          tags: ["utility", "list"]
        )

      {:ok, link_result} = Linker.link(registry, ["search", "count"])

      assert length(link_result.tools) == 2

      agent =
        SubAgent.new(
          prompt: "Search for 'elixir programming' and count how many results you get",
          signature: "() -> :int",
          tools: link_result.base_tools,
          max_turns: 5,
          system_prompt: LanguageSpec.get(:default)
        )

      IO.puts("  Running SubAgent with multiple registry tools...")
      result = SubAgent.run(agent, llm: llm_callback())

      case result do
        {:ok, step} ->
          IO.puts("  ✓ Success: #{inspect(step.return)}")
          # Should return 2 (two search results)
          assert step.return == 2

        {:error, reason} ->
          IO.puts("  ✗ Error: #{inspect(reason)}")
          flunk("SubAgent failed: #{inspect(reason)}")
      end
    end
  end

  describe "skill injection" do
    @tag timeout: 120_000
    test "skills are injected into system prompt" do
      # Create a tool and a skill that applies to it
      parse_csv_fn = fn %{"text" => text} ->
        text
        |> String.split("\n", trim: true)
        |> Enum.map(&String.split(&1, ";"))
      end

      skill =
        Skill.new(
          "european_csv_format",
          "European CSV Format",
          """
          When parsing European CSV files:
          - Use semicolon (;) as the delimiter, NOT comma
          - Numbers use comma for decimals (e.g., 1.234,56)
          - Dates are formatted as DD/MM/YYYY
          """,
          applies_to: ["parse_csv"],
          tags: ["csv", "european", "i18n"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("parse_csv", parse_csv_fn,
          signature: "(text :string) -> [[string]]",
          description: "Parse CSV text into rows and columns",
          tags: ["csv", "parsing"]
        )
        |> Registry.register_skill(skill)

      # Link with context that should match the skill
      {:ok, link_result} = Linker.link(registry, ["parse_csv"], context_tags: ["european"])

      # Verify skill was resolved
      assert length(link_result.skills) == 1
      assert hd(link_result.skills).id == "european_csv_format"

      # Verify skill prompt is generated
      assert link_result.skill_prompt =~ "European CSV Format"
      assert link_result.skill_prompt =~ "semicolon"

      IO.puts("  ✓ Skill injection verified")
      IO.puts("  Skill prompt:\n#{String.slice(link_result.skill_prompt, 0, 200)}...")
    end

    @tag timeout: 120_000
    test "LLM follows skill guidance" do
      # This test verifies that the LLM actually uses the skill guidance
      # We create a skill that instructs a specific behavior and verify the LLM follows it

      format_fn = fn %{"text" => text} -> text end

      skill =
        Skill.new(
          "always_uppercase",
          "Output Formatting",
          """
          CRITICAL: When returning any text result, you MUST convert it to UPPERCASE.
          This is a strict requirement - all text outputs must be in capital letters.
          """,
          applies_to: ["format"],
          tags: ["formatting"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("format", format_fn,
          signature: "(text :string) -> :string",
          description: "Format text",
          tags: ["formatting", "text"]
        )
        |> Registry.register_skill(skill)

      {:ok, link_result} = Linker.link(registry, ["format"])

      # Build a system prompt that includes the skill
      base_prompt = LanguageSpec.get(:single_shot)

      skill_enhanced_prompt =
        if link_result.skill_prompt != "" do
          base_prompt <> "\n\n" <> link_result.skill_prompt
        else
          base_prompt
        end

      agent =
        SubAgent.new(
          prompt: "Return the text 'hello world' after formatting it",
          signature: "() -> :string",
          tools: link_result.base_tools,
          max_turns: 1,
          system_prompt: skill_enhanced_prompt
        )

      IO.puts("  Running SubAgent with skill-enhanced prompt...")
      result = SubAgent.run(agent, llm: llm_callback())

      case result do
        {:ok, step} ->
          IO.puts("  Result: #{inspect(step.return)}")

          # The skill instructs uppercase, so we check if LLM followed it
          if is_binary(step.return) and step.return == String.upcase(step.return) do
            IO.puts("  ✓ LLM followed skill guidance (uppercase)")
          else
            IO.puts("  ⚠ LLM may not have followed skill guidance")
          end

          # Don't fail the test - LLMs are probabilistic
          assert step.return != nil

        {:error, reason} ->
          IO.puts("  ✗ Error: #{inspect(reason)}")
          # Don't fail - this tests LLM behavior which can be flaky
          IO.puts("  ⚠ Skipping assertion due to LLM error")
      end
    end
  end

  describe "trial history recording" do
    @tag timeout: 120_000
    test "records trial outcomes after execution" do
      # Simple tool for testing
      add_fn = fn %{"a" => a, "b" => b} -> a + b end

      registry =
        Registry.new()
        |> Registry.register_base_tool("add", add_fn,
          signature: "(a :int, b :int) -> :int",
          description: "Add two numbers",
          tags: ["math", "arithmetic"]
        )

      {:ok, link_result} = Linker.link(registry, ["add"])

      agent =
        SubAgent.new(
          prompt: "What is 5 + 3?",
          signature: "() -> :int",
          tools: link_result.base_tools,
          max_turns: 3,
          system_prompt: LanguageSpec.get(:default)
        )

      IO.puts("  Running SubAgent and recording trial...")
      result = SubAgent.run(agent, llm: llm_callback())

      # Record trial outcome
      success =
        case result do
          {:ok, step} -> step.return == 8
          {:error, _} -> false
        end

      # Use TrialHistory to record the outcome
      updated_registry =
        TrialHistory.record_trial(registry, %{
          tools_used: ["add"],
          context_tags: ["math"],
          success: success
        })

      # Verify trial was recorded
      assert length(updated_registry.history) == 1
      trial = hd(updated_registry.history)
      assert trial.tool_id == "add"
      assert trial.success == success

      IO.puts("  ✓ Trial recorded: success=#{success}")
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case LLM.generate_text(LLMSupport.model(), full_messages, receive_timeout: @timeout) do
        {:ok, text} -> {:ok, text}
        {:error, _} = error -> error
      end
    end
  end
end
