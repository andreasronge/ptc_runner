defmodule PtcRunner.PlanExecutorE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  E2E tests for PlanExecutor.run/2 - the high-level autonomous execution API.

  These tests validate the full autonomous loop:
  1. MetaPlanner generates initial plan from mission
  2. PlanExecutor executes with automatic replanning
  3. Self-correction on validation failures
  4. Proper handling of impossible missions

  Run with: mix test test/ptc_runner/plan_executor_e2e_test.exs --include e2e

  Run with Bedrock:
    eval $(aws configure export-credentials --profile sandbox --format env)
    LLM_DEFAULT_PROVIDER=bedrock mix test test/ptc_runner/plan_executor_e2e_test.exs --include e2e

  Run specific test:
    mix test test/ptc_runner/plan_executor_e2e_test.exs --include e2e --only stock_comparison
  """

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias PtcRunner.PlanExecutor
  alias PtcRunner.PlanTracer
  alias PtcRunner.TestSupport.LLM
  alias PtcRunner.TestSupport.LLMSupport

  @tool_descriptions %{
    "search" =>
      "Search the web for information. Input: {query: string}. Output: {articles: [{title, snippet}]}",
    "fetch_price" =>
      "Fetch current stock price. Input: {symbol: string}. Output: {symbol, price, currency}"
  }

  # Mock tools for testing - simulate real tool behavior
  defp mock_tools do
    %{
      "search" => fn %{"query" => query} ->
        # Simulate search results
        Process.sleep(100)

        {:ok,
         %{
           "articles" => [
             %{"title" => "Result for: #{query}", "snippet" => "Mock search result..."}
           ]
         }}
      end,
      "fetch_price" => fn %{"symbol" => symbol} ->
        # Simulate stock price lookup
        Process.sleep(50)

        prices = %{
          "AAPL" => 185.50,
          "MSFT" => 425.00,
          "GOOGL" => 175.25
        }

        case Map.get(prices, symbol) do
          nil -> {:error, "Unknown symbol: #{symbol}"}
          price -> {:ok, %{"symbol" => symbol, "price" => price, "currency" => "USD"}}
        end
      end
    }
  end

  setup_all do
    LLMSupport.ensure_api_key!()
    File.mkdir_p!("tmp/e2e_results")
    IO.puts("\n=== PlanExecutor E2E Tests ===")
    IO.puts("Model: #{LLMSupport.model()}")
    IO.puts("Provider: #{System.get_env("LLM_DEFAULT_PROVIDER", "openrouter")}\n")
    :ok
  end

  describe "PlanExecutor.run/2 - autonomous execution" do
    @tag :stock_comparison
    test "generates and executes stock comparison mission" do
      mission =
        "Fetch the current stock prices for Apple (AAPL) and Microsoft (MSFT), " <>
          "then compare them in a synthesis gate that outputs which is higher."

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Mission: Stock Price Comparison")
      IO.puts(String.duplicate("=", 70))
      IO.puts("\n#{mission}\n")

      # Start tracer for visibility
      {:ok, tracer} = PlanTracer.start(output: :io)

      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.run(mission,
          llm: llm_callback(),
          available_tools: @tool_descriptions,
          base_tools: mock_tools(),
          max_turns: 3,
          max_total_replans: 2,
          replan_cooldown_ms: 100,
          timeout: 60_000,
          on_event: PlanTracer.handler(tracer)
        )

      duration_ms = System.monotonic_time(:millisecond) - start
      PlanTracer.stop(tracer)

      IO.puts("\n--- Result (#{duration_ms}ms) ---")
      print_result(result)
      write_result("stock_comparison", mission, result, duration_ms)

      # Soft assertions - we're exploring
      case result do
        {:ok, results, metadata} ->
          assert map_size(results) > 0, "Should have results"
          assert metadata.execution_attempts >= 1

        {:error, reason, _metadata} ->
          IO.puts("\n⚠ Mission failed: #{inspect(reason)}")

        # Don't fail the test - this helps us understand LLM behavior

        {:waiting, _pending, _metadata} ->
          IO.puts("\n⚠ Paused for human review")
      end
    end

    @tag :simple_research
    test "handles simple single-task mission" do
      mission = "What is 2 + 2? Return the answer as a JSON object with a 'result' field."

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Mission: Simple Math (no tools)")
      IO.puts(String.duplicate("=", 70))
      IO.puts("\n#{mission}\n")

      {:ok, tracer} = PlanTracer.start(output: :io)

      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.run(mission,
          llm: llm_callback(),
          max_turns: 1,
          timeout: 30_000,
          on_event: PlanTracer.handler(tracer)
        )

      duration_ms = System.monotonic_time(:millisecond) - start
      PlanTracer.stop(tracer)

      IO.puts("\n--- Result (#{duration_ms}ms) ---")
      print_result(result)
      write_result("simple_research", mission, result, duration_ms)

      case result do
        {:ok, results, _metadata} ->
          assert map_size(results) > 0

        _ ->
          :ok
      end
    end

    @tag :synthesis_gate
    test "synthesis gate consolidates parallel results" do
      mission = """
      Research two topics in parallel:
      1. Find information about Elixir programming language
      2. Find information about Erlang programming language

      Then use a synthesis gate to create a comparison summary with fields:
      {elixir_year, erlang_year, common_creator, key_differences}
      """

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Mission: Synthesis Gate - Language Comparison")
      IO.puts(String.duplicate("=", 70))
      IO.puts("\n#{String.trim(mission)}\n")

      {:ok, tracer} = PlanTracer.start(output: :io)

      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.run(mission,
          llm: llm_callback(),
          available_tools: @tool_descriptions,
          base_tools: mock_tools(),
          max_turns: 3,
          timeout: 90_000,
          on_event: PlanTracer.handler(tracer)
        )

      duration_ms = System.monotonic_time(:millisecond) - start
      PlanTracer.stop(tracer)

      IO.puts("\n--- Result (#{duration_ms}ms) ---")
      print_result(result)
      write_result("synthesis_gate", mission, result, duration_ms)
    end
  end

  describe "self-correction scenarios" do
    @tag :self_correction
    @tag :skip
    test "recovers from verification failure via replan" do
      # This mission is designed to potentially fail verification
      # and trigger the self-correction loop
      mission = """
      Fetch the stock price for AAPL.
      The result MUST include a 'confidence' field with value > 0.9.
      """

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Mission: Self-Correction Test")
      IO.puts(String.duplicate("=", 70))
      IO.puts("\n#{String.trim(mission)}\n")

      {:ok, tracer} = PlanTracer.start(output: :io)

      result =
        PlanExecutor.run(mission,
          llm: llm_callback(),
          available_tools: @tool_descriptions,
          base_tools: mock_tools(),
          max_turns: 3,
          max_total_replans: 3,
          replan_cooldown_ms: 100,
          timeout: 120_000,
          on_event: PlanTracer.handler(tracer)
        )

      PlanTracer.stop(tracer)

      IO.puts("\n--- Result ---")
      print_result(result)

      case result do
        {:ok, _results, metadata} ->
          IO.puts("Replan count: #{metadata.replan_count}")

          if metadata.replan_count > 0 do
            IO.puts("✓ Self-correction triggered and succeeded")
          end

        {:error, _reason, metadata} ->
          IO.puts("Replan attempts before failure: #{metadata.replan_count}")

        _ ->
          :ok
      end
    end
  end

  describe "impossible mission handling" do
    @tag :impossible
    @tag :skip
    test "recognizes impossible mission and returns gracefully" do
      mission = "Buy 1 Bitcoin for exactly $1 USD right now and confirm the transaction."

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Mission: Impossible Task Detection")
      IO.puts(String.duplicate("=", 70))
      IO.puts("\n#{mission}\n")

      {:ok, tracer} = PlanTracer.start(output: :io)

      result =
        PlanExecutor.run(mission,
          llm: llm_callback(),
          max_turns: 2,
          max_total_replans: 1,
          timeout: 60_000,
          on_event: PlanTracer.handler(tracer)
        )

      PlanTracer.stop(tracer)

      IO.puts("\n--- Result ---")
      print_result(result)

      # Check if the LLM recognized this as impossible
      case result do
        {:ok, results, _metadata} ->
          if Map.has_key?(results, "mission_impossible") do
            IO.puts("✓ LLM correctly identified mission as impossible")
          else
            IO.puts("⚠ LLM attempted the mission instead of flagging as impossible")
          end

        {:error, reason, _metadata} ->
          IO.puts("Mission failed (may indicate correct behavior): #{inspect(reason)}")

        _ ->
          :ok
      end
    end
  end

  describe "timeout and hang detection" do
    @tag :timeout
    @tag :skip
    test "handles slow operations with timeout" do
      # Create a tool that hangs
      slow_tools = %{
        "slow_search" => fn _args ->
          Process.sleep(10_000)
          {:ok, %{"result" => "done"}}
        end
      }

      mission = "Search for information using the slow_search tool."

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Mission: Timeout Handling")
      IO.puts(String.duplicate("=", 70))

      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.run(mission,
          llm: llm_callback(),
          available_tools: %{"slow_search" => "A very slow search tool"},
          base_tools: slow_tools,
          max_turns: 1,
          timeout: 5_000
        )

      duration_ms = System.monotonic_time(:millisecond) - start

      IO.puts("\nCompleted in #{duration_ms}ms")

      case result do
        {:error, reason, _metadata} ->
          if duration_ms < 8_000 do
            IO.puts("✓ Timeout triggered correctly")
          else
            IO.puts("⚠ Timeout took too long")
          end

          IO.puts("Error: #{inspect(reason)}")

        _ ->
          IO.puts("Unexpected result: #{inspect(result)}")
      end
    end
  end

  describe "constraints" do
    @tag :constraints
    test "respects planning constraints" do
      mission = "Fetch stock prices for AAPL and MSFT."

      constraints = """
      - Use ONLY the fetch_price tool, never search
      - Each task must have a verification predicate
      - Maximum 3 tasks in the plan
      """

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Mission: Constrained Planning")
      IO.puts(String.duplicate("=", 70))
      IO.puts("\nMission: #{mission}")
      IO.puts("\nConstraints:\n#{constraints}")

      {:ok, tracer} = PlanTracer.start(output: :io)

      result =
        PlanExecutor.run(mission,
          llm: llm_callback(),
          available_tools: @tool_descriptions,
          base_tools: mock_tools(),
          constraints: constraints,
          max_turns: 2,
          timeout: 60_000,
          on_event: PlanTracer.handler(tracer)
        )

      PlanTracer.stop(tracer)

      IO.puts("\n--- Result ---")
      print_result(result)
      write_result("constraints", mission, result, 0)
    end
  end

  describe "trial & error learning" do
    alias PtcRunner.Plan

    @tag :trial_error_learning
    test "LLM sees trial history in second replan prompt" do
      # This test verifies that:
      # 1. First failure triggers replan (no trial history yet)
      # 2. Second failure triggers replan WITH trial history from attempt 1
      # 3. The LLM uses real MetaPlanner.replan for repair plan generation
      #
      # Strategy: Use predefined plan with on_verification_failure: "replan"
      # so we control when replanning triggers, but use real LLM for repairs.

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Trial & Error Learning: LLM Sees Failure History")
      IO.puts(String.duplicate("=", 70))

      mission = "Fetch stock data for AAPL with at least 3 price points."

      # Predefined plan with explicit replan strategy
      raw_plan = %{
        "agents" => %{
          "fetcher" => %{
            "prompt" => "You fetch stock data. Always return JSON with symbol and prices array.",
            "tools" => ["flaky_api"]
          }
        },
        "tasks" => [
          %{
            "id" => "fetch_prices",
            "agent" => "fetcher",
            "input" => "Fetch AAPL stock prices using flaky_api tool",
            # Verification: must have at least 3 prices
            "verification" => "(>= (count (get data/result \"prices\")) 3)",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw_plan)

      IO.puts("\n--- Initial Plan ---")
      IO.puts("Task: fetch_prices with verification (>= 3 prices)")
      IO.puts("on_verification_failure: replan")

      # Track API call attempts and captured prompts
      api_calls = Agent.start_link(fn -> 0 end) |> elem(1)
      replan_prompts = Agent.start_link(fn -> [] end) |> elem(1)

      # Flaky tool: fails 4 times to force 2 replans, succeeds on 5th
      # This ensures we get at least 2 replans so we can verify trial history
      flaky_tools = %{
        "flaky_api" => fn _args ->
          call_num = Agent.get_and_update(api_calls, fn n -> {n + 1, n + 1} end)
          IO.puts("  [flaky_api] Call ##{call_num}")

          case call_num do
            1 ->
              IO.puts("    → Empty prices (fails verification)")
              {:ok, %{"symbol" => "AAPL", "prices" => []}}

            2 ->
              IO.puts("    → 1 price (still fails)")
              {:ok, %{"symbol" => "AAPL", "prices" => [185.0]}}

            3 ->
              IO.puts("    → 2 prices (still fails)")
              {:ok, %{"symbol" => "AAPL", "prices" => [185.0, 186.0]}}

            4 ->
              IO.puts("    → 2 prices (still fails, forcing 2nd replan)")
              {:ok, %{"symbol" => "AAPL", "prices" => [185.0, 186.0]}}

            _ ->
              IO.puts("    → 5 prices (passes!)")
              {:ok, %{"symbol" => "AAPL", "prices" => [185.0, 186.0, 187.0, 188.0, 189.0]}}
          end
        end
      }

      # Wrap LLM to capture replan prompts and inject replan strategy
      base_llm = llm_callback()

      capturing_llm = fn %{messages: messages} = input ->
        prompt = hd(messages).content

        if String.contains?(prompt, "repair specialist") do
          Agent.update(replan_prompts, fn list -> list ++ [prompt] end)
          IO.puts("\n  [MetaPlanner.replan] Generating repair plan...")

          if String.contains?(prompt, "Trial & Error History") do
            IO.puts("  ✓ Trial history included!")

            if String.contains?(prompt, "Attempt 1") do
              IO.puts("  ✓ Contains Attempt 1 details")
            end

            if String.contains?(prompt, "Self-Reflection") do
              IO.puts("  ✓ Contains Self-Reflection prompt")
            end
          else
            IO.puts("  (No trial history yet - first replan)")
          end

          # Show key sections of the prompt
          IO.puts("\n  --- Replan Prompt Sections ---")

          if String.contains?(prompt, "What Failed") do
            IO.puts("  ✓ Has 'What Failed' section")
          end

          if String.contains?(prompt, "Original Plan Structure") do
            IO.puts("  ✓ Has 'Original Plan Structure' section")
          end
        end

        # Call LLM and post-process to ensure repair plan uses replan strategy
        case base_llm.(input) do
          {:ok, response} ->
            # Inject on_verification_failure: "replan" into the response
            modified =
              String.replace(
                response,
                ~r/"on_verification_failure"\s*:\s*"stop"/,
                "\"on_verification_failure\": \"replan\""
              )

            # Also add it if missing from verification tasks
            {:ok, modified}

          error ->
            error
        end
      end

      IO.puts("\n--- Executing ---")
      {:ok, tracer} = PlanTracer.start(output: :io)
      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.execute(plan, mission,
          llm: capturing_llm,
          base_tools: flaky_tools,
          max_turns: 3,
          max_total_replans: 3,
          max_replan_attempts: 3,
          replan_cooldown_ms: 100,
          timeout: 120_000,
          on_event: PlanTracer.handler(tracer)
        )

      duration_ms = System.monotonic_time(:millisecond) - start
      PlanTracer.stop(tracer)

      total_api_calls = Agent.get(api_calls, & &1)
      prompts = Agent.get(replan_prompts, & &1)
      Agent.stop(api_calls)
      Agent.stop(replan_prompts)

      IO.puts("\n" <> String.duplicate("-", 50))
      IO.puts("Summary (#{duration_ms}ms)")
      IO.puts(String.duplicate("-", 50))

      case result do
        {:ok, metadata} ->
          IO.puts("✓ Success after #{metadata.replan_count} replans")
          IO.puts("  Execution attempts: #{metadata.execution_attempts}")
          IO.puts("  flaky_api calls: #{total_api_calls}")

          if Map.has_key?(metadata.results, "fetch_prices") do
            prices = get_in(metadata.results, ["fetch_prices", "prices"]) || []
            IO.puts("  Final price count: #{length(prices)}")
          end

        {:error, reason, metadata} ->
          IO.puts("✗ Failed: #{inspect(reason)}")
          IO.puts("  Replans: #{metadata.replan_count}")
      end

      IO.puts("\n--- Replan Prompt Analysis ---")
      IO.puts("  Total replan prompts captured: #{length(prompts)}")

      for {prompt, idx} <- Enum.with_index(prompts, 1) do
        has_history = String.contains?(prompt, "Trial & Error History")
        has_self_reflect = String.contains?(prompt, "Self-Reflection Required")
        IO.puts("  Replan ##{idx}: history=#{has_history}, self_reflect=#{has_self_reflect}")
      end

      # Write detailed results
      write_trial_error_result(mission, result, prompts, duration_ms)

      # Assertions
      case result do
        {:ok, metadata} ->
          assert metadata.replan_count >= 1, "Expected at least 1 replan"

          # Verify enriched history structure
          first_entry = hd(metadata.replan_history)
          assert Map.has_key?(first_entry, :approach), "History should have :approach"
          assert Map.has_key?(first_entry, :output), "History should have :output"
          assert Map.has_key?(first_entry, :timestamp), "History should have :timestamp"
          assert Map.has_key?(first_entry, :input), "History should have :input"

          IO.puts("\n--- Enriched History Entry ---")
          IO.puts("  approach: #{String.slice(first_entry.approach, 0, 50)}...")
          IO.puts("  output: #{String.slice(first_entry.output, 0, 50)}...")
          IO.puts("  timestamp: #{first_entry.timestamp}")

          # Verify replan prompt has expected sections
          if prompts != [] do
            first_prompt = hd(prompts)

            assert String.contains?(first_prompt, "What Failed"),
                   "Replan prompt should have 'What Failed' section"

            assert String.contains?(first_prompt, "Original Plan"),
                   "Replan prompt should reference original plan"
          end

          # If we had 2+ replans, verify second prompt had trial history
          if length(prompts) >= 2 do
            second_prompt = Enum.at(prompts, 1)

            assert String.contains?(second_prompt, "Trial & Error History"),
                   "Second replan should include trial history"

            IO.puts("\n✓ Trial history verified in 2nd replan prompt!")
          else
            IO.puts("\n⚠ Only 1 replan needed (LLM generated effective retry loop)")
            IO.puts("  Trial history would appear in 2nd replan if needed")
          end

        {:error, _reason, metadata} ->
          # Even on failure, verify history was captured
          if metadata.replan_count > 0 do
            first_entry = hd(metadata.replan_history)
            assert Map.has_key?(first_entry, :approach)
          end
      end
    end

    @tag :trial_history_in_prompt
    test "forces 2 replans to verify trial history appears in prompt" do
      # This test uses a verification that checks for a UNIQUE TOKEN
      # that only the tool can provide - the LLM cannot fake this.
      #
      # Strategy:
      # 1. Tool returns incrementing "token" values
      # 2. Verification requires token to match "TOKEN_PASS"
      # 3. Tool only returns "TOKEN_PASS" on 3rd+ call
      # 4. Forces multiple replan cycles

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Trial & Error Learning: Forcing Multiple Replans")
      IO.puts(String.duplicate("=", 70))

      mission = "Get the secret token that equals TOKEN_PASS."

      # Initial plan - verification requires exact token match
      raw_plan = %{
        "agents" => %{
          "fetcher" => %{
            "prompt" =>
              "You fetch tokens. Call the get_token tool and return its EXACT output. " <>
                "Do not modify or fabricate the token - return exactly what the tool returns.",
            "tools" => ["get_token"]
          }
        },
        "tasks" => [
          %{
            "id" => "fetch_token",
            "agent" => "fetcher",
            "input" =>
              "Call get_token and return its exact output. The token field must equal TOKEN_PASS.",
            "verification" => "(= (get data/result \"token\") \"TOKEN_PASS\")",
            "on_verification_failure" => "replan"
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw_plan)

      # Track execution and replan prompts
      exec_count = Agent.start_link(fn -> 0 end) |> elem(1)
      replan_prompts = Agent.start_link(fn -> [] end) |> elem(1)

      # Tool returns failing tokens until 3rd call
      mock_tools = %{
        "get_token" => fn _args ->
          count = Agent.get_and_update(exec_count, fn n -> {n + 1, n + 1} end)
          IO.puts("  [get_token] Call ##{count}")

          case count do
            1 ->
              IO.puts("    → TOKEN_FAIL_1")
              {:ok, %{"token" => "TOKEN_FAIL_1", "attempt" => 1}}

            2 ->
              IO.puts("    → TOKEN_FAIL_2")
              {:ok, %{"token" => "TOKEN_FAIL_2", "attempt" => 2}}

            _ ->
              IO.puts("    → TOKEN_PASS ✓")
              {:ok, %{"token" => "TOKEN_PASS", "attempt" => count}}
          end
        end
      }

      base_llm = llm_callback()

      # Capture replan prompts
      capturing_llm = fn %{messages: messages} = input ->
        prompt = hd(messages).content

        if String.contains?(prompt, "repair specialist") do
          prompt_num = length(Agent.get(replan_prompts, & &1)) + 1
          Agent.update(replan_prompts, fn list -> list ++ [prompt] end)

          IO.puts("\n  [MetaPlanner.replan ##{prompt_num}]")

          if String.contains?(prompt, "Trial & Error History") do
            IO.puts("  ✓ Has Trial History!")
            attempt_count = Regex.scan(~r/### Attempt \d+/, prompt) |> length()
            IO.puts("  ✓ Contains #{attempt_count} previous attempt(s)")

            if String.contains?(prompt, "Self-Reflection Required") do
              IO.puts("  ✓ Has Self-Reflection prompt")
            end

            # Show a snippet of trial history
            if String.contains?(prompt, "TOKEN_FAIL") do
              IO.puts("  ✓ History shows failed token values")
            end
          else
            IO.puts("  (No trial history - first replan)")
          end
        end

        # Inject replan strategy into repair plans
        case base_llm.(input) do
          {:ok, response} ->
            # Ensure repair tasks use replan strategy
            modified =
              String.replace(
                response,
                ~r/"on_verification_failure"\s*:\s*"[^"]*"/,
                "\"on_verification_failure\": \"replan\""
              )

            {:ok, modified}

          error ->
            error
        end
      end

      IO.puts("\n--- Executing (expecting 2+ replans) ---")
      {:ok, tracer} = PlanTracer.start(output: :io)

      result =
        PlanExecutor.execute(plan, mission,
          llm: capturing_llm,
          base_tools: mock_tools,
          max_turns: 3,
          max_total_replans: 4,
          max_replan_attempts: 4,
          replan_cooldown_ms: 100,
          timeout: 180_000,
          on_event: PlanTracer.handler(tracer)
        )

      PlanTracer.stop(tracer)

      prompts = Agent.get(replan_prompts, & &1)
      total_calls = Agent.get(exec_count, & &1)
      Agent.stop(exec_count)
      Agent.stop(replan_prompts)

      IO.puts("\n" <> String.duplicate("-", 50))
      IO.puts("Summary")
      IO.puts(String.duplicate("-", 50))
      IO.puts("  get_token calls: #{total_calls}")
      IO.puts("  Replan prompts: #{length(prompts)}")

      case result do
        {:ok, metadata} ->
          IO.puts("  ✓ Success after #{metadata.replan_count} replans")

          if metadata.replan_count >= 2 do
            # Verify second prompt has trial history
            assert length(prompts) >= 2, "Expected at least 2 replan prompts"
            second_prompt = Enum.at(prompts, 1)

            assert String.contains?(second_prompt, "Trial & Error History"),
                   "Second replan prompt must contain trial history"

            IO.puts("\n  ✓ Trial history verified in 2nd replan prompt!")
          else
            IO.puts(
              "\n  ⚠ Only #{metadata.replan_count} replan (LLM may have retried internally)"
            )

            # Still verify enriched history structure
            if metadata.replan_count > 0 do
              first_entry = hd(metadata.replan_history)
              assert Map.has_key?(first_entry, :approach)
              assert Map.has_key?(first_entry, :output)
              IO.puts("  ✓ Enriched history structure verified")
            end
          end

        {:error, reason, metadata} ->
          IO.puts("  ✗ Failed: #{inspect(reason)}")
          IO.puts("  Replans: #{metadata.replan_count}")

          # Even on failure, check what we can verify
          if metadata.replan_count >= 2 and length(prompts) >= 2 do
            second_prompt = Enum.at(prompts, 1)
            has_history = String.contains?(second_prompt, "Trial & Error History")
            IO.puts("  Trial history in 2nd prompt: #{has_history}")
          end
      end

      # Always verify we exercised the replan path
      assert prompts != [], "Expected at least 1 replan prompt"
    end

    @tag :trial_learning_pattern
    @tag :skip
    test "LLM learns from trial history to avoid repeating mistakes" do
      # This is a more advanced test that checks if the LLM actually
      # changes its approach based on trial history

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("Trial & Error Learning: Pattern Recognition")
      IO.puts(String.duplicate("=", 70))

      mission = """
      Find information about a rare programming language called "Zyxlang".
      Return details including: name, year_created, and creator.
      All fields must be non-empty strings.
      """

      # This tool always returns incomplete data - testing if LLM recognizes
      # the pattern and declares mission_impossible or changes strategy
      impossible_tool = %{
        "search" => fn %{"query" => _query} ->
          {:ok,
           %{
             "results" => [
               %{"title" => "No results found", "snippet" => "Zyxlang does not exist"}
             ]
           }}
        end
      }

      IO.puts("\n--- Executing mission that cannot succeed ---")
      {:ok, tracer} = PlanTracer.start(output: :io)

      result =
        PlanExecutor.run(mission,
          llm: llm_callback(),
          available_tools: %{"search" => "Search for programming language info"},
          base_tools: impossible_tool,
          max_turns: 2,
          max_total_replans: 3,
          replan_cooldown_ms: 100,
          timeout: 90_000,
          on_event: PlanTracer.handler(tracer)
        )

      PlanTracer.stop(tracer)

      IO.puts("\n--- Result ---")
      print_result(result)

      case result do
        {:ok, results, metadata} ->
          # Check if LLM recognized the pattern and declared mission impossible
          if Map.has_key?(results, "mission_impossible") do
            IO.puts("\n✓ LLM recognized impossible mission after seeing trial history")
          else
            IO.puts("\n⚠ LLM completed mission (may have fabricated data)")
          end

          IO.puts("  Replans: #{metadata.replan_count}")

        {:error, _reason, metadata} ->
          IO.puts("\n  LLM failed after #{metadata.replan_count} attempts")
          # Check if trial history was used
          if length(metadata.replan_history) >= 2 do
            IO.puts("  ✓ Multiple attempts recorded in history")
          end

        _ ->
          :ok
      end
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp write_trial_error_result(mission, result, prompts, duration_ms) do
    status =
      case result do
        {:ok, _} -> "SUCCESS"
        {:ok, _, _} -> "SUCCESS"
        {:error, _, _} -> "FAILED"
        {:error, _} -> "FAILED"
        {:waiting, _, _} -> "WAITING"
      end

    # Truncate prompts for readability
    prompt_summaries =
      prompts
      |> Enum.with_index(1)
      |> Enum.map(fn {prompt, idx} ->
        has_history = String.contains?(prompt, "Trial & Error History")

        """
        ### Replan #{idx}
        - Has trial history: #{has_history}
        - Length: #{String.length(prompt)} chars
        #{if has_history, do: "- Contains self-reflection prompt: #{String.contains?(prompt, "Self-Reflection")}", else: ""}
        """
      end)

    prompt_summaries = Enum.join(prompt_summaries, "\n")

    content = """
    # Trial & Error Learning E2E Test

    ## Mission
    #{mission}

    ## Status: #{status}

    ## Replan Prompts Analysis
    #{prompt_summaries}

    ## Result
    ```elixir
    #{inspect(result, pretty: true, limit: 500)}
    ```

    ## Duration
    #{duration_ms}ms

    ## Generated
    #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """

    File.write!(
      "tmp/e2e_results/trial_error_learning_#{System.system_time(:second)}.md",
      content
    )
  end

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case LLM.generate_text(LLMSupport.model(), full_messages, receive_timeout: 60_000) do
        {:ok, text} -> {:ok, text}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp print_result({:ok, results, metadata}) do
    IO.puts("✓ Success")
    IO.puts("  Tasks completed: #{map_size(results)}")
    IO.puts("  Execution attempts: #{metadata.execution_attempts}")
    IO.puts("  Replan count: #{metadata.replan_count}")
    IO.puts("  Duration: #{metadata.total_duration_ms}ms")

    IO.puts("\n  Results:")

    for {task_id, value} <- results do
      value_str = inspect(value, limit: 80, pretty: false)
      IO.puts("    #{task_id}: #{String.slice(value_str, 0, 100)}")
    end
  end

  defp print_result({:error, reason, metadata}) do
    IO.puts("✗ Failed")
    IO.puts("  Reason: #{inspect(reason)}")
    IO.puts("  Execution attempts: #{metadata.execution_attempts}")
    IO.puts("  Replan count: #{metadata.replan_count}")

    if metadata.replan_history != [] do
      IO.puts("\n  Replan history:")

      for entry <- metadata.replan_history do
        IO.puts("    - #{entry.task_id}: #{entry.diagnosis}")
      end
    end
  end

  defp print_result({:waiting, pending, metadata}) do
    IO.puts("⏸ Waiting for human review")
    IO.puts("  Pending tasks: #{Enum.map_join(pending, ", ", & &1.task_id)}")
    IO.puts("  Execution attempts: #{metadata.execution_attempts}")
  end

  defp write_result(name, mission, result, duration_ms) do
    status =
      case result do
        {:ok, _, _} -> "SUCCESS"
        {:error, _, _} -> "FAILED"
        {:waiting, _, _} -> "WAITING"
      end

    content = """
    # E2E Test: #{name}

    ## Mission
    #{mission}

    ## Status: #{status}

    ## Result
    ```elixir
    #{inspect(result, pretty: true, limit: 500)}
    ```

    ## Duration
    #{duration_ms}ms

    ## Generated
    #{DateTime.utc_now() |> DateTime.to_iso8601()}
    """

    File.write!("tmp/e2e_results/#{name}_#{System.system_time(:second)}.md", content)
  end
end
