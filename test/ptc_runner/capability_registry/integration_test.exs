defmodule PtcRunner.CapabilityRegistry.IntegrationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Integration tests for Capability Registry.

  Tests the registry modules working together without LLM dependencies.
  """

  alias PtcRunner.CapabilityRegistry.{
    Discovery,
    GarbageCollection,
    Linker,
    Persistence,
    Promotion,
    Registry,
    Skill,
    TestSuite,
    ToolEntry,
    TrialHistory,
    Verification
  }

  describe "Registry + Linker + Verification flow" do
    test "registers tool, verifies it, and links for mission" do
      # Create a base tool with test suite
      double_fn = fn %{"x" => x} -> x * 2 end

      suite =
        TestSuite.new("double")
        |> TestSuite.add_case(%{"x" => 5}, 10, tags: [:smoke])
        |> TestSuite.add_case(%{"x" => 0}, 0, tags: [:edge_case])

      tool =
        ToolEntry.new_base("double", double_fn,
          signature: "(x :int) -> :int",
          tags: ["math", "arithmetic"]
        )

      # Register with verification
      registry = Registry.new()
      {:ok, registry} = Verification.register_with_verification(registry, tool, suite)

      # Tool should be healthy
      assert Registry.get_health(registry, "double") == :green

      # Link for mission
      {:ok, link_result} = Linker.link(registry, ["double"])

      assert length(link_result.tools) == 1
      assert link_result.base_tools["double"] != nil

      # Execute via linked function
      result = link_result.base_tools["double"].(%{"x" => 7})
      assert result == 14
    end

    test "failing tests prevent registration" do
      # Tool that always returns wrong value
      bad_fn = fn _args -> 999 end

      suite =
        TestSuite.new("bad_tool")
        |> TestSuite.add_case(%{"x" => 5}, 10, tags: [:smoke])

      tool =
        ToolEntry.new_base("bad_tool", bad_fn, signature: "(x :int) -> :int")

      registry = Registry.new()

      {:error, {:tests_failed, _}} =
        Verification.register_with_verification(registry, tool, suite)

      # Tool should not be registered
      assert Registry.get_tool(registry, "bad_tool") == nil
    end

    test "repair tool inherits tests from original" do
      # Original tool
      original_fn = fn %{"x" => x} -> x * 2 end

      original_suite =
        TestSuite.new("calc_v1")
        |> TestSuite.add_case(%{"x" => 5}, 10, tags: [:regression])
        |> TestSuite.add_case(%{"x" => 3}, 6, tags: [:regression])

      registry =
        Registry.new()
        |> Registry.register_base_tool("calc_v1", original_fn)
        |> then(&%{&1 | test_suites: Map.put(&1.test_suites, "calc_v1", original_suite)})
        |> Registry.mark_unhealthy("calc_v1")

      # Repair tool must pass all inherited tests
      repair_fn = fn %{"x" => x} -> x * 2 end

      repair_tool =
        ToolEntry.new_base("calc_v2", repair_fn, supersedes: "calc_v1")

      {:ok, updated} = Verification.register_repair(registry, repair_tool, [])

      # Both tools registered, repair is healthy
      assert Registry.get_tool(updated, "calc_v1") != nil
      assert Registry.get_tool(updated, "calc_v2") != nil
      assert Registry.get_health(updated, "calc_v2") == :green
    end
  end

  describe "Discovery + Linker + Skills flow" do
    test "skills linked via applies_to are injected" do
      search_fn = fn %{"query" => q} -> [%{title: "Result for #{q}"}] end

      skill =
        Skill.new(
          "search_tips",
          "Search Tips",
          """
          When searching:
          - Use specific keywords
          - Prefer recent results
          """,
          applies_to: ["search"],
          tags: ["search", "tips"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("search", search_fn,
          signature: "(query :string) -> [{title :string}]",
          tags: ["search", "web"]
        )
        |> Registry.register_skill(skill)

      # Link should find skill via applies_to
      {:ok, result} = Linker.link(registry, ["search"])

      assert length(result.skills) == 1
      assert hd(result.skills).id == "search_tips"
      assert result.skill_prompt =~ "Search Tips"
      assert result.skill_prompt =~ "specific keywords"
    end

    test "skills matched by context tags are injected" do
      parse_fn = fn %{"text" => t} -> String.split(t, ";") end

      skill =
        Skill.new(
          "european_csv",
          "European CSV Handling",
          """
          European CSV files use:
          - Semicolon (;) as delimiter
          - Comma for decimals
          """,
          applies_to: [],
          tags: ["csv", "european"]
        )

      registry =
        Registry.new()
        |> Registry.register_base_tool("parse_csv", parse_fn, tags: ["csv", "parsing"])
        |> Registry.register_skill(skill)

      # Link with european context tag
      {:ok, result} = Linker.link(registry, ["parse_csv"], context_tags: ["european"])

      assert length(result.skills) == 1
      assert hd(result.skills).id == "european_csv"
    end

    test "discovery finds tools by tag" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search_web", fn _ -> [] end, tags: ["search", "web"])
        |> Registry.register_base_tool("search_db", fn _ -> [] end, tags: ["search", "database"])
        |> Registry.register_base_tool("json_util", fn _ -> %{} end, tags: ["parsing", "json"])

      # Discovery.search uses multi-strategy (tags + fuzzy)
      # Tools with "search" tag should score highest
      results = Discovery.search(registry, "search", min_score: 0.3)

      # Check that search tools are found
      ids = Enum.map(results, & &1.id)
      assert "search_web" in ids
      assert "search_db" in ids

      # Check ordering - search-tagged tools should score higher
      top_two = Enum.take(results, 2) |> Enum.map(& &1.id)
      assert "search_web" in top_two
      assert "search_db" in top_two
    end
  end

  describe "Trial History + Statistics flow" do
    test "trial outcomes update tool success rates" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("api_call", fn _ -> :ok end, tags: ["api"])

      # Record several trials using Registry.record_trial/4
      registry =
        registry
        |> Registry.record_trial("api_call", ["web"], true)
        |> Registry.record_trial("api_call", ["web"], true)
        |> Registry.record_trial("api_call", ["web"], false)
        |> Registry.record_trial("api_call", ["web"], true)

      tool = Registry.get_tool(registry, "api_call")

      # Success rate should be updated (EMA converges toward actual rate)
      # Started at 1.0, 3/4 successes, should still be high but < 1.0
      assert tool.success_rate > 0.9
      assert tool.success_rate < 1.0

      # Context success should also be tracked
      assert tool.context_success["web"] != nil
    end

    test "context warnings generated for low success contexts" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("flaky_tool", fn _ -> :ok end, tags: ["api"])

      # Record many failures in "production" context
      registry =
        Enum.reduce(1..20, registry, fn _, r ->
          Registry.record_trial(r, "flaky_tool", ["production"], false)
        end)

      # Use TrialHistory.get_context_warnings which returns different shape
      warnings = TrialHistory.get_context_warnings(registry, ["production"])

      assert length(warnings) == 1
      assert hd(warnings).tool_id == "flaky_tool"
      assert hd(warnings).rate < 0.3
    end
  end

  describe "Promotion flow" do
    test "tracks patterns across missions" do
      plan = %{
        agents: %{"worker" => %{tools: ["search", "summarize"]}},
        tasks: [
          %{id: "t1", agent: "worker", type: :task}
        ]
      }

      registry =
        Registry.new()
        |> Promotion.track_pattern(plan, :success, mission: "mission_1")
        |> Promotion.track_pattern(plan, :success, mission: "mission_2")
        |> Promotion.track_pattern(plan, :success, mission: "mission_3")

      candidates = Promotion.list_candidates(registry)

      assert length(candidates) == 1
      candidate = hd(candidates)
      assert length(candidate.occurrences) == 3
      # Status is :candidate (or :flagged after threshold)
      assert candidate.status in [:candidate, :flagged]
    end

    test "promotes pattern as composed tool" do
      plan = %{
        agents: %{"worker" => %{tools: ["fetch", "parse"]}},
        tasks: [%{id: "t1", agent: "worker", type: :task}]
      }

      # Register base tools first
      registry =
        Registry.new()
        |> Registry.register_base_tool("fetch", fn _ -> "data" end)
        |> Registry.register_base_tool("parse", fn _ -> %{} end)
        |> Promotion.track_pattern(plan, :success, mission: "m1")
        |> Promotion.track_pattern(plan, :success, mission: "m2")
        |> Promotion.track_pattern(plan, :success, mission: "m3")

      candidates = Promotion.list_candidates(registry)
      hash = hd(candidates).pattern_hash

      {:ok, updated} =
        Promotion.promote_as_tool(registry, hash, "fetch_and_parse",
          code: "(defn fetch-and-parse [url] (-> (tool/fetch {:url url}) (tool/parse {})))",
          signature: "(url :string) -> :map",
          tags: ["fetch", "parse", "composed"]
        )

      tool = Registry.get_tool(updated, "fetch_and_parse")
      assert tool != nil
      assert tool.layer == :composed
      assert tool.source == :smithed

      # Candidate should be promoted
      promoted_candidate = Promotion.get_candidate(updated, hash)
      assert promoted_candidate.status == :promoted
    end
  end

  describe "Garbage Collection flow" do
    test "identifies stale tools for archival" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("fresh_tool", fn _ -> :ok end)
        |> Registry.register_base_tool("stale_tool", fn _ -> :ok end)

      # Simulate fresh tool being linked recently
      registry = Registry.record_tool_link(registry, "fresh_tool")

      # With link_age_days: 0, even "fresh_tool" could be stale
      # But we just linked it, so it should have last_linked_at set
      # stale_tool has never been linked (nil last_linked_at)
      candidates = GarbageCollection.archive_tool_candidates(registry, link_age_days: 0)

      # Filter to find only the one that was never linked
      never_linked = Enum.filter(candidates, &(&1.reason =~ "Never linked"))
      assert length(never_linked) == 1
      assert hd(never_linked).id == "stale_tool"
    end

    test "archives and preserves tools correctly" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("to_archive", fn _ -> :ok end, tags: ["old"])

      # Archive the tool
      updated = Registry.archive_tool(registry, "to_archive", "no longer needed")

      # Tool should be removed from active registry
      assert Registry.get_tool(updated, "to_archive") == nil

      # But preserved in archive
      archived = Registry.list_archived(updated)
      assert length(archived) == 1
      assert hd(archived).type == :tool
      assert hd(archived).reason == "no longer needed"
    end

    test "protects sole implementation of capability" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("only_impl", fn _ -> :ok end, capability_id: "do_thing")

      # Even if stale, should not be archived (sole implementation)
      candidates = GarbageCollection.archive_tool_candidates(registry, link_age_days: 0)

      # No candidates because it's the only implementation
      assert Enum.empty?(candidates)
    end
  end

  describe "Persistence round-trip with complex state" do
    test "full registry state survives serialization" do
      double_fn = fn %{"x" => x} -> x * 2 end

      skill =
        Skill.new("math_tips", "Math Tips", "Always validate inputs",
          applies_to: ["double"],
          tags: ["math"]
        )

      suite =
        TestSuite.new("double")
        |> TestSuite.add_case(%{"x" => 5}, 10, tags: [:smoke])

      plan = %{
        agents: %{"calc" => %{tools: ["double"]}},
        tasks: [%{id: "t1", agent: "calc", type: :task}]
      }

      registry =
        Registry.new()
        |> Registry.register_base_tool("double", double_fn,
          signature: "(x :int) -> :int",
          capability_id: "multiply"
        )
        |> Registry.mark_healthy("double")
        |> Registry.register_skill(skill)
        |> then(&%{&1 | test_suites: Map.put(&1.test_suites, "double", suite)})
        |> Registry.record_trial("double", ["math"], true)
        |> Promotion.track_pattern(plan, :success, mission: "m1")

      # Serialize and deserialize
      json = Persistence.to_json(registry)

      {:ok, loaded} =
        Persistence.from_json(json, fn
          "double" -> double_fn
          _ -> nil
        end)

      # Verify all state preserved
      assert Registry.get_tool(loaded, "double") != nil
      assert Registry.get_health(loaded, "double") == :green
      assert Registry.get_skill(loaded, "math_tips") != nil
      assert Registry.get_capability(loaded, "multiply") != nil
      assert Verification.get_suite(loaded, "double") != nil
      assert length(loaded.history) == 1
      assert length(Promotion.list_candidates(loaded)) == 1

      # Verify tool function works
      tool = Registry.get_tool(loaded, "double")
      assert tool.function.(%{"x" => 7}) == 14
    end
  end

  describe "Transitive dependency resolution" do
    test "resolves deep dependency chains" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("base_fetch", fn _ -> "data" end)
        |> Registry.register_composed_tool(
          "level1",
          "(defn level1 [x] (tool/base_fetch {:url x}))",
          dependencies: ["base_fetch"]
        )
        |> Registry.register_composed_tool(
          "level2",
          "(defn level2 [x] (-> (level1 x) (process)))",
          dependencies: ["level1"]
        )
        |> Registry.register_composed_tool(
          "level3",
          "(defn level3 [x] (level2 x))",
          dependencies: ["level2"]
        )

      {:ok, result} = Linker.link(registry, ["level3"])

      # Should have all 4 tools in correct order
      assert length(result.tools) == 4
      ids = Enum.map(result.tools, & &1.id)

      # base_fetch should come before level1, level1 before level2, etc.
      assert Enum.find_index(ids, &(&1 == "base_fetch")) <
               Enum.find_index(ids, &(&1 == "level1"))

      assert Enum.find_index(ids, &(&1 == "level1")) < Enum.find_index(ids, &(&1 == "level2"))
      assert Enum.find_index(ids, &(&1 == "level2")) < Enum.find_index(ids, &(&1 == "level3"))
    end

    test "detects dependency cycles" do
      registry =
        Registry.new()
        |> Registry.register_composed_tool("a", "(defn a [x] (b x))", dependencies: ["b"])
        |> Registry.register_composed_tool("b", "(defn b [x] (c x))", dependencies: ["c"])
        |> Registry.register_composed_tool("c", "(defn c [x] (a x))", dependencies: ["a"])

      {:error, {:dependency_cycle, _}} = Linker.link(registry, ["a"])
    end
  end
end
