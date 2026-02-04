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
        output: :json,
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

  defp map_depth(list, depth) when is_list(list) do
    if length(list) == 0 do
      depth
    else
      Enum.map(list, &map_depth(&1, depth + 1)) |> Enum.max()
    end
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
      |> Enum.map(fn {name, %{plan: plan, evaluation: eval, duration_ms: ms}} ->
        """
        ## #{name} (#{ms}ms)

        Tasks: #{eval.task_count} | Agents: #{inspect(eval.agent_types)}
        Verification: #{eval.has_verification} | Error handling: #{eval.has_error_handling}

        ```json
        #{format_plan(plan)}
        ```

        """
      end)
      |> Enum.join("\n---\n\n")

    header = """
    # Meta-Planner Results

    Model: #{LLMSupport.model()}
    Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    ---

    """

    File.write!("tmp/meta_planner_summary.md", header <> content)
    IO.puts("\nResults written to tmp/meta_planner_summary.md")
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
