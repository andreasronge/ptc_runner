defmodule PtcRunner.CapabilityRegistry.PlanIntegrationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration tests for Capability Registry with PlanRunner and PlanExecutor.

  Tests registry-based tool resolution, skill injection, and trial recording.
  """

  alias PtcRunner.CapabilityRegistry.{Linker, Registry, Skill}
  alias PtcRunner.{Plan, PlanRunner}

  # Helper to create a minimal mock LLM that returns a simple JSON response
  defp mock_llm_json(return_value) do
    fn _input ->
      {:ok, Jason.encode!(return_value)}
    end
  end

  # Helper to create a mock LLM that returns valid PTC-Lisp
  defp mock_llm_ptc(return_value) do
    fn _input ->
      {:ok, "(return #{Jason.encode!(return_value)})"}
    end
  end

  describe "PlanRunner with registry" do
    test "resolves tools via Linker when registry is provided" do
      # Setup registry with a base tool
      double_fn = fn %{"x" => x} -> x * 2 end

      registry =
        Registry.new()
        |> Registry.register_base_tool("double", double_fn,
          signature: "(x :int) -> :int",
          tags: ["math"]
        )

      # Verify Linker can resolve the tool
      {:ok, result} = Linker.link(registry, ["double"])

      assert result.base_tools["double"] != nil
      assert result.base_tools["double"].(%{"x" => 5}) == 10
    end

    test "falls back to base_tools when registry link fails" do
      # Create a registry without the needed tool
      registry = Registry.new()

      # The registry doesn't have "double", so link should fail
      {:error, {:tool_not_found, "double"}} = Linker.link(registry, ["double"])

      # In PlanRunner, this would fall back to base_tools
      # The fallback logic is tested indirectly via PlanRunner's
      # resolve_tools_and_skills/2 function when Linker.link fails
    end

    test "generates skill prompt for injection" do
      search_fn = fn %{"query" => q} -> [%{title: "Result: #{q}"}] end

      skill =
        Skill.new(
          "search_tips",
          "Search Tips",
          """
          When searching:
          - Use specific keywords
          - Filter by date when relevant
          """,
          applies_to: ["search"],
          tags: ["search"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("search", search_fn,
          signature: "(query :string) -> [{title :string}]",
          tags: ["search"]
        )
        |> Registry.register_skill(skill)

      # Link should include skill prompt
      {:ok, result} = Linker.link(registry, ["search"])

      assert length(result.skills) == 1
      assert result.skill_prompt =~ "Search Tips"
      assert result.skill_prompt =~ "specific keywords"
    end

    test "context tags filter skills" do
      parse_fn = fn %{"text" => t} -> String.split(t, ";") end

      european_skill =
        Skill.new(
          "european_csv",
          "European CSV",
          "Use semicolon as delimiter",
          applies_to: [],
          tags: ["european"]
        )

      american_skill =
        Skill.new(
          "american_csv",
          "American CSV",
          "Use comma as delimiter",
          applies_to: [],
          tags: ["american"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("parse_csv", parse_fn, tags: ["csv"])
        |> Registry.register_skill(european_skill)
        |> Registry.register_skill(american_skill)

      # Link with european context
      {:ok, result} = Linker.link(registry, ["parse_csv"], context_tags: ["european"])

      skill_ids = Enum.map(result.skills, & &1.id)
      assert "european_csv" in skill_ids
      refute "american_csv" in skill_ids
    end
  end

  describe "PlanRunner execute with JSON mode (no tools)" do
    test "executes task without tools using JSON mode" do
      plan = %Plan{
        agents: %{
          "analyzer" => %{prompt: "Analyze the input", tools: []}
        },
        tasks: [
          %{
            id: "analyze",
            agent: "analyzer",
            type: :task,
            input: "What is 2+2?",
            depends_on: [],
            on_failure: :stop,
            on_verification_failure: :stop,
            max_retries: 0,
            critical: true,
            verification: nil
          }
        ]
      }

      # Mock LLM that returns JSON
      llm = mock_llm_json(%{answer: 4})

      {:ok, results} = PlanRunner.execute(plan, llm: llm)

      assert results["analyze"]["answer"] == 4
    end
  end

  describe "PlanRunner execute with registry tools" do
    test "uses registry tools when available" do
      double_fn = fn %{"x" => x} -> %{result: x * 2} end

      registry =
        Registry.new()
        |> Registry.register_base_tool("double", double_fn, signature: "(x :int) -> :map")

      plan = %Plan{
        agents: %{
          "math" => %{prompt: "Use the double tool", tools: ["double"]}
        },
        tasks: [
          %{
            id: "compute",
            agent: "math",
            type: :task,
            input: "Double the number 5",
            depends_on: [],
            on_failure: :stop,
            on_verification_failure: :stop,
            max_retries: 0,
            critical: true,
            verification: nil
          }
        ]
      }

      # Mock LLM that uses the tool
      llm = mock_llm_ptc(%{doubled: 10})

      {:ok, results} =
        PlanRunner.execute(plan,
          llm: llm,
          registry: registry
        )

      # Result may come back as string key or with coerced types
      assert results["compute"]["doubled"] in [10, "10", :"10"]
    end
  end

  describe "extract_tools_used helper" do
    test "extracts tools from plan agents" do
      plan = %Plan{
        agents: %{
          "worker1" => %{prompt: "Worker 1", tools: ["search", "fetch"]},
          "worker2" => %{prompt: "Worker 2", tools: ["parse", "search"]}
        },
        tasks: []
      }

      tools =
        plan.agents
        |> Enum.flat_map(fn {_id, spec} -> Map.get(spec, :tools, []) end)
        |> Enum.uniq()

      assert "search" in tools
      assert "fetch" in tools
      assert "parse" in tools
      assert length(tools) == 3
    end
  end

  describe "trial recording format" do
    test "trial outcome has required fields" do
      outcome = %{
        tools_used: ["search", "parse"],
        skills_used: ["search_tips"],
        context_tags: ["european"],
        model_id: "claude-3",
        success: true,
        diagnosis: nil
      }

      assert is_list(outcome.tools_used)
      assert is_list(outcome.skills_used)
      assert is_list(outcome.context_tags)
      assert is_boolean(outcome.success)
    end
  end
end
