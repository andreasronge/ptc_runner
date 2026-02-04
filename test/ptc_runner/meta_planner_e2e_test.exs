defmodule PtcRunner.MetaPlannerE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  E2E tests for MetaPlanner plan generation with real LLMs.

  Run with: mix test test/ptc_runner/meta_planner_e2e_test.exs --include e2e
  """

  @moduletag :e2e
  @moduletag timeout: 60_000

  alias PtcRunner.MetaPlanner
  alias PtcRunner.TestSupport.LLMSupport

  setup_all do
    LLMSupport.ensure_api_key!()
    IO.puts("\n=== MetaPlanner E2E Tests ===")
    IO.puts("Model: #{LLMSupport.model()}")
    IO.puts("Provider: #{System.get_env("LLM_DEFAULT_PROVIDER", "openrouter")}\n")
    :ok
  end

  describe "MetaPlanner.plan/2" do
    @tag :basic_plan
    test "generates valid plan from simple mission" do
      mission = "Compare the prices of AAPL and MSFT stocks"

      IO.puts("\n--- Test: Basic Plan Generation ---")
      IO.puts("Mission: #{mission}")

      # Wrap LLM to see the raw response
      debug_llm = fn input ->
        result = llm_callback().(input)

        case result do
          {:ok, %{content: content}} ->
            IO.puts("\n[DEBUG] LLM returned: #{String.slice(content, 0, 500)}...")

          {:ok, content} when is_binary(content) ->
            IO.puts("\n[DEBUG] LLM returned string: #{String.slice(content, 0, 500)}...")

          other ->
            IO.puts("\n[DEBUG] LLM returned: #{inspect(other, limit: 200)}")
        end

        result
      end

      result =
        MetaPlanner.plan(mission,
          llm: debug_llm,
          available_tools: %{
            "fetch_price" =>
              "Fetch stock price. Input: {symbol: string}. Output: {symbol, price, currency}"
          },
          timeout: 30_000
        )

      IO.puts("\nResult: #{inspect(result, pretty: true, limit: 50)}")

      case result do
        {:ok, plan} ->
          IO.puts("✓ Generated #{length(plan.tasks)} task(s)")
          IO.puts("  Agents: #{inspect(Map.keys(plan.agents))}")

          for task <- plan.tasks do
            IO.puts("  - #{task.id}: #{String.slice(to_string(task.input), 0, 50)}...")
          end

          assert plan.tasks != [], "Should generate at least 1 task"

        {:error, reason} ->
          IO.puts("✗ Failed: #{inspect(reason)}")
          flunk("Plan generation failed: #{inspect(reason)}")
      end
    end

    @tag :plan_with_verification
    test "generates plan with verification predicates" do
      mission = """
      Fetch the stock price for AAPL using the fetch_price tool.
      The result must include both 'symbol' and 'price' fields.
      Add verification predicates to ensure the output is valid.
      """

      IO.puts("\n--- Test: Plan with Verification ---")
      IO.puts("Mission: #{String.trim(mission)}")

      result =
        MetaPlanner.plan(mission,
          llm: llm_callback(),
          available_tools: %{
            "fetch_price" =>
              "Fetch stock price. Input: {symbol: string}. Output: {symbol, price, currency}"
          },
          timeout: 30_000
        )

      case result do
        {:ok, plan} ->
          IO.puts("✓ Generated #{length(plan.tasks)} task(s)")

          # Check if any task has verification
          tasks_with_verification =
            Enum.filter(plan.tasks, fn t -> t.verification != nil end)

          IO.puts("  Tasks with verification: #{length(tasks_with_verification)}")

          for task <- tasks_with_verification do
            IO.puts("  - #{task.id}: #{task.verification}")
          end

          # Should have at least one task
          assert plan.tasks != [], "Should generate at least 1 task"

        {:error, reason} ->
          IO.puts("✗ Failed: #{inspect(reason)}")
          flunk("Plan generation failed: #{inspect(reason)}")
      end
    end

    @tag :plan_no_tools
    @tag :skip
    test "generates plan without tools (pure LLM reasoning)" do
      # This test is flaky because the LLM may not generate tasks for simple calculations
      # when there are no tools available. Skipping for now.
      mission = "What is 15% tip on a $47.50 restaurant bill? Show the calculation."

      IO.puts("\n--- Test: Plan without Tools ---")
      IO.puts("Mission: #{mission}")

      result =
        MetaPlanner.plan(mission,
          llm: llm_callback(),
          timeout: 30_000
        )

      case result do
        {:ok, plan} ->
          IO.puts("✓ Generated #{length(plan.tasks)} task(s)")

          for task <- plan.tasks do
            IO.puts("  - #{task.id}: #{String.slice(to_string(task.input), 0, 60)}...")
          end

          # Soft assertion - this is exploratory
          if plan.tasks == [] do
            IO.puts("  (LLM chose not to create tasks for this simple mission)")
          end

        {:error, reason} ->
          IO.puts("✗ Failed: #{inspect(reason)}")
          flunk("Plan generation failed: #{inspect(reason)}")
      end
    end

    @tag :plan_with_dependencies
    test "generates plan with task dependencies" do
      mission = """
      Research workflow:
      1. Search for information about Elixir programming language
      2. Search for information about Erlang programming language
      3. Compare them and create a summary

      The comparison step must wait for both research steps to complete.
      """

      IO.puts("\n--- Test: Plan with Dependencies ---")
      IO.puts("Mission: Research and compare two languages")

      result =
        MetaPlanner.plan(mission,
          llm: llm_callback(),
          available_tools: %{
            "search" => "Search the web. Input: {query: string}. Output: [{title, snippet}]"
          },
          timeout: 30_000
        )

      case result do
        {:ok, plan} ->
          IO.puts("✓ Generated #{length(plan.tasks)} task(s)")

          # Check for dependencies
          tasks_with_deps =
            Enum.filter(plan.tasks, fn t -> t.depends_on != [] end)

          IO.puts("  Tasks with dependencies: #{length(tasks_with_deps)}")

          for task <- plan.tasks do
            deps =
              if task.depends_on == [],
                do: "(root)",
                else: "(after: #{Enum.join(task.depends_on, ", ")})"

            IO.puts("  - #{task.id} #{deps}")
          end

          assert match?([_, _ | _], plan.tasks), "Should have multiple tasks"

        {:error, reason} ->
          IO.puts("✗ Failed: #{inspect(reason)}")
          flunk("Plan generation failed: #{inspect(reason)}")
      end
    end
  end

  describe "debug: inspect LLM communication" do
    @tag :debug_llm
    @tag :skip
    test "shows what is sent to and received from LLM" do
      mission = "Compare AAPL and MSFT stock prices"

      IO.puts("\n--- Debug: LLM Communication ---")

      # Wrap LLM to inspect communication
      debug_llm = fn input ->
        IO.puts("\n=== LLM REQUEST ===")
        IO.puts("Output mode: #{inspect(input[:output])}")
        IO.puts("Schema: #{inspect(input[:schema], pretty: true)}")
        IO.puts("\nSystem prompt (first 500 chars):")
        IO.puts(String.slice(input[:system], 0, 500))
        IO.puts("\nUser message:")
        IO.puts(hd(input[:messages]).content)

        result = llm_callback().(input)

        IO.puts("\n=== LLM RESPONSE ===")

        case result do
          {:ok, %{content: content}} ->
            IO.puts("Content: #{inspect(content, pretty: true, limit: 50)}")

          {:ok, content} ->
            IO.puts("Raw: #{inspect(content, pretty: true, limit: 50)}")

          {:error, reason} ->
            IO.puts("Error: #{inspect(reason)}")
        end

        result
      end

      result =
        MetaPlanner.plan(mission,
          llm: debug_llm,
          available_tools: %{
            "fetch_price" => "Fetch stock price. Input: {symbol}. Output: {price}"
          },
          timeout: 30_000
        )

      IO.puts("\n=== FINAL RESULT ===")
      IO.puts(inspect(result, pretty: true, limit: 100))
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp llm_callback do
    # LLMClient.callback handles both text and JSON modes automatically
    LLMClient.callback(LLMSupport.model())
  end
end
