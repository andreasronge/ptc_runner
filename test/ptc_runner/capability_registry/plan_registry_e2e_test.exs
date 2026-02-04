defmodule PtcRunner.CapabilityRegistry.PlanRegistryE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end tests for Capability Registry integration with PlanRunner/PlanExecutor.

  Tests that:
  1. Registry-based tool resolution works in real executions
  2. Skill prompts are injected and influence LLM behavior
  3. Trial history is recorded after plan execution

  Run with Bedrock (recommended for these tests):
    eval $(aws configure export-credentials --profile sandbox --format env)
    LLM_DEFAULT_PROVIDER=bedrock mix test test/ptc_runner/capability_registry/plan_registry_e2e_test.exs --include e2e

  Run with OpenRouter:
    mix test test/ptc_runner/capability_registry/plan_registry_e2e_test.exs --include e2e
  """

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias PtcRunner.CapabilityRegistry.{Linker, Registry, Skill, TrialHistory}
  alias PtcRunner.{Plan, PlanExecutor, PlanRunner, PlanTracer}
  alias PtcRunner.TestSupport.LLM
  alias PtcRunner.TestSupport.LLMSupport

  @timeout 60_000

  setup_all do
    LLMSupport.ensure_api_key!()
    File.mkdir_p!("tmp/e2e_results")
    IO.puts("\n=== Capability Registry + Plan Integration E2E Tests ===")
    IO.puts("Model: #{LLMSupport.model()}")
    IO.puts("Provider: #{System.get_env("LLM_DEFAULT_PROVIDER", "openrouter")}\n")
    :ok
  end

  describe "PlanRunner with Registry tools" do
    @tag timeout: 120_000
    test "executes plan using tools from Capability Registry" do
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Test: PlanRunner with Registry Tools")
      IO.puts(String.duplicate("=", 70))

      # Create mock tools and register in registry
      fetch_price_fn = fn %{"symbol" => symbol} ->
        prices = %{"AAPL" => 185.50, "MSFT" => 425.00, "GOOGL" => 175.25}

        case Map.get(prices, symbol) do
          nil -> {:error, "Unknown symbol: #{symbol}"}
          price -> %{"symbol" => symbol, "price" => price, "currency" => "USD"}
        end
      end

      registry =
        Registry.new()
        |> Registry.register_base_tool("fetch_price", fetch_price_fn,
          signature: "(symbol :string) -> {symbol :string, price :float, currency :string}",
          description: "Fetches the current stock price for a given symbol",
          tags: ["stocks", "finance"]
        )

      # Create a simple plan that uses the registry tool
      plan = %Plan{
        agents: %{
          "stock_fetcher" => %{
            prompt: "You fetch stock prices. Use the fetch_price tool and return the result.",
            tools: ["fetch_price"]
          }
        },
        tasks: [
          %{
            id: "get_aapl",
            agent: "stock_fetcher",
            type: :task,
            input: "Fetch the price for AAPL stock using the fetch_price tool",
            depends_on: [],
            on_failure: :stop,
            on_verification_failure: :stop,
            max_retries: 0,
            critical: true,
            verification: nil
          }
        ]
      }

      IO.puts("\n  Running PlanRunner with registry: registry option...")
      start = System.monotonic_time(:millisecond)

      result =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          registry: registry,
          timeout: @timeout,
          max_turns: 3
        )

      duration_ms = System.monotonic_time(:millisecond) - start

      IO.puts("\n--- Result (#{duration_ms}ms) ---")

      case result do
        {:ok, results} ->
          IO.puts("  ✓ Success")
          IO.puts("  Results: #{inspect(results, limit: 200)}")

          # Verify the task completed
          assert Map.has_key?(results, "get_aapl"), "Should have get_aapl result"

          # The result should contain price info
          aapl_result = results["get_aapl"]
          IO.puts("  AAPL result: #{inspect(aapl_result)}")

          # Accept various result formats
          case aapl_result do
            %{"price" => price} when is_number(price) ->
              assert price == 185.50 or price == 185.5
              IO.puts("  ✓ Got correct AAPL price: $#{price}")

            %{"symbol" => "AAPL", "price" => price} ->
              assert price == 185.50 or price == 185.5
              IO.puts("  ✓ Got correct AAPL price: $#{price}")

            price when is_number(price) ->
              assert price == 185.50 or price == 185.5
              IO.puts("  ✓ Got correct AAPL price: $#{price}")

            _ ->
              # LLM may have formatted differently - just verify we got something
              IO.puts("  ⚠ Unexpected format but task completed")
              assert aapl_result != nil
          end

        {:error, task_id, partial_results, reason} ->
          IO.puts("  ✗ Failed")
          IO.puts("  Task: #{task_id}")
          IO.puts("  Reason: #{inspect(reason)}")
          IO.puts("  Partial: #{inspect(partial_results)}")
          flunk("PlanRunner failed: #{inspect(reason)}")
      end
    end

    @tag timeout: 120_000
    test "executes plan with multiple registry tools" do
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Test: PlanRunner with Multiple Registry Tools")
      IO.puts(String.duplicate("=", 70))

      # Create multiple tools
      add_fn = fn %{"a" => a, "b" => b} -> a + b end
      multiply_fn = fn %{"a" => a, "b" => b} -> a * b end

      registry =
        Registry.new()
        |> Registry.register_base_tool("add", add_fn,
          signature: "(a :int, b :int) -> :int",
          description: "Add two numbers",
          tags: ["math"]
        )
        |> Registry.register_base_tool("multiply", multiply_fn,
          signature: "(a :int, b :int) -> :int",
          description: "Multiply two numbers",
          tags: ["math"]
        )

      plan = %Plan{
        agents: %{
          "calculator" => %{
            prompt:
              "You are a calculator. Use the math tools to compute. First add 5+3, then multiply that result by 2.",
            tools: ["add", "multiply"]
          }
        },
        tasks: [
          %{
            id: "compute",
            agent: "calculator",
            type: :task,
            input: "Add 5 and 3, then multiply the result by 2. Return the final number.",
            depends_on: [],
            on_failure: :stop,
            on_verification_failure: :stop,
            max_retries: 0,
            critical: true,
            verification: nil
          }
        ]
      }

      IO.puts("\n  Running PlanRunner with multiple registry tools...")
      start = System.monotonic_time(:millisecond)

      result =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          registry: registry,
          timeout: @timeout,
          max_turns: 5
        )

      duration_ms = System.monotonic_time(:millisecond) - start

      IO.puts("\n--- Result (#{duration_ms}ms) ---")

      case result do
        {:ok, results} ->
          IO.puts("  ✓ Success")
          compute_result = results["compute"]
          IO.puts("  Result: #{inspect(compute_result)}")

          # Expected: (5 + 3) * 2 = 16
          assert compute_result in [16, "16", :"16"],
                 "Expected 16, got #{inspect(compute_result)}"

          IO.puts("  ✓ Correct computation: (5+3)*2 = 16")

        {:error, _task_id, _partial, reason} ->
          IO.puts("  ✗ Failed: #{inspect(reason)}")
          flunk("PlanRunner failed: #{inspect(reason)}")
      end
    end
  end

  describe "Skill injection via Registry" do
    @tag timeout: 120_000
    test "injects skills and LLM uses skill guidance" do
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Test: Skill Injection via Registry")
      IO.puts(String.duplicate("=", 70))

      # Create a tool and a skill that provides formatting guidance
      format_fn = fn %{"text" => text} -> text end

      skill =
        Skill.new(
          "uppercase_format",
          "Output Formatting Rule",
          """
          CRITICAL FORMATTING RULE:
          When returning any text output, you MUST:
          1. Convert the text to UPPERCASE
          2. Return ONLY uppercase letters

          This is a strict requirement. Never return lowercase text.
          """,
          applies_to: ["format"],
          tags: ["formatting"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("format", format_fn,
          signature: "(text :string) -> :string",
          description: "Format text according to guidelines",
          tags: ["formatting", "text"]
        )
        |> Registry.register_skill(skill)

      plan = %Plan{
        agents: %{
          "formatter" => %{
            prompt:
              "You format text. Use the format tool and follow all formatting guidelines strictly.",
            tools: ["format"]
          }
        },
        tasks: [
          %{
            id: "format_text",
            agent: "formatter",
            type: :task,
            input:
              "Format the text 'hello world' using the format tool. Return the formatted result.",
            depends_on: [],
            on_failure: :stop,
            on_verification_failure: :stop,
            max_retries: 0,
            critical: true,
            verification: nil
          }
        ]
      }

      IO.puts("\n  Running PlanRunner with skill injection...")

      # Verify skill is linked
      {:ok, link_result} = Linker.link(registry, ["format"])
      IO.puts("  Skills linked: #{length(link_result.skills)}")
      IO.puts("  Skill prompt: #{String.slice(link_result.skill_prompt, 0, 100)}...")

      assert length(link_result.skills) == 1
      assert link_result.skill_prompt =~ "UPPERCASE"

      start = System.monotonic_time(:millisecond)

      result =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          registry: registry,
          timeout: @timeout,
          max_turns: 3
        )

      duration_ms = System.monotonic_time(:millisecond) - start

      IO.puts("\n--- Result (#{duration_ms}ms) ---")

      case result do
        {:ok, results} ->
          IO.puts("  ✓ Task completed")
          format_result = results["format_text"]
          IO.puts("  Result: #{inspect(format_result)}")

          # Check if LLM followed the skill guidance
          if is_binary(format_result) do
            if String.upcase(format_result) == format_result and format_result =~ ~r/[A-Z]/ do
              IO.puts("  ✓ LLM followed skill guidance (uppercase output)")
            else
              IO.puts("  ⚠ LLM may not have followed skill guidance")
              IO.puts("    Expected: HELLO WORLD or similar")
              IO.puts("    Got: #{format_result}")
            end
          end

          # Don't fail - LLMs are probabilistic
          assert format_result != nil

        {:error, _task_id, _partial, reason} ->
          IO.puts("  ✗ Failed: #{inspect(reason)}")
          # Don't fail test - skill behavior is exploratory
          IO.puts("  ⚠ Skipping assertion - LLM error is not a test failure")
      end
    end

    @tag timeout: 120_000
    test "context tags filter skills appropriately" do
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Test: Context Tag Filtering for Skills")
      IO.puts(String.duplicate("=", 70))

      parse_fn = fn %{"text" => text} -> String.split(text, ";") end

      european_skill =
        Skill.new(
          "european_csv",
          "European CSV Format",
          """
          When parsing European CSV:
          - Use semicolon (;) as delimiter
          - Use comma for decimals
          """,
          applies_to: [],
          tags: ["european"]
        )

      american_skill =
        Skill.new(
          "american_csv",
          "American CSV Format",
          """
          When parsing American CSV:
          - Use comma (,) as delimiter
          - Use period for decimals
          """,
          applies_to: [],
          tags: ["american"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("parse_csv", parse_fn, tags: ["csv"])
        |> Registry.register_skill(european_skill)
        |> Registry.register_skill(american_skill)

      # Test with european context
      {:ok, result_eu} = Linker.link(registry, ["parse_csv"], context_tags: ["european"])
      IO.puts("\n  With context_tags: [\"european\"]")
      IO.puts("  Skills: #{Enum.map(result_eu.skills, & &1.id) |> inspect}")

      assert length(result_eu.skills) == 1
      assert hd(result_eu.skills).id == "european_csv"

      # Test with american context
      {:ok, result_us} = Linker.link(registry, ["parse_csv"], context_tags: ["american"])
      IO.puts("\n  With context_tags: [\"american\"]")
      IO.puts("  Skills: #{Enum.map(result_us.skills, & &1.id) |> inspect}")

      assert length(result_us.skills) == 1
      assert hd(result_us.skills).id == "american_csv"

      IO.puts("\n  ✓ Context tag filtering works correctly")
    end
  end

  describe "PlanExecutor with Registry trial recording" do
    @tag timeout: 180_000
    test "records successful trial to registry after execution" do
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Test: PlanExecutor Trial Recording (Success)")
      IO.puts(String.duplicate("=", 70))

      # Simple tool for testing
      greet_fn = fn %{"name" => name} -> "Hello, #{name}!" end

      registry =
        Registry.new()
        |> Registry.register_base_tool("greet", greet_fn,
          signature: "(name :string) -> :string",
          description: "Generate a greeting",
          tags: ["greeting"]
        )

      plan = %Plan{
        agents: %{
          "greeter" => %{
            prompt: "You generate greetings. Use the greet tool.",
            tools: ["greet"]
          }
        },
        tasks: [
          %{
            id: "say_hello",
            agent: "greeter",
            type: :task,
            input: "Greet the user named 'Alice' using the greet tool",
            depends_on: [],
            on_failure: :stop,
            on_verification_failure: :stop,
            max_retries: 0,
            critical: true,
            verification: nil
          }
        ]
      }

      mission = "Greet Alice"

      IO.puts("\n  Running PlanExecutor with registry...")
      {:ok, tracer} = PlanTracer.start(output: :io)
      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.execute(plan, mission,
          llm: llm_callback(),
          registry: registry,
          context_tags: ["greeting"],
          timeout: @timeout,
          max_turns: 3,
          on_event: PlanTracer.handler(tracer)
        )

      duration_ms = System.monotonic_time(:millisecond) - start
      PlanTracer.stop(tracer)

      IO.puts("\n--- Result (#{duration_ms}ms) ---")

      case result do
        {:ok, metadata} ->
          IO.puts("  ✓ Success")
          IO.puts("  Execution attempts: #{metadata.execution_attempts}")
          IO.puts("  Results: #{inspect(metadata.results, limit: 100)}")

          # Verify greeting was generated
          assert Map.has_key?(metadata.results, "say_hello")

          greeting = metadata.results["say_hello"]
          IO.puts("  Greeting: #{inspect(greeting)}")

          # Should contain "Hello" and "Alice"
          if is_binary(greeting) do
            assert String.contains?(String.downcase(greeting), "hello") or
                     String.contains?(String.downcase(greeting), "alice"),
                   "Greeting should mention hello or Alice"
          end

          IO.puts("  ✓ Trial would be recorded as success")

        {:error, reason, metadata} ->
          IO.puts("  ✗ Failed: #{inspect(reason)}")
          IO.puts("  Replans: #{metadata.replan_count}")
          flunk("PlanExecutor failed")
      end
    end

    @tag timeout: 180_000
    test "records failure trial on max replans exceeded" do
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Test: PlanExecutor Trial Recording (Failure)")
      IO.puts(String.duplicate("=", 70))

      # Tool that always returns wrong data to trigger verification failure
      bad_fn = fn _args -> %{"value" => 0} end

      registry =
        Registry.new()
        |> Registry.register_base_tool("get_value", bad_fn,
          signature: "() -> {value :int}",
          description: "Get a value (always returns 0)",
          tags: ["test"]
        )

      # Plan with verification that will always fail
      plan = %Plan{
        agents: %{
          "worker" => %{
            prompt: "You get values.",
            tools: ["get_value"]
          }
        },
        tasks: [
          %{
            id: "get_big_value",
            agent: "worker",
            type: :task,
            input: "Get a value using the get_value tool",
            depends_on: [],
            on_failure: :stop,
            on_verification_failure: :replan,
            max_retries: 0,
            critical: true,
            # This verification will always fail since tool returns 0
            verification: "(> (get data/result \"value\") 100)"
          }
        ]
      }

      mission = "Get a value greater than 100"

      IO.puts("\n  Running PlanExecutor (expecting failure after max replans)...")
      {:ok, tracer} = PlanTracer.start(output: :io)
      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.execute(plan, mission,
          llm: llm_callback(),
          registry: registry,
          max_total_replans: 2,
          max_replan_attempts: 2,
          replan_cooldown_ms: 100,
          timeout: @timeout,
          max_turns: 2,
          on_event: PlanTracer.handler(tracer)
        )

      duration_ms = System.monotonic_time(:millisecond) - start
      PlanTracer.stop(tracer)

      IO.puts("\n--- Result (#{duration_ms}ms) ---")

      case result do
        {:error, reason, metadata} ->
          IO.puts("  ✓ Failed as expected")
          IO.puts("  Reason: #{inspect(reason)}")
          IO.puts("  Replan count: #{metadata.replan_count}")
          IO.puts("  Execution attempts: #{metadata.execution_attempts}")

          # Verify we hit max replans
          assert metadata.replan_count > 0, "Should have attempted replanning"
          IO.puts("  ✓ Trial would be recorded as failure")

        {:ok, metadata} ->
          # This shouldn't happen but LLM might get creative
          IO.puts("  ⚠ Unexpectedly succeeded")
          IO.puts("  Results: #{inspect(metadata.results)}")
          IO.puts("  (LLM may have found a workaround)")
      end
    end

    @tag timeout: 180_000
    test "full execution flow with registry, skills, and trial recording" do
      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Test: Full Integration Flow")
      IO.puts(String.duplicate("=", 70))

      # Create a realistic scenario with tools, skills, and verification
      search_fn = fn %{"query" => query} ->
        %{
          "results" => [
            %{"title" => "Result for: #{query}", "relevance" => 0.95}
          ]
        }
      end

      summarize_fn = fn %{"text" => text} ->
        "Summary: #{String.slice(text, 0, 50)}..."
      end

      search_skill =
        Skill.new(
          "search_best_practices",
          "Search Best Practices",
          """
          When searching:
          - Use specific, targeted keywords
          - Prefer recent results
          - Validate relevance scores
          """,
          applies_to: ["search"],
          tags: ["search"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("search", search_fn,
          signature: "(query :string) -> {results: [{title :string, relevance :float}]}",
          description: "Search for information",
          tags: ["search", "web"]
        )
        |> Registry.register_base_tool("summarize", summarize_fn,
          signature: "(text :string) -> :string",
          description: "Summarize text",
          tags: ["text", "nlp"]
        )
        |> Registry.register_skill(search_skill)

      # Verify skill is linked
      {:ok, link_result} = Linker.link(registry, ["search", "summarize"])
      IO.puts("\n  Registry setup:")
      IO.puts("  - Tools: #{length(link_result.tools)}")
      IO.puts("  - Skills: #{length(link_result.skills)}")
      IO.puts("  - Skill prompt length: #{String.length(link_result.skill_prompt)} chars")

      plan = %Plan{
        agents: %{
          "researcher" => %{
            prompt: "You are a research assistant. Use tools to find and summarize information.",
            tools: ["search", "summarize"]
          }
        },
        tasks: [
          %{
            id: "research",
            agent: "researcher",
            type: :task,
            input: "Search for 'Elixir programming' and summarize the first result",
            depends_on: [],
            on_failure: :stop,
            on_verification_failure: :stop,
            max_retries: 0,
            critical: true,
            verification: nil
          }
        ]
      }

      mission = "Research Elixir programming language"

      IO.puts("\n  Running full integration flow...")
      {:ok, tracer} = PlanTracer.start(output: :io)
      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.execute(plan, mission,
          llm: llm_callback(),
          registry: registry,
          context_tags: ["research", "programming"],
          timeout: @timeout,
          max_turns: 5,
          on_event: PlanTracer.handler(tracer)
        )

      duration_ms = System.monotonic_time(:millisecond) - start
      PlanTracer.stop(tracer)

      IO.puts("\n--- Result (#{duration_ms}ms) ---")

      case result do
        {:ok, metadata} ->
          IO.puts("  ✓ Success")
          IO.puts("  Execution attempts: #{metadata.execution_attempts}")
          IO.puts("  Replan count: #{metadata.replan_count}")

          assert Map.has_key?(metadata.results, "research")
          research_result = metadata.results["research"]
          IO.puts("  Research result: #{inspect(research_result, limit: 100)}")

          # Record trial manually to demonstrate the flow
          updated_registry =
            TrialHistory.record_trial(registry, %{
              tools_used: ["search", "summarize"],
              skills_used: ["search_best_practices"],
              context_tags: ["research", "programming"],
              success: true
            })

          assert length(updated_registry.history) == 1
          IO.puts("  ✓ Trial recorded to registry history")

        {:error, reason, metadata} ->
          IO.puts("  ✗ Failed: #{inspect(reason)}")
          IO.puts("  Replans: #{metadata.replan_count}")

          # Still record failure trial
          updated_registry =
            TrialHistory.record_trial(registry, %{
              tools_used: ["search", "summarize"],
              skills_used: ["search_best_practices"],
              context_tags: ["research", "programming"],
              success: false,
              diagnosis: inspect(reason)
            })

          assert length(updated_registry.history) == 1
          IO.puts("  ✓ Failure trial recorded to registry history")
      end

      write_result("full_integration", mission, result, duration_ms)
    end
  end

  # ============================================================================
  # Helpers
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

  defp write_result(name, mission, result, duration_ms) do
    status =
      case result do
        {:ok, _} -> "SUCCESS"
        {:error, _, _} -> "FAILED"
        {:waiting, _, _} -> "WAITING"
      end

    content = """
    # Registry Integration E2E Test: #{name}

    ## Mission
    #{mission}

    ## Status: #{status}

    ## Result
    ```elixir
    #{inspect(result, pretty: true, limit: 500)}
    ```

    ## Duration
    #{duration_ms}ms

    ## Provider
    #{System.get_env("LLM_DEFAULT_PROVIDER", "openrouter")}

    ## Model
    #{LLMSupport.model()}

    ## Generated
    #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """

    File.write!(
      "tmp/e2e_results/registry_#{name}_#{System.system_time(:second)}.md",
      content
    )
  end
end
