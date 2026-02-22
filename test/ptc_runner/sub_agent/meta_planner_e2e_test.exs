defmodule PtcRunner.SubAgent.MetaPlannerE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  E2E tests for meta-planning: LLM designs its own execution strategy.

  This test explores what plans LLMs generate for different mission types.
  The goal is to understand:
  - What structures emerge naturally?
  - When do LLMs add verification/review steps?
  - How do they handle complexity and errors?
  - Do simple missions get simple plans?

  Run with: mix test test/ptc_runner/sub_agent/meta_planner_e2e_test.exs --include e2e

  Run specific mission:
    mix test test/ptc_runner/sub_agent/meta_planner_e2e_test.exs --include e2e --only simple_math

  Requires OPENROUTER_API_KEY or AWS credentials for Bedrock.
  """

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias PtcRunner.Plan
  alias PtcRunner.PlanCritic
  alias PtcRunner.PlanRunner
  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LLM
  alias PtcRunner.TestSupport.LLMSupport

  @missions [
    # Simple - should be minimal/no plan
    {:simple_math, "What is 2+2?"},

    # Single research task
    {:single_research, "What is the latest stable version of Elixir?"},

    # Parallel independent research
    {:parallel_research, "Compare the latest versions of Elixir and Erlang"},

    # Sequential dependency (B needs A's result)
    {:sequential, "Find who created Elixir, then list 3 other projects they've built"},

    # Multi-criteria analysis requiring synthesis
    {:analysis,
     "Recommend a web framework (Phoenix, Rails, or Django) based on performance, learning curve, and job market"},

    # Error handling - some sources may fail
    {:unreliable,
     "Gather information from these sources (some may be unavailable): elixir-lang.org, erlang.org, gleam.run"},

    # Deep chain - multiple dependent steps
    {:deep_chain,
     "Find the most popular Elixir library, then find its main contributor, then find what company they work for"},

    # Conditional branching
    {:conditional,
     "Check if Elixir 2.0 has been released. If yes, list its features. If no, list what features are planned."}
  ]

  setup_all do
    LLMSupport.ensure_api_key!()
    File.mkdir_p!("tmp")
    IO.puts("\n=== Meta-Planner E2E Tests ===")
    IO.puts("Model: #{LLMSupport.model()}\n")
    :ok
  end

  # Generate a test for each mission
  for {name, mission} <- @missions do
    @tag name
    test "plan for: #{name}" do
      mission = unquote(mission)
      name = unquote(name)

      {plan, duration_ms} = timed_generate_plan(mission)

      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Mission: #{name}")
      IO.puts(String.duplicate("=", 60))
      IO.puts("\n#{mission}\n")
      IO.puts("--- Generated Plan (#{duration_ms}ms) ---")
      IO.puts(format_plan(plan))

      evaluation = evaluate_plan(plan, mission)
      IO.puts("\n--- Evaluation ---")
      print_evaluation(evaluation)

      # Write to file for later analysis
      write_result(name, mission, plan, evaluation, duration_ms)

      # Soft assertion - we're exploring, not enforcing
      assert is_map(plan), "Should return a map"
    end
  end

  describe "plan comparison" do
    @tag :comparison
    test "run all missions and summarize" do
      results =
        for {name, mission} <- @missions do
          {plan, duration_ms} = timed_generate_plan(mission)
          evaluation = evaluate_plan(plan, mission)
          {name, %{plan: plan, evaluation: evaluation, duration_ms: duration_ms}}
        end

      IO.puts("\n" <> String.duplicate("=", 70))
      IO.puts("SUMMARY: All Missions")
      IO.puts(String.duplicate("=", 70))

      # Print comparison table
      IO.puts("\n| Mission | Tasks | Agents | Verification | Error Handling | Time |")
      IO.puts("|---------|-------|--------|--------------|----------------|------|")

      for {name, %{evaluation: eval, duration_ms: ms}} <- results do
        agents = Enum.join(eval.agent_types, ", ")
        agents = if agents == "", do: "-", else: agents

        IO.puts(
          "| #{pad(name, 15)} | #{pad(eval.task_count, 5)} | #{pad(agents, 20)} | #{pad(eval.has_verification, 12)} | #{pad(eval.has_error_handling, 14)} | #{pad(ms, 5)}ms |"
        )
      end

      # Write full results to file
      write_summary(results)

      assert length(results) == length(@missions)
    end
  end

  describe "plan execution" do
    @tag :execute
    test "generate and execute single_research plan" do
      mission = "What is the latest stable version of Elixir?"

      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Plan Execution: single_research")
      IO.puts(String.duplicate("=", 60))

      # Step 1: Generate plan
      IO.puts("\n--- Generating Plan ---")
      {raw_plan, gen_ms} = timed_generate_plan(mission)
      IO.puts("Plan generated in #{gen_ms}ms:")
      IO.puts(format_plan(raw_plan))

      # Step 2: Parse plan
      IO.puts("\n--- Parsing Plan ---")
      {:ok, plan} = Plan.parse(raw_plan)
      IO.puts("Parsed #{length(plan.tasks)} task(s)")
      IO.puts("Agents: #{inspect(Map.keys(plan.agents))}")

      for task <- plan.tasks do
        IO.puts("  Task #{task.id}: agent=#{task.agent}, depends_on=#{inspect(task.depends_on)}")
      end

      # Step 3: Execute plan
      IO.puts("\n--- Executing Plan ---")
      start = System.monotonic_time(:millisecond)

      result =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          timeout: 30_000,
          max_turns: 3
        )

      exec_ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, results} ->
          IO.puts("Execution succeeded in #{exec_ms}ms")
          IO.puts("Results:")

          for {task_id, value} <- results do
            IO.puts("  #{task_id}: #{inspect(value, limit: 100)}")
          end

          # Verify we got actual results
          assert map_size(results) > 0, "Should have at least one result"

          # Check that results contain something meaningful (not just empty)
          has_content =
            Enum.any?(results, fn {_id, value} ->
              case value do
                v when is_binary(v) -> String.length(v) > 0
                v when is_map(v) -> map_size(v) > 0
                _ -> true
              end
            end)

          assert has_content, "Results should contain actual data"

        {:error, failed_task, partial_results, reason} ->
          IO.puts("Execution failed at task #{failed_task} in #{exec_ms}ms")
          IO.puts("Reason: #{inspect(reason)}")
          IO.puts("Partial results: #{inspect(partial_results)}")

          # For exploration, we don't hard-fail on execution errors
          # but we note them for analysis
          IO.puts("\n[NOTE: Execution failed - this is expected during exploration]")
      end

      # Write execution results
      write_execution_result(mission, raw_plan, plan, result, gen_ms, exec_ms)
    end

    @tag :execute_simple
    test "execute a hand-crafted simple plan" do
      # Test with a known-good plan structure to validate PlanRunner
      # Note: JSON mode requires object responses, so we ask for structured output
      raw_plan = %{
        "tasks" => [
          %{
            "id" => "answer",
            "agent" => "default",
            "input" => "What is 2 + 2? Return as JSON with a 'result' field."
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw_plan)
      assert length(plan.tasks) == 1

      result =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          timeout: 30_000,
          max_turns: 1
        )

      case result do
        {:ok, results} ->
          assert Map.has_key?(results, "answer")
          IO.puts("Simple plan result: #{inspect(results["answer"])}")

        {:error, task_id, _partial, reason} ->
          flunk("Simple plan failed at #{task_id}: #{inspect(reason)}")
      end
    end
  end

  describe "plan critique" do
    @tag :critique
    test "static critique catches missing synthesis gate" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Plan Critique: Missing Gate Detection")
      IO.puts(String.duplicate("=", 60))

      # Generate a plan for parallel research (likely to have parallel tasks)
      mission = missions()[:parallel_research]

      IO.puts("\n--- Generating Plan ---")
      {raw_plan, gen_ms} = timed_generate_plan(mission)
      IO.puts("Plan generated in #{gen_ms}ms")

      {:ok, plan} = Plan.parse(raw_plan)
      IO.puts("Parsed #{length(plan.tasks)} task(s)")

      # Run static critique
      IO.puts("\n--- Static Critique ---")
      {:ok, critique} = PlanCritic.static_review(plan)

      IO.puts("Score: #{critique.score}/10")
      IO.puts("Summary: #{critique.summary}")

      if critique.issues != [] do
        IO.puts("\nIssues found:")

        for issue <- critique.issues do
          IO.puts("  [#{issue.severity}] #{issue.category}: #{issue.message}")
        end

        IO.puts("\nRecommendations:")

        for rec <- critique.recommendations do
          IO.puts("  - #{rec}")
        end
      else
        IO.puts("No issues found")
      end

      # The test passes regardless of issues - we're exploring
      assert is_integer(critique.score)
      assert is_list(critique.issues)
    end

    @tag :critique_llm
    test "LLM critique finds semantic issues" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Plan Critique: LLM Analysis")
      IO.puts(String.duplicate("=", 60))

      # Generate a complex plan
      mission = missions()[:analysis]

      IO.puts("\n--- Generating Plan ---")
      {raw_plan, gen_ms} = timed_generate_plan(mission)
      IO.puts("Plan generated in #{gen_ms}ms")

      {:ok, plan} = Plan.parse(raw_plan)
      IO.puts("Parsed #{length(plan.tasks)} task(s)")

      # Run full critique with LLM
      IO.puts("\n--- Full Critique (Static + LLM) ---")
      start = System.monotonic_time(:millisecond)

      {:ok, critique} =
        PlanCritic.review(plan,
          llm: llm_callback(),
          timeout: 30_000
        )

      critique_ms = System.monotonic_time(:millisecond) - start

      IO.puts("Critique completed in #{critique_ms}ms")
      IO.puts("Score: #{critique.score}/10")
      IO.puts("Summary: #{critique.summary}")

      if critique.issues != [] do
        IO.puts("\nIssues found (#{length(critique.issues)}):")

        for issue <- Enum.take(critique.issues, 5) do
          task_info = if issue.task_id, do: " [#{issue.task_id}]", else: ""
          IO.puts("  [#{issue.severity}] #{issue.category}#{task_info}")
          IO.puts("    #{issue.message}")
        end

        if length(critique.issues) > 5 do
          IO.puts("  ... and #{length(critique.issues) - 5} more")
        end
      end

      assert is_integer(critique.score)
    end

    @tag :critique_refine
    test "critique and refine loop improves plan" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Plan Critique: Critique & Refine Loop")
      IO.puts(String.duplicate("=", 60))

      # Create a deliberately flawed plan
      flawed_plan = %{
        "tasks" => [
          %{"id" => "search1", "input" => "Search web for topic A", "critical" => true},
          %{"id" => "search2", "input" => "Search web for topic B", "critical" => true},
          %{"id" => "search3", "input" => "Search web for topic C", "critical" => true},
          %{"id" => "search4", "input" => "Fetch API data", "critical" => true},
          # No synthesis gate before analysis
          %{
            "id" => "analyze",
            "input" => "Analyze all findings",
            "depends_on" => ["search1", "search2", "search3", "search4"]
          }
        ]
      }

      {:ok, plan_v1} = Plan.parse(flawed_plan)

      # Critique v1
      IO.puts("\n--- Critique V1 ---")
      {:ok, critique_v1} = PlanCritic.static_review(plan_v1)
      IO.puts("Score: #{critique_v1.score}/10")
      IO.puts("Issues: #{length(critique_v1.issues)}")

      for issue <- critique_v1.issues do
        IO.puts(
          "  [#{issue.severity}] #{issue.category}: #{String.slice(issue.message, 0, 60)}..."
        )
      end

      # The flawed plan should have issues
      assert critique_v1.score < 9, "Flawed plan should have low score"
      assert critique_v1.issues != [], "Flawed plan should have issues"

      # Check we detected the expected issues
      issue_categories = Enum.map(critique_v1.issues, & &1.category)

      has_gate_warning = :missing_gate in issue_categories
      has_optimism_warning = :optimism_bias in issue_categories

      IO.puts("\n--- Issue Detection ---")
      IO.puts("Missing gate warning: #{has_gate_warning}")
      IO.puts("Optimism bias warning: #{has_optimism_warning}")

      # At least one of our expected issues should be detected
      assert has_gate_warning or has_optimism_warning,
             "Should detect missing gate or optimism bias"
    end
  end

  # Tests whether the MetaPlanner can generate valid PTC-Lisp verification predicates.
  # This is the critical first step before implementing verification in PlanRunner.
  # If LLMs struggle with Lisp syntax, we need helper functions.
  describe "verification predicate generation" do
    alias PtcRunner.Lisp.Parser

    @verification_missions [
      {:stock_research, "Research the current stock price for NVDA and AAPL"},
      {:weather_fetch, "Fetch the weather for New York and London"},
      {:api_data, "Fetch user data from an API and validate it has email and name fields"}
    ]

    @tag :verification
    test "MetaPlanner generates plans with Lisp verification predicates" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Verification Predicate Generation Test")
      IO.puts(String.duplicate("=", 60))

      mission =
        "Research the current stock price for NVDA. Ensure the result contains a valid price greater than 0."

      IO.puts("\n--- Generating Plan with Verification ---")
      {raw_plan, gen_ms} = timed_generate_plan_with_verification(mission)
      IO.puts("Plan generated in #{gen_ms}ms")
      IO.puts(format_plan(raw_plan))

      # Extract verification predicates from tasks
      verifications = extract_verifications(raw_plan)

      IO.puts("\n--- Extracted Verifications ---")

      if verifications == [] do
        IO.puts("⚠ No verification predicates found in plan")
        IO.puts("  This suggests the LLM didn't generate verification fields")
      else
        for {task_id, verification} <- verifications do
          IO.puts("\nTask: #{task_id}")
          IO.puts("Verification: #{verification}")

          # Test 1: Is it valid Lisp syntax?
          parse_result = Parser.parse(verification)

          case parse_result do
            {:ok, ast} ->
              IO.puts("✓ Valid Lisp syntax")
              IO.puts("  AST: #{inspect(ast, limit: 50)}")

              # Test 2: Can we run it with mock bindings?
              mock_bindings = %{
                "input" => %{"symbol" => "NVDA"},
                "result" => %{"symbol" => "NVDA", "price" => 950.0}
              }

              run_result =
                PtcRunner.Lisp.run(verification,
                  context: mock_bindings,
                  timeout: 1000
                )

              case run_result do
                {:ok, step} ->
                  IO.puts("✓ Runs successfully")
                  IO.puts("  Result: #{inspect(step.return)}")

                  # Check if it returns boolean or string (diagnosis)
                  valid_return =
                    is_boolean(step.return) or is_binary(step.return)

                  if valid_return do
                    IO.puts("✓ Returns boolean or diagnosis string")
                  else
                    IO.puts("⚠ Returns #{inspect(step.return)} - expected boolean or string")
                  end

                {:error, step} ->
                  IO.puts("✗ Execution failed: #{inspect(step.fail)}")
              end

            {:error, error} ->
              IO.puts("✗ Invalid Lisp syntax: #{inspect(error)}")
          end
        end
      end

      # Write results for analysis
      write_verification_result(mission, raw_plan, verifications)

      # Soft assertion - we're exploring
      assert is_map(raw_plan), "Should return a plan"
    end

    @tag :verification_input_awareness
    test "verification predicates reference input for context awareness" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Input Awareness Test")
      IO.puts(String.duplicate("=", 60))

      mission = "Fetch weather for the city 'Tokyo'. Verify the result is for the requested city."

      {raw_plan, _} = timed_generate_plan_with_verification(mission)
      verifications = extract_verifications(raw_plan)

      IO.puts("\n--- Checking for input references ---")

      input_aware =
        Enum.any?(verifications, fn {task_id, v} ->
          has_input = String.contains?(v, "data/input")
          IO.puts("Task #{task_id}: references data/input = #{has_input}")
          IO.puts("  Predicate: #{String.slice(v, 0, 100)}...")
          has_input
        end)

      if input_aware do
        IO.puts("\n✓ At least one verification references 'data/input'")
      else
        IO.puts("\n⚠ No verifications reference 'data/input'")
        IO.puts("  LLM may need prompt guidance to include input checks")
      end

      assert is_map(raw_plan)
    end

    @tag :verification_diagnosis
    test "verification predicates return diagnosis strings on failure" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Diagnosis String Test")
      IO.puts(String.duplicate("=", 60))

      mission =
        "Fetch API data. Verify the result has at least 5 items. If validation fails, return a helpful error message."

      {raw_plan, _} = timed_generate_plan_with_verification(mission)
      verifications = extract_verifications(raw_plan)

      IO.puts("\n--- Testing with failing mock data ---")

      for {task_id, verification} <- verifications do
        # Mock data that should fail validation (only 2 items)
        failing_bindings = %{
          "input" => %{},
          "result" => [%{"id" => 1}, %{"id" => 2}]
        }

        case Parser.parse(verification) do
          {:ok, _} ->
            run_result =
              PtcRunner.Lisp.run(verification,
                context: failing_bindings,
                timeout: 1000
              )

            case run_result do
              {:ok, step} ->
                IO.puts("\nTask #{task_id}:")
                IO.puts("  Result: #{inspect(step.return)}")

                cond do
                  step.return == false ->
                    IO.puts("  ⚠ Returns false (no diagnosis)")

                  is_binary(step.return) ->
                    IO.puts("  ✓ Returns diagnosis: \"#{step.return}\"")

                  step.return == true ->
                    IO.puts("  ⚠ Returns true (validation didn't catch the issue)")

                  true ->
                    IO.puts("  ⚠ Unexpected return type")
                end

              {:error, step} ->
                IO.puts("\nTask #{task_id}: execution error - #{inspect(step.fail)}")
            end

          {:error, _} ->
            IO.puts("\nTask #{task_id}: invalid Lisp syntax")
        end
      end

      assert is_map(raw_plan)
    end

    @tag :verification_all_missions
    test "generate verification for multiple mission types" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Multi-Mission Verification Test")
      IO.puts(String.duplicate("=", 60))

      results =
        for {name, mission} <- @verification_missions do
          IO.puts("\n--- #{name} ---")
          {raw_plan, ms} = timed_generate_plan_with_verification(mission)
          verifications = extract_verifications(raw_plan)

          valid_count =
            verifications
            |> Enum.count(fn {_, v} ->
              case Parser.parse(v) do
                {:ok, _} -> true
                _ -> false
              end
            end)

          IO.puts("Tasks: #{count_tasks(raw_plan)}")
          IO.puts("Verifications: #{length(verifications)} (#{valid_count} valid Lisp)")
          IO.puts("Time: #{ms}ms")

          {name, %{plan: raw_plan, verifications: verifications, valid_count: valid_count}}
        end

      # Summary
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Summary")
      IO.puts(String.duplicate("=", 60))
      IO.puts("\n| Mission | Verifications | Valid Lisp |")
      IO.puts("|---------|---------------|------------|")

      for {name, %{verifications: v, valid_count: vc}} <- results do
        IO.puts("| #{pad(name, 15)} | #{pad(length(v), 13)} | #{pad(vc, 10)} |")
      end

      total_verifications =
        results |> Enum.map(fn {_, r} -> length(r.verifications) end) |> Enum.sum()

      total_valid = results |> Enum.map(fn {_, r} -> r.valid_count end) |> Enum.sum()

      IO.puts("\nTotal verifications: #{total_verifications}")
      IO.puts("Total valid Lisp: #{total_valid}")

      if total_verifications > 0 do
        success_rate = Float.round(total_valid / total_verifications * 100, 1)
        IO.puts("Success rate: #{success_rate}%")

        if success_rate < 50 do
          IO.puts("\n⚠ Low success rate - consider adding verification helper functions")
        end
      else
        IO.puts("\n⚠ No verifications generated - LLM needs stronger prompt guidance")
      end

      write_verification_summary(results)

      assert length(results) == length(@verification_missions)
    end

    # --- Helpers for verification tests ---

    defp timed_generate_plan_with_verification(mission) do
      start = System.monotonic_time(:millisecond)
      plan = generate_plan_with_verification(mission)
      duration = System.monotonic_time(:millisecond) - start
      {plan, duration}
    end

    defp generate_plan_with_verification(mission) do
      planner =
        SubAgent.new(
          prompt: """
          Mission: {{mission}}

          You are a workflow architect. Design a plan to accomplish this mission.

          ## Plan Structure

          Return a JSON plan with this structure:
          ```json
          {
            "tasks": [
              {
                "id": "task_name",
                "agent": "researcher",
                "input": "What to do",
                "depends_on": [],
                "verification": "(Lisp predicate here)",
                "on_verification_failure": "retry"
              }
            ]
          }
          ```

          ## Verification Predicates (IMPORTANT)

          Each task MUST have a `verification` field containing a PTC-Lisp predicate.

          CRITICAL: Use `data/result` and `data/input` to access task output and input:
          - `data/input`: The task's input parameters (what was requested)
          - `data/result`: The task's output (what was returned)

          The predicate should return:
          - `true` if verification passes
          - A diagnosis string if verification fails (e.g., "Missing price field")

          ## IMPORTANT: Never Hardcode Values From Input

          When verifying that the result matches what was requested, ALWAYS reference
          `data/input` instead of hardcoding the value. This makes verification reusable.

          BAD (hardcoded):
          ```lisp
          (= (get data/result "city") "Tokyo")  ;; DON'T DO THIS
          ```

          GOOD (references input):
          ```lisp
          (= (get data/result "city") (get data/input "city"))  ;; DO THIS
          ```

          ## Example Verifications

          Check result is not nil:
          ```lisp
          (if (nil? data/result) "Result is nil" true)
          ```

          Check result has required fields:
          ```lisp
          (if (and (get data/result "price") (get data/result "symbol"))
            true
            "Missing required fields")
          ```

          Check result matches the requested input (MUST use data/input, not hardcoded values):
          ```lisp
          (if (= (get data/result "id") (get data/input "id"))
            true
            (str "Wrong id: expected " (get data/input "id") ", got " (get data/result "id")))
          ```

          Check minimum count:
          ```lisp
          (if (>= (count data/result) 5)
            true
            (str "Insufficient results: got " (count data/result) ", need 5"))
          ```

          ## Available Lisp Functions

          Predicates: nil?, empty?, map?, coll?
          Access: get, get-in, count, keys
          Logic: and, or, not, if, cond
          Comparison: =, <, >, <=, >=
          Strings: str (concatenation)

          REMEMBER:
          - Always use data/result and data/input, NOT plain result/input
          - Never hardcode values that come from input - reference data/input instead

          Generate the plan now.
          """,
          signature: "(mission :string) -> :map",
          output: :text,
          max_turns: 1,
          retry_turns: 2,
          timeout: 60_000
        )

      case SubAgent.run(planner, context: %{mission: mission}, llm: llm_callback()) do
        {:ok, step} -> step.return
        {:error, step} -> %{error: step.fail, raw: "Plan generation failed"}
      end
    end

    defp extract_verifications(plan) do
      tasks = plan["tasks"] || plan[:tasks] || []

      tasks
      |> Enum.filter(fn task ->
        v = task["verification"] || task[:verification]
        v != nil and is_binary(v) and String.length(v) > 0
      end)
      |> Enum.map(fn task ->
        id = task["id"] || task[:id] || "unknown"
        v = task["verification"] || task[:verification]
        {id, v}
      end)
    end

    defp write_verification_result(mission, plan, verifications) do
      content = """
      # Verification Generation Test

      ## Mission
      #{mission}

      ## Generated Plan
      ```json
      #{format_plan(plan)}
      ```

      ## Extracted Verifications
      #{for {id, v} <- verifications, into: "" do
        """
        ### #{id}
        ```lisp
        #{v}
        ```
        """
      end}

      ## Analysis
      - Total verifications: #{length(verifications)}
      - Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
      """

      File.write!("tmp/verification_generation_test.md", content)
      IO.puts("\nResults written to tmp/verification_generation_test.md")
    end

    defp write_verification_summary(results) do
      content = """
      # Verification Generation Summary

      Model: #{LLMSupport.model()}
      Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

      #{for {name, %{plan: plan, verifications: v, valid_count: vc}} <- results, into: "" do
        """
        ## #{name}

        Verifications: #{length(v)} (#{vc} valid)

        ```json
        #{format_plan(plan)}
        ```

        #{for {id, pred} <- v, into: "" do
          """
          ### #{id}
          ```lisp
          #{pred}
          ```
          """
        end}
        ---
        """
      end}
      """

      File.write!("tmp/verification_summary.md", content)
      IO.puts("\nSummary written to tmp/verification_summary.md")
    end
  end

  describe "human review gates" do
    @tag :human_review
    test "plan pauses at human review and resumes with decision" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Human Review Gate: Pause/Resume Flow")
      IO.puts(String.duplicate("=", 60))

      # Create a plan with a human review gate
      raw_plan = %{
        "tasks" => [
          %{
            "id" => "research",
            "input" =>
              "What is the current population of Tokyo? Return as JSON with a 'population' field."
          },
          %{
            "id" => "verify",
            "input" =>
              "Please verify: Is this population figure accurate? Context: {{results.research}}",
            "type" => "human_review",
            "depends_on" => ["research"]
          },
          %{
            "id" => "report",
            "input" =>
              "Write a brief report. Population data: {{results.research}}. Verification: {{results.verify}}",
            "depends_on" => ["verify"]
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw_plan)
      IO.puts("\nParsed plan with #{length(plan.tasks)} tasks")

      # First execution - should pause at human review
      IO.puts("\n--- First Execution (should pause) ---")
      start = System.monotonic_time(:millisecond)

      result1 =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          timeout: 30_000,
          max_turns: 1
        )

      ms1 = System.monotonic_time(:millisecond) - start

      case result1 do
        {:waiting, pending, partial} ->
          IO.puts("✓ Paused at human review (#{ms1}ms)")
          IO.puts("  Pending reviews: #{length(pending)}")

          for p <- pending do
            IO.puts("  - Task: #{p.task_id}")
            IO.puts("    Prompt: #{String.slice(p.prompt, 0, 80)}...")
          end

          IO.puts("  Partial results: #{inspect(Map.keys(partial))}")

          # Verify we have research results
          assert Map.has_key?(partial, "research")
          IO.puts("  Research result: #{inspect(partial["research"])}")

          # Simulate human decision
          human_decision = %{
            "verified" => true,
            "notes" => "Population figure looks accurate based on recent data"
          }

          IO.puts("\n--- Second Execution (with human decision) ---")
          IO.puts("Human decision: #{inspect(human_decision)}")

          start2 = System.monotonic_time(:millisecond)

          result2 =
            PlanRunner.execute(plan,
              llm: llm_callback(),
              timeout: 30_000,
              max_turns: 1,
              reviews: %{"verify" => human_decision}
            )

          ms2 = System.monotonic_time(:millisecond) - start2

          case result2 do
            {:ok, results} ->
              IO.puts("✓ Completed (#{ms2}ms)")
              IO.puts("  Final results:")

              for {task_id, value} <- results do
                IO.puts("  - #{task_id}: #{inspect(value, limit: 100)}")
              end

              # Verify all tasks completed
              assert Map.has_key?(results, "research")
              assert Map.has_key?(results, "verify")
              assert Map.has_key?(results, "report")

              # Verify human decision was used
              assert results["verify"] == human_decision

            {:error, task_id, _partial, reason} ->
              IO.puts("✗ Failed at #{task_id}: #{inspect(reason)}")
              flunk("Second execution failed: #{inspect(reason)}")

            {:waiting, more_pending, _} ->
              IO.puts("✗ Still waiting: #{inspect(more_pending)}")
              flunk("Should not still be waiting after providing review")
          end

        {:ok, results} ->
          IO.puts("✗ Did not pause - completed immediately (#{ms1}ms)")
          IO.puts("  Results: #{inspect(results)}")
          flunk("Should have paused at human_review task")

        {:error, task_id, _partial, reason} ->
          IO.puts("✗ Failed at #{task_id}: #{inspect(reason)}")
          flunk("Execution failed: #{inspect(reason)}")
      end
    end
  end

  defp write_execution_result(mission, raw_plan, parsed_plan, result, gen_ms, exec_ms) do
    {status, results_str} =
      case result do
        {:ok, results} ->
          {"SUCCESS", inspect(results, pretty: true)}

        {:error, task, partial, reason} ->
          {"FAILED at #{task}",
           "Reason: #{inspect(reason)}\nPartial: #{inspect(partial, pretty: true)}"}
      end

    content = """
    # Plan Execution: single_research

    ## Mission
    #{mission}

    ## Generated Plan (#{gen_ms}ms)
    ```json
    #{format_plan(raw_plan)}
    ```

    ## Parsed Plan
    Tasks: #{length(parsed_plan.tasks)}
    Agents: #{inspect(Map.keys(parsed_plan.agents))}

    ## Execution (#{exec_ms}ms)
    Status: #{status}

    ```
    #{results_str}
    ```
    """

    File.write!("tmp/meta_plan_execution.md", content)
    IO.puts("\nExecution results written to tmp/meta_plan_execution.md")
  end

  # --- Plan Generation ---

  defp timed_generate_plan(mission) do
    start = System.monotonic_time(:millisecond)
    plan = generate_plan(mission)
    duration = System.monotonic_time(:millisecond) - start
    {plan, duration}
  end

  defp generate_plan(mission) do
    planner =
      SubAgent.new(
        prompt: """
        Mission: {{mission}}

        You are a workflow architect. Design a plan to accomplish this mission.

        Consider:
        - What tasks are needed? (or is this simple enough to answer directly?)
        - Do tasks need specialized agents? (researcher, reviewer, synthesizer, etc.)
        - Which tasks can run in parallel vs must be sequential?
        - How should results be verified? (always, never, only for critical steps?)
        - What if a task fails? (retry, skip, replan, ask user?)

        Return your plan as JSON. Structure it however you think makes sense.
        If the mission is trivial, you can return a simple plan or indicate no agents needed.
        """,
        signature: "(mission :string) -> :map",
        output: :text,
        max_turns: 1,
        retry_turns: 2,
        timeout: 30_000
      )

    case SubAgent.run(planner, context: %{mission: mission}, llm: llm_callback()) do
      {:ok, step} -> step.return
      {:error, step} -> %{error: step.fail, raw: "Plan generation failed"}
    end
  end

  # --- Plan Evaluation ---

  defp evaluate_plan(plan, mission) do
    %{
      # Structure checks
      has_tasks: has_tasks?(plan),
      has_agents: mentions_agents?(plan),
      has_verification: mentions_verification?(plan),
      has_error_handling: mentions_error_handling?(plan),
      has_parallel: mentions_parallel?(plan),
      has_dependencies: mentions_dependencies?(plan),

      # Counts
      task_count: count_tasks(plan),
      agent_types: extract_agent_types(plan),

      # Complexity metrics
      mission_words: length(String.split(mission)),
      plan_depth: map_depth(plan),
      plan_size: map_size_recursive(plan)
    }
  end

  defp has_tasks?(plan) do
    Map.has_key?(plan, "tasks") || Map.has_key?(plan, "steps") ||
      Map.has_key?(plan, "workflow") || Map.has_key?(plan, "plan")
  end

  defp mentions_agents?(plan) do
    json = Jason.encode!(plan)

    String.contains?(json, "agent") ||
      String.contains?(json, "worker") ||
      String.contains?(json, "researcher")
  end

  defp mentions_verification?(plan) do
    json = Jason.encode!(plan)

    String.contains?(json, "verif") ||
      String.contains?(json, "review") ||
      String.contains?(json, "validat") ||
      String.contains?(json, "check")
  end

  defp mentions_error_handling?(plan) do
    json = Jason.encode!(plan)

    String.contains?(json, "fail") ||
      String.contains?(json, "retry") ||
      String.contains?(json, "error") ||
      String.contains?(json, "fallback")
  end

  defp mentions_parallel?(plan) do
    json = Jason.encode!(plan)

    String.contains?(json, "parallel") ||
      String.contains?(json, "concurrent") ||
      String.contains?(json, "batch")
  end

  defp mentions_dependencies?(plan) do
    json = Jason.encode!(plan)

    String.contains?(json, "depend") ||
      String.contains?(json, "requires") ||
      String.contains?(json, "after") ||
      String.contains?(json, "sequential")
  end

  defp count_tasks(plan) do
    cond do
      is_list(plan["tasks"]) -> length(plan["tasks"])
      is_list(plan["steps"]) -> length(plan["steps"])
      is_list(plan["workflow"]) -> length(plan["workflow"])
      is_map(plan["plan"]) and is_list(plan["plan"]["steps"]) -> length(plan["plan"]["steps"])
      true -> 0
    end
  end

  defp extract_agent_types(plan) do
    json = Jason.encode!(plan) |> String.downcase()

    ~w(researcher reviewer synthesizer planner worker validator analyzer fetcher comparator)
    |> Enum.filter(&String.contains?(json, &1))
  end

  defp map_depth(map, depth \\ 0)

  defp map_depth(map, depth) when is_map(map) do
    if map_size(map) == 0 do
      depth
    else
      Map.values(map) |> Enum.map(&map_depth(&1, depth + 1)) |> Enum.max()
    end
  end

  defp map_depth([], depth), do: depth

  defp map_depth(list, depth) when is_list(list) do
    Enum.map(list, &map_depth(&1, depth + 1)) |> Enum.max()
  end

  defp map_depth(_, depth), do: depth

  defp map_size_recursive(map) when is_map(map) do
    map_size(map) + (Map.values(map) |> Enum.map(&map_size_recursive/1) |> Enum.sum())
  end

  defp map_size_recursive(list) when is_list(list) do
    length(list) + (Enum.map(list, &map_size_recursive/1) |> Enum.sum())
  end

  defp map_size_recursive(_), do: 0

  # --- Output Formatting ---

  defp format_plan(plan) do
    Jason.encode!(plan, pretty: true)
  rescue
    _ -> inspect(plan, pretty: true, limit: :infinity)
  end

  defp print_evaluation(eval) do
    IO.puts("  Tasks: #{eval.task_count}")
    IO.puts("  Agent types: #{inspect(eval.agent_types)}")
    IO.puts("  Has verification: #{eval.has_verification}")
    IO.puts("  Has error handling: #{eval.has_error_handling}")
    IO.puts("  Has parallel execution: #{eval.has_parallel}")
    IO.puts("  Has dependencies: #{eval.has_dependencies}")
    IO.puts("  Plan depth: #{eval.plan_depth}, size: #{eval.plan_size}")
  end

  defp pad(value, width) when is_atom(value), do: pad(Atom.to_string(value), width)
  defp pad(value, width) when is_integer(value), do: pad(Integer.to_string(value), width)
  defp pad(value, width) when is_boolean(value), do: pad(Atom.to_string(value), width)

  defp pad(value, width) when is_binary(value) do
    String.pad_trailing(String.slice(value, 0, width), width)
  end

  # --- File Output ---

  defp write_result(name, mission, plan, evaluation, duration_ms) do
    content = """
    # #{name}

    ## Mission
    #{mission}

    ## Plan (#{duration_ms}ms)
    ```json
    #{format_plan(plan)}
    ```

    ## Evaluation
    #{inspect(evaluation, pretty: true)}

    ---
    """

    File.write!("tmp/meta_plan_#{name}.md", content)
  end

  defp write_summary(results) do
    content =
      results
      |> Enum.map_join("\n---\n\n", fn {name, %{plan: plan, evaluation: eval, duration_ms: ms}} ->
        """
        ## #{name} (#{ms}ms)

        Tasks: #{eval.task_count} | Agents: #{inspect(eval.agent_types)}
        Verification: #{eval.has_verification} | Error handling: #{eval.has_error_handling}

        ```json
        #{format_plan(plan)}
        ```

        """
      end)

    header = """
    # Meta-Planner Results

    Model: #{LLMSupport.model()}
    Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    ---

    """

    File.write!("tmp/meta_planner_summary.md", header <> content)
    IO.puts("\nResults written to tmp/meta_planner_summary.md")
  end

  # E2E tests for verification predicates in actual plan execution.
  # These tests validate that:
  # 1. LLM-generated verification predicates execute correctly
  # 2. Smart retry recovers from verification failures
  # 3. Verification integrates with the full execution flow
  describe "verification execution" do
    @tag :verification_execution
    @tag :skip
    test "LLM-generated plan with verification executes correctly" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Verification Execution: Full Flow")
      IO.puts(String.duplicate("=", 60))

      mission = "What is 2 + 2? Return the answer as a number."

      # Step 1: Generate plan with verification
      IO.puts("\n--- Generating Plan with Verification ---")
      {raw_plan, gen_ms} = timed_generate_plan_with_verification(mission)
      IO.puts("Generated in #{gen_ms}ms")
      IO.puts(format_plan(raw_plan))

      # Step 2: Parse plan
      {:ok, plan} = Plan.parse(raw_plan)
      IO.puts("\nParsed #{length(plan.tasks)} task(s)")

      # Log verification predicates
      for task <- plan.tasks do
        if task.verification do
          IO.puts("  Task #{task.id} verification: #{String.slice(task.verification, 0, 60)}...")
        end
      end

      # Step 3: Execute with real LLM
      IO.puts("\n--- Executing Plan ---")
      start = System.monotonic_time(:millisecond)

      result =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          timeout: 30_000,
          max_turns: 3
        )

      exec_ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, results} ->
          IO.puts("✓ Execution succeeded (#{exec_ms}ms)")

          for {task_id, value} <- results do
            IO.puts("  #{task_id}: #{inspect(value, limit: 50)}")
          end

          assert map_size(results) > 0

        {:error, task_id, partial, reason} ->
          IO.puts("✗ Execution failed at #{task_id} (#{exec_ms}ms)")
          IO.puts("  Reason: #{inspect(reason)}")
          IO.puts("  Partial: #{inspect(Map.keys(partial))}")

          # Don't hard-fail for exploration
          IO.puts("\n⚠ Verification may need tuning - check predicate vs actual output")

        {:replan_required, context} ->
          IO.puts("⚠ Replan requested for task #{context.task_id}")
          IO.puts("  Diagnosis: #{context.diagnosis}")
          IO.puts("  Output: #{inspect(context.task_output, limit: 50)}")
      end

      # Write results
      write_verification_execution_result(mission, raw_plan, result)
    end

    @tag :verification_smart_retry_e2e
    @tag :skip
    test "smart retry recovers from initial verification failure" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Verification Execution: Smart Retry")
      IO.puts(String.duplicate("=", 60))

      # Mission that might need retries
      mission = "List exactly 3 programming languages. Return as a JSON array called 'languages'."

      # Generate plan with retry-enabled verification
      IO.puts("\n--- Generating Plan with Retry Verification ---")
      {raw_plan, _} = timed_generate_plan_with_verification(mission)

      # Force retry on verification failure
      raw_plan =
        update_in(raw_plan, ["tasks", Access.all()], fn task ->
          Map.merge(task, %{
            "on_verification_failure" => "retry",
            "max_retries" => 3
          })
        end)

      IO.puts(format_plan(raw_plan))

      {:ok, plan} = Plan.parse(raw_plan)

      # Execute
      IO.puts("\n--- Executing with Retry-Enabled Verification ---")
      start = System.monotonic_time(:millisecond)

      result =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          timeout: 30_000,
          max_turns: 5
        )

      exec_ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, results} ->
          IO.puts("✓ Succeeded (#{exec_ms}ms)")

          for {task_id, value} <- results do
            IO.puts("  #{task_id}: #{inspect(value, limit: 80)}")
          end

        {:error, task_id, _, reason} ->
          IO.puts("✗ Failed at #{task_id} after retries")
          IO.puts("  Reason: #{inspect(reason)}")

        {:replan_required, context} ->
          IO.puts("⚠ Replan requested: #{context.diagnosis}")
      end
    end

    @tag :verification_data_depends_e2e
    @tag :skip
    test "verification uses data/depends to compare against upstream results" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Verification Execution: data/depends Access")
      IO.puts(String.duplicate("=", 60))

      # Multi-step mission where downstream verifies against upstream
      mission = """
      Step 1: Generate a list of 5 random numbers between 1 and 100.
      Step 2: Filter the list to only include numbers greater than 50.
      Verify that the filtered list is a subset of the original list.
      """

      IO.puts("\n--- Generating Multi-Step Plan ---")
      {raw_plan, _} = timed_generate_plan_with_verification(mission)
      IO.puts(format_plan(raw_plan))

      {:ok, plan} = Plan.parse(raw_plan)
      IO.puts("\nParsed #{length(plan.tasks)} task(s)")

      # Check for data/depends references in verification
      has_depends_ref =
        Enum.any?(plan.tasks, fn task ->
          task.verification && String.contains?(task.verification, "data/depends")
        end)

      if has_depends_ref do
        IO.puts("✓ Found data/depends references in verification predicates")
      else
        IO.puts("⚠ No data/depends references found - may use different pattern")
      end

      # Execute
      IO.puts("\n--- Executing ---")
      start = System.monotonic_time(:millisecond)

      result =
        PlanRunner.execute(plan,
          llm: llm_callback(),
          timeout: 30_000,
          max_turns: 3
        )

      exec_ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, results} ->
          IO.puts("✓ Succeeded (#{exec_ms}ms)")
          IO.puts("  Results: #{inspect(results, limit: 100)}")

        {:error, task_id, partial, reason} ->
          IO.puts("✗ Failed at #{task_id}")
          IO.puts("  Partial: #{inspect(partial, limit: 100)}")
          IO.puts("  Reason: #{inspect(reason)}")

        other ->
          IO.puts("  Result: #{inspect(other)}")
      end
    end

    defp write_verification_execution_result(mission, plan, result) do
      status =
        case result do
          {:ok, _} -> "SUCCESS"
          {:error, _, _, _} -> "FAILED"
          {:replan_required, _} -> "REPLAN_REQUIRED"
          _ -> "UNKNOWN"
        end

      content = """
      # Verification Execution Test

      ## Mission
      #{mission}

      ## Plan
      ```json
      #{format_plan(plan)}
      ```

      ## Result: #{status}
      ```elixir
      #{inspect(result, pretty: true, limit: 200)}
      ```

      Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
      """

      File.write!("tmp/verification_execution_test.md", content)
      IO.puts("\nResults written to tmp/verification_execution_test.md")
    end
  end

  # E2E tests for the PlanExecutor replan loop.
  # These tests validate that:
  # 1. Verification failures with :replan trigger MetaPlanner
  # 2. MetaPlanner generates valid repair plans
  # 3. The execution loop completes successfully after replanning
  describe "tail replanning (Phase 2)" do
    alias PtcRunner.MetaPlanner
    alias PtcRunner.PlanExecutor

    @tag :replan_e2e
    @tag :skip
    test "PlanExecutor handles replan loop end-to-end" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Tail Replanning: Full E2E Flow")
      IO.puts(String.duplicate("=", 60))

      mission =
        "Find the current stock price of Apple (AAPL). Return as a map with 'symbol' and 'price' keys."

      # Create a plan where the first attempt will likely fail verification
      # (price must be a positive number, not a string)
      raw_plan = %{
        "agents" => %{
          "researcher" => %{
            "prompt" => "You are a financial researcher. Return data as JSON.",
            "tools" => []
          }
        },
        "tasks" => [
          %{
            "id" => "fetch_price",
            "agent" => "researcher",
            "input" => mission,
            # Strict verification - price must be a number > 0
            "verification" =>
              "(and (map? data/result) (number? (get data/result \"price\")) (> (get data/result \"price\") 0))",
            "on_verification_failure" => "replan",
            "max_retries" => 2
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw_plan)

      IO.puts("\n--- Initial Plan ---")
      IO.puts("Tasks: #{length(plan.tasks)}")

      for task <- plan.tasks do
        IO.puts("  #{task.id}: #{String.slice(to_string(task.input), 0, 50)}...")

        if task.verification do
          IO.puts("    Verification: #{String.slice(task.verification, 0, 60)}...")
        end
      end

      IO.puts("\n--- Executing via PlanExecutor ---")
      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.execute(plan, mission,
          llm: llm_callback(),
          timeout: 30_000,
          max_turns: 3,
          max_total_replans: 3,
          max_replan_attempts: 2,
          replan_cooldown_ms: 500
        )

      exec_ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, metadata} ->
          IO.puts("\n✓ Execution succeeded (#{exec_ms}ms)")
          IO.puts("  Replan count: #{metadata.replan_count}")
          IO.puts("  Execution attempts: #{metadata.execution_attempts}")
          IO.puts("  Total duration: #{metadata.total_duration_ms}ms")

          if metadata.replan_history != [] do
            IO.puts("\n--- Replan History ---")

            for {entry, idx} <- Enum.with_index(metadata.replan_history) do
              IO.puts("  #{idx + 1}. Task '#{entry.task_id}' failed: #{entry.diagnosis}")
            end
          end

          IO.puts("\n--- Final Results ---")

          for {task_id, value} <- metadata.results do
            IO.puts("  #{task_id}: #{inspect(value, limit: 100)}")
          end

          # Verify we got a valid result
          assert Map.has_key?(metadata.results, "fetch_price")

        {:error, reason, metadata} ->
          IO.puts(
            "\n✗ Execution failed after #{metadata.execution_attempts} attempts (#{exec_ms}ms)"
          )

          IO.puts("  Reason: #{inspect(reason)}")
          IO.puts("  Replan count: #{metadata.replan_count}")

          if metadata.replan_history != [] do
            IO.puts("\n--- Replan History ---")

            for entry <- metadata.replan_history do
              IO.puts("  Task '#{entry.task_id}': #{entry.diagnosis}")
            end
          end

          # For exploration, don't hard-fail
          IO.puts("\n⚠ This may indicate the LLM couldn't satisfy the verification")

        {:waiting, pending, _metadata} ->
          IO.puts("\n⏸ Paused for human review")
          IO.puts("  Pending: #{inspect(Enum.map(pending, & &1.task_id))}")
      end

      # Write results for analysis
      write_replan_test_result(mission, raw_plan, result, exec_ms)
    end

    @tag :replan_multi_task
    @tag :skip
    test "replan preserves completed tasks in multi-step workflow" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("Tail Replanning: Multi-Task Preservation")
      IO.puts(String.duplicate("=", 60))

      mission =
        "Research the Elixir programming language: find its creator and the year it was released."

      # Multi-step plan: step 1 likely succeeds, step 2 has strict verification
      raw_plan = %{
        "agents" => %{
          "researcher" => %{
            "prompt" => "You are a programming language historian. Always return JSON.",
            "tools" => []
          }
        },
        "tasks" => [
          %{
            "id" => "find_creator",
            "agent" => "researcher",
            "input" =>
              "Who created the Elixir programming language? Return as {\"creator\": \"name\"}",
            "verification" => "(and (map? data/result) (string? (get data/result \"creator\")))"
          },
          %{
            "id" => "find_year",
            "agent" => "researcher",
            "input" =>
              "What year was Elixir first released? Return as {\"year\": number}. The year must be a number between 2010 and 2015.",
            "depends_on" => ["find_creator"],
            # Strict verification - year must be in valid range
            "verification" =>
              "(and (map? data/result) (number? (get data/result \"year\")) (>= (get data/result \"year\") 2010) (<= (get data/result \"year\") 2015))",
            "on_verification_failure" => "replan",
            "max_retries" => 2
          }
        ]
      }

      {:ok, plan} = Plan.parse(raw_plan)

      IO.puts("\n--- Initial Plan ---")

      for task <- plan.tasks do
        deps =
          if task.depends_on == [],
            do: "",
            else: " (depends: #{Enum.join(task.depends_on, ", ")})"

        IO.puts("  #{task.id}#{deps}")
      end

      IO.puts("\n--- Executing ---")
      start = System.monotonic_time(:millisecond)

      result =
        PlanExecutor.execute(plan, mission,
          llm: llm_callback(),
          timeout: 30_000,
          max_turns: 3,
          max_total_replans: 2,
          replan_cooldown_ms: 500
        )

      exec_ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, metadata} ->
          IO.puts("\n✓ Success (#{exec_ms}ms, #{metadata.replan_count} replans)")

          # Check that find_creator was only executed once (preserved across replans)
          IO.puts("\n--- Results ---")

          for {task_id, value} <- metadata.results do
            IO.puts("  #{task_id}: #{inspect(value, limit: 80)}")
          end

          assert Map.has_key?(metadata.results, "find_creator")
          assert Map.has_key?(metadata.results, "find_year")

        {:error, reason, metadata} ->
          IO.puts("\n✗ Failed: #{inspect(reason)}")
          IO.puts("  Attempts: #{metadata.execution_attempts}, Replans: #{metadata.replan_count}")

        _ ->
          IO.puts("\nUnexpected result")
      end
    end

    @tag :metaplanner_direct
    @tag :skip
    test "MetaPlanner generates valid repair plan" do
      IO.puts("\n" <> String.duplicate("=", 60))
      IO.puts("MetaPlanner: Direct Repair Plan Generation")
      IO.puts(String.duplicate("=", 60))

      mission = "Get the current temperature in San Francisco"

      completed_results = %{
        "get_location" => %{"city" => "San Francisco", "state" => "CA"}
      }

      failure_context = %{
        task_id: "get_weather",
        task_output: %{"temp" => "unknown"},
        diagnosis: "Temperature must be a number, got string 'unknown'"
      }

      IO.puts("\n--- Failure Context ---")
      IO.puts("  Task: #{failure_context.task_id}")
      IO.puts("  Output: #{inspect(failure_context.task_output)}")
      IO.puts("  Diagnosis: #{failure_context.diagnosis}")

      IO.puts("\n--- Completed Results ---")

      for {task_id, value} <- completed_results do
        IO.puts("  #{task_id}: #{inspect(value)}")
      end

      IO.puts("\n--- Generating Repair Plan ---")
      start = System.monotonic_time(:millisecond)

      result =
        MetaPlanner.replan(
          mission,
          completed_results,
          failure_context,
          llm: llm_callback(),
          timeout: 30_000
        )

      gen_ms = System.monotonic_time(:millisecond) - start

      case result do
        {:ok, repair_plan} ->
          IO.puts("\n✓ Repair plan generated (#{gen_ms}ms)")
          IO.puts("  Tasks: #{length(repair_plan.tasks)}")

          IO.puts("\n--- Repair Plan Tasks ---")

          for task <- repair_plan.tasks do
            deps =
              if task.depends_on == [],
                do: "",
                else: " (depends: #{Enum.join(task.depends_on, ", ")})"

            IO.puts("  #{task.id}#{deps}: #{String.slice(to_string(task.input), 0, 60)}...")
          end

          # Verify the repair plan includes the completed task ID
          task_ids = Enum.map(repair_plan.tasks, & &1.id)
          IO.puts("\n--- Validation ---")
          has_location = "get_location" in task_ids
          has_weather = Enum.any?(task_ids, &String.contains?(&1, "weather"))
          IO.puts("  Contains 'get_location': #{has_location}")
          IO.puts("  Contains weather task: #{has_weather}")

          assert repair_plan.tasks != []

        {:error, reason} ->
          IO.puts("\n✗ Failed to generate repair plan")
          IO.puts("  Reason: #{inspect(reason)}")
      end
    end

    defp write_replan_test_result(mission, plan, result, duration_ms) do
      status =
        case result do
          {:ok, meta} -> "SUCCESS (#{meta.replan_count} replans)"
          {:error, reason, _} -> "FAILED: #{inspect(reason)}"
          {:waiting, _, _} -> "WAITING"
        end

      content = """
      # Tail Replanning E2E Test

      ## Mission
      #{mission}

      ## Initial Plan
      ```json
      #{Jason.encode!(plan, pretty: true)}
      ```

      ## Result: #{status}
      Duration: #{duration_ms}ms

      ```elixir
      #{inspect(result, pretty: true, limit: 500)}
      ```

      Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}
      """

      File.write!("tmp/replan_e2e_test.md", content)
      IO.puts("\nResults written to tmp/replan_e2e_test.md")
    end
  end

  # --- Mission Helper ---

  defp missions do
    Map.new(@missions)
  end

  # --- LLM Callback ---

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]

      case LLM.generate_text(LLMSupport.model(), full_messages, receive_timeout: 30_000) do
        {:ok, text} -> {:ok, text}
        {:error, _} = error -> error
      end
    end
  end
end
