defmodule PtcRunner.CapabilityRegistry.TrialHistoryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.CapabilityRegistry.{Registry, Skill, TrialHistory}

  describe "record_trial/2" do
    test "updates tool success rates" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.register_base_tool("parse", fn _ -> [] end)

      result = %{
        tools_used: ["search", "parse"],
        skills_used: [],
        context_tags: ["web"],
        success: true
      }

      updated = TrialHistory.record_trial(registry, result)

      search = Registry.get_tool(updated, "search")
      assert search.success_rate == 1.0
      assert Map.has_key?(search.context_success, "web")
    end

    test "updates skill success rates" do
      skill = Skill.new("tips", "Tips", "...")

      registry =
        Registry.new()
        |> Registry.register_skill(skill)

      result = %{
        tools_used: [],
        skills_used: ["tips"],
        context_tags: ["csv"],
        model_id: "claude-3",
        success: true
      }

      updated = TrialHistory.record_trial(registry, result)

      tips = Registry.get_skill(updated, "tips")
      assert tips.success_rate == 1.0
      assert Map.has_key?(tips.context_success, "csv")
      assert Map.has_key?(tips.model_success, "claude-3")
    end

    test "handles outcome-based success detection" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> [] end)

      # All outcomes success
      result = %{
        outcomes: %{"t1" => :success, "t2" => :success},
        tools_used: ["tool"],
        context_tags: []
      }

      updated = TrialHistory.record_trial(registry, result)
      tool = Registry.get_tool(updated, "tool")
      assert tool.success_rate == 1.0
    end

    test "detects failure from outcomes" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> [] end)

      # Some outcomes failed
      result = %{
        outcomes: %{"t1" => :success, "t2" => {:error, "failed"}},
        tools_used: ["tool"],
        context_tags: []
      }

      # Record multiple failures to see rate drop
      updated =
        Enum.reduce(1..10, registry, fn _, acc ->
          TrialHistory.record_trial(acc, result)
        end)

      tool = Registry.get_tool(updated, "tool")
      # Rate should drop due to failures
      assert tool.success_rate < 1.0
    end
  end

  describe "update_tool_statistics/3" do
    test "updates success rate with EMA" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> [] end)

      outcome = %{
        success: false,
        context_tags: ["test"]
      }

      # Multiple failures should decrease rate
      updated =
        Enum.reduce(1..10, registry, fn _, acc ->
          TrialHistory.update_tool_statistics(acc, "tool", outcome)
        end)

      tool = Registry.get_tool(updated, "tool")
      assert tool.success_rate < 0.5
    end
  end

  describe "get_context_warnings/2" do
    test "returns warnings for low context success" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("risky", fn _ -> [] end)
        |> then(fn r ->
          tool = Registry.get_tool(r, "risky")
          updated = %{tool | context_success: %{"unicode" => 0.2, "normal" => 0.9}}
          %{r | tools: Map.put(r.tools, "risky", updated)}
        end)

      warnings = TrialHistory.get_context_warnings(registry, ["unicode", "normal"])

      assert length(warnings) == 1
      [warning] = warnings
      assert warning.tool_id == "risky"
      assert warning.tag == "unicode"
      assert warning.rate == 0.2
    end

    test "returns empty for high success contexts" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("good", fn _ -> [] end)
        |> then(fn r ->
          tool = Registry.get_tool(r, "good")
          updated = %{tool | context_success: %{"stable" => 0.95}}
          %{r | tools: Map.put(r.tools, "good", updated)}
        end)

      warnings = TrialHistory.get_context_warnings(registry, ["stable"])
      assert warnings == []
    end
  end

  describe "get_repair_candidates/2" do
    test "returns tools with low success rates" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("broken", fn _ -> [] end)
        |> Registry.register_base_tool("good", fn _ -> [] end)
        |> then(fn r ->
          broken = Registry.get_tool(r, "broken")
          updated_broken = %{broken | success_rate: 0.3, link_count: 20}
          good = Registry.get_tool(r, "good")
          updated_good = %{good | success_rate: 0.9, link_count: 20}

          %{
            r
            | tools:
                r.tools
                |> Map.put("broken", updated_broken)
                |> Map.put("good", updated_good)
          }
        end)

      candidates = TrialHistory.get_repair_candidates(registry, threshold: 0.5, min_trials: 10)

      assert length(candidates) == 1
      assert hd(candidates).id == "broken"
    end

    test "requires minimum trials" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("new", fn _ -> [] end)
        |> then(fn r ->
          tool = Registry.get_tool(r, "new")
          updated = %{tool | success_rate: 0.2, link_count: 3}
          %{r | tools: Map.put(r.tools, "new", updated)}
        end)

      candidates = TrialHistory.get_repair_candidates(registry, min_trials: 10)
      assert candidates == []
    end
  end

  describe "get_model_warnings/3" do
    test "returns skills with low model effectiveness" do
      skill1 =
        Skill.new("bad_for_model", "Bad", "...")
        |> then(&%{&1 | model_success: %{"claude-3" => 0.3}})

      skill2 =
        Skill.new("good_for_model", "Good", "...")
        |> then(&%{&1 | model_success: %{"claude-3" => 0.9}})

      registry =
        Registry.new()
        |> Registry.register_skill(skill1)
        |> Registry.register_skill(skill2)

      warnings = TrialHistory.get_model_warnings(registry, "claude-3", threshold: 0.5)

      assert length(warnings) == 1
      assert hd(warnings).id == "bad_for_model"
    end
  end

  describe "aggregate_statistics/1" do
    test "computes registry statistics" do
      skill = Skill.new("s1", "Skill", "...")

      registry =
        Registry.new()
        |> Registry.register_base_tool("t1", fn _ -> [] end)
        |> Registry.register_base_tool("t2", fn _ -> [] end)
        |> Registry.register_skill(skill)
        |> Registry.mark_healthy("t1")
        |> Registry.mark_unhealthy("t2")

      stats = TrialHistory.aggregate_statistics(registry)

      assert stats.tool_count == 2
      assert stats.skill_count == 1
      assert stats.healthy_tools == 1
      assert stats.unhealthy_tools == 1
    end
  end
end
