defmodule PtcRunner.CapabilityRegistry.DiscoveryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.CapabilityRegistry.{Capability, Discovery, Registry, Skill}

  describe "search/3" do
    test "finds tools by tag match" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("parse_csv", fn _ -> [] end, tags: ["csv", "parsing"])
        |> Registry.register_base_tool("other_tool", fn _ -> [] end,
          tags: ["unrelated", "different"]
        )

      results = Discovery.search(registry, "csv parsing", min_score: 0.5)
      assert [_] = results
      assert hd(results).id == "parse_csv"
      assert hd(results).match_type == :tag
    end

    test "finds tools by fuzzy name match" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("parse_csv_file", fn _ -> [] end,
          name: "CSV File Parser",
          tags: []
        )

      results = Discovery.search(registry, "csv parser")
      assert results != []
      assert hd(results).match_type == :fuzzy
    end

    test "applies context affinity boost" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("generic", fn _ -> [] end, tags: ["csv"])
        |> Registry.register_base_tool("european", fn _ -> [] end, tags: ["csv"])
        |> then(fn r ->
          # Update european tool to have high context success for "european"
          tool = Registry.get_tool(r, "european")
          updated = %{tool | context_success: %{"european" => 0.95}}
          %{r | tools: Map.put(r.tools, "european", updated)}
        end)

      results = Discovery.search(registry, "csv", context_tags: ["european"])

      # European should score higher due to context affinity
      ids = Enum.map(results, & &1.id)
      assert hd(ids) == "european"
    end

    test "respects min_score option" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("tool1", fn _ -> [] end, tags: ["exact"])
        |> Registry.register_base_tool("tool2", fn _ -> [] end, tags: [])

      results = Discovery.search(registry, "exact", min_score: 0.9)
      # Only high-scoring matches
      assert Enum.all?(results, &(&1.score >= 0.9))
    end

    test "respects limit option" do
      registry =
        1..20
        |> Enum.reduce(Registry.new(), fn i, r ->
          Registry.register_base_tool(r, "tool#{i}", fn _ -> [] end, tags: ["common"])
        end)

      results = Discovery.search(registry, "common", limit: 5)
      assert length(results) == 5
    end
  end

  describe "search_skills/3" do
    test "finds skills by tool association" do
      skill1 = Skill.new("csv_tips", "CSV Tips", "...", applies_to: ["parse_csv"])
      skill2 = Skill.new("other", "Other", "...", applies_to: ["other_tool"])

      registry =
        Registry.new()
        |> Registry.register_skill(skill1)
        |> Registry.register_skill(skill2)

      results = Discovery.search_skills(registry, [], tool_ids: ["parse_csv"])
      assert [_] = results
      assert hd(results).id == "csv_tips"
    end

    test "finds skills by context tags" do
      skill1 = Skill.new("euro", "Euro", "...", tags: ["european", "i18n"])
      skill2 = Skill.new("us", "US", "...", tags: ["american"])

      registry =
        Registry.new()
        |> Registry.register_skill(skill1)
        |> Registry.register_skill(skill2)

      results = Discovery.search_skills(registry, ["european"])
      assert [_] = results
      assert hd(results).id == "euro"
    end

    test "filters by model effectiveness" do
      skill1 =
        Skill.new("good_for_claude", "Good", "...")
        |> then(&%{&1 | model_success: %{"claude-3" => 0.95}})

      skill2 =
        Skill.new("bad_for_claude", "Bad", "...")
        |> then(&%{&1 | model_success: %{"claude-3" => 0.3}})

      registry =
        Registry.new()
        |> Registry.register_skill(%{skill1 | tags: ["test"]})
        |> Registry.register_skill(%{skill2 | tags: ["test"]})

      results = Discovery.search_skills(registry, ["test"], model_id: "claude-3", min_score: 0.5)

      assert [_] = results
      assert hd(results).id == "good_for_claude"
    end

    test "sorts by effectiveness" do
      skill1 =
        Skill.new("low", "Low", "...")
        |> then(&%{&1 | success_rate: 0.6, tags: ["test"]})

      skill2 =
        Skill.new("high", "High", "...")
        |> then(&%{&1 | success_rate: 0.9, tags: ["test"]})

      registry =
        Registry.new()
        |> Registry.register_skill(skill1)
        |> Registry.register_skill(skill2)

      results = Discovery.search_skills(registry, ["test"])
      ids = Enum.map(results, & &1.id)
      assert hd(ids) == "high"
    end
  end

  describe "resolve/3" do
    test "returns best implementation for capability" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("v1", fn _ -> [] end,
          capability_id: "parse",
          tags: []
        )
        |> Registry.register_base_tool("v2", fn _ -> [] end,
          capability_id: "parse",
          tags: []
        )
        |> Registry.mark_healthy("v1")
        |> Registry.mark_healthy("v2")
        |> then(fn r ->
          # Make v1 have lower success rate
          tool1 = Registry.get_tool(r, "v1")
          updated1 = %{tool1 | success_rate: 0.7}
          # Make v2 have higher success rate
          tool2 = Registry.get_tool(r, "v2")
          updated2 = %{tool2 | success_rate: 0.95}
          %{r | tools: r.tools |> Map.put("v1", updated1) |> Map.put("v2", updated2)}
        end)

      {:ok, best} = Discovery.resolve(registry, "parse", [])
      assert best == "v2"
    end

    test "considers context affinity" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("generic", fn _ -> [] end, capability_id: "parse")
        |> Registry.register_base_tool("european", fn _ -> [] end, capability_id: "parse")
        |> Registry.mark_healthy("generic")
        |> Registry.mark_healthy("european")
        |> then(fn r ->
          tool = Registry.get_tool(r, "european")
          updated = %{tool | context_success: %{"eu" => 0.98}}
          %{r | tools: Map.put(r.tools, "european", updated)}
        end)

      {:ok, best} = Discovery.resolve(registry, "parse", ["eu"])
      assert best == "european"
    end

    test "penalizes unhealthy tools" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("healthy", fn _ -> [] end, capability_id: "parse")
        |> Registry.register_base_tool("broken", fn _ -> [] end, capability_id: "parse")
        |> Registry.mark_healthy("healthy")
        |> Registry.mark_unhealthy("broken")
        |> then(fn r ->
          # Make broken have higher base success rate
          tool = Registry.get_tool(r, "broken")
          updated = %{tool | success_rate: 0.99}
          %{r | tools: Map.put(r.tools, "broken", updated)}
        end)

      {:ok, best} = Discovery.resolve(registry, "parse", [])
      # Despite higher base rate, healthy wins due to red penalty
      assert best == "healthy"
    end

    test "returns error for missing capability" do
      registry = Registry.new()
      assert :error = Discovery.resolve(registry, "nonexistent", [])
    end

    test "returns error for capability with no implementations" do
      registry =
        Registry.new()
        |> Registry.register_capability(Capability.new("empty"))

      assert :error = Discovery.resolve(registry, "empty", [])
    end
  end

  describe "get_context_warnings/2" do
    test "returns warnings for low context success rates" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("risky", fn _ -> [] end)
        |> then(fn r ->
          tool = Registry.get_tool(r, "risky")
          updated = %{tool | context_success: %{"unicode" => 0.2}}
          %{r | tools: Map.put(r.tools, "risky", updated)}
        end)

      warnings = Discovery.get_context_warnings(registry, ["unicode"])
      assert [_] = warnings
      assert hd(warnings).tool_id == "risky"
      assert hd(warnings).warning =~ "20%"
    end

    test "no warnings for high success rates" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("safe", fn _ -> [] end)
        |> then(fn r ->
          tool = Registry.get_tool(r, "safe")
          updated = %{tool | context_success: %{"common" => 0.95}}
          %{r | tools: Map.put(r.tools, "safe", updated)}
        end)

      warnings = Discovery.get_context_warnings(registry, ["common"])
      assert warnings == []
    end
  end
end
