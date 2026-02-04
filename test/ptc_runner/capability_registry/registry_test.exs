defmodule PtcRunner.CapabilityRegistry.RegistryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.CapabilityRegistry.{Registry, Skill}

  describe "new/0" do
    test "creates empty registry" do
      registry = Registry.new()

      assert registry.tools == %{}
      assert registry.skills == %{}
      assert registry.capabilities == %{}
    end
  end

  describe "register_base_tool/4" do
    test "registers a base tool" do
      registry =
        Registry.new()
        |> Registry.register_base_tool(
          "search",
          fn _args -> [] end,
          signature: "(query :string) -> [{}]",
          tags: ["search"]
        )

      tool = Registry.get_tool(registry, "search")
      assert tool.id == "search"
      assert tool.layer == :base
      assert tool.tags == ["search"]
      assert is_function(tool.function)
    end

    test "sets initial health to pending" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)

      assert Registry.get_health(registry, "search") == :pending
    end

    test "associates with capability when specified" do
      registry =
        Registry.new()
        |> Registry.register_base_tool(
          "parse_csv_v1",
          fn _ -> [] end,
          capability_id: "parse_csv"
        )
        |> Registry.register_base_tool(
          "parse_csv_v2",
          fn _ -> [] end,
          capability_id: "parse_csv"
        )

      cap = Registry.get_capability(registry, "parse_csv")
      assert cap.implementations == ["parse_csv_v1", "parse_csv_v2"]
      assert cap.default_impl == "parse_csv_v1"
    end
  end

  describe "register_composed_tool/4" do
    test "registers a composed tool with code" do
      code = "(defn extract [path] (tool/read {:path path}))"

      registry =
        Registry.new()
        |> Registry.register_composed_tool(
          "extract",
          code,
          dependencies: ["read"],
          tags: ["file", "extraction"]
        )

      tool = Registry.get_tool(registry, "extract")
      assert tool.id == "extract"
      assert tool.layer == :composed
      assert tool.code == code
      assert tool.dependencies == ["read"]
    end
  end

  describe "register_skill/2" do
    test "registers a skill" do
      skill = Skill.new("csv_tips", "CSV Tips", "When parsing CSV...", applies_to: ["parse_csv"])

      registry =
        Registry.new()
        |> Registry.register_skill(skill)

      assert Registry.get_skill(registry, "csv_tips") == skill
    end
  end

  describe "unregister_tool/2" do
    test "removes a tool" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.unregister_tool("search")

      assert Registry.get_tool(registry, "search") == nil
      assert Registry.get_health(registry, "search") == nil
    end

    test "removes from capability implementations" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("v1", fn _ -> [] end, capability_id: "cap")
        |> Registry.register_base_tool("v2", fn _ -> [] end, capability_id: "cap")
        |> Registry.unregister_tool("v1")

      cap = Registry.get_capability(registry, "cap")
      assert cap.implementations == ["v2"]
      assert cap.default_impl == "v2"
    end
  end

  describe "health management" do
    test "mark_healthy/2 sets green status" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.mark_healthy("search")

      assert Registry.get_health(registry, "search") == :green
    end

    test "mark_unhealthy/2 sets red status" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.mark_unhealthy("search")

      assert Registry.get_health(registry, "search") == :red
    end

    test "mark_flaky/2 sets flaky status" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.mark_flaky("search")

      assert Registry.get_health(registry, "search") == :flaky
    end

    test "list_healthy_tools/1 returns only green tools" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("good1", fn _ -> [] end)
        |> Registry.register_base_tool("good2", fn _ -> [] end)
        |> Registry.register_base_tool("bad", fn _ -> [] end)
        |> Registry.mark_healthy("good1")
        |> Registry.mark_healthy("good2")
        |> Registry.mark_unhealthy("bad")

      healthy = Registry.list_healthy_tools(registry)
      ids = Enum.map(healthy, & &1.id) |> Enum.sort()
      assert ids == ["good1", "good2"]
    end
  end

  describe "trial history" do
    test "record_trial/4 updates tool success rate" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)

      # Record some failures to bring down the rate
      registry =
        Enum.reduce(1..10, registry, fn _, acc ->
          Registry.record_trial(acc, "search", ["web"], false)
        end)

      tool = Registry.get_tool(registry, "search")
      # Rate should be lower after failures (exponential moving average)
      assert tool.success_rate < 1.0
    end

    test "record_trial/4 updates context success" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.record_trial("search", ["web"], true)
        |> Registry.record_trial("search", ["web"], true)

      tool = Registry.get_tool(registry, "search")
      assert Map.has_key?(tool.context_success, "web")
    end

    test "record_skill_trial/5 updates skill statistics" do
      skill = Skill.new("tips", "Tips", "Some tips...")

      registry =
        Registry.new()
        |> Registry.register_skill(skill)
        |> Registry.record_skill_trial("tips", ["context"], "claude-3", true)

      updated = Registry.get_skill(registry, "tips")
      assert Map.has_key?(updated.model_success, "claude-3")
    end
  end

  describe "link recording" do
    test "record_tool_link/2 updates link count" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.record_tool_link("search")
        |> Registry.record_tool_link("search")

      tool = Registry.get_tool(registry, "search")
      assert tool.link_count == 2
      assert tool.last_linked_at != nil
    end

    test "record_skill_link/2 updates skill link count" do
      skill = Skill.new("tips", "Tips", "Some tips...")

      registry =
        Registry.new()
        |> Registry.register_skill(skill)
        |> Registry.record_skill_link("tips")

      updated = Registry.get_skill(registry, "tips")
      assert updated.link_count == 1
    end
  end

  describe "skill review management" do
    test "flag_skill_for_review/3 sets review status" do
      skill = Skill.new("tips", "Tips", "Some tips...")

      registry =
        Registry.new()
        |> Registry.register_skill(skill)
        |> Registry.flag_skill_for_review("tips", "tool repaired")

      updated = Registry.get_skill(registry, "tips")
      assert updated.review_status == :flagged_for_review
    end

    test "flag_skills_for_tool/3 flags all related skills" do
      skill1 = Skill.new("skill1", "Skill 1", "...", applies_to: ["tool1"])
      skill2 = Skill.new("skill2", "Skill 2", "...", applies_to: ["tool1", "tool2"])
      skill3 = Skill.new("skill3", "Skill 3", "...", applies_to: ["tool2"])

      registry =
        Registry.new()
        |> Registry.register_skill(skill1)
        |> Registry.register_skill(skill2)
        |> Registry.register_skill(skill3)
        |> Registry.flag_skills_for_tool("tool1", "repair")

      assert Registry.get_skill(registry, "skill1").review_status == :flagged_for_review
      assert Registry.get_skill(registry, "skill2").review_status == :flagged_for_review
      assert Registry.get_skill(registry, "skill3").review_status == nil
    end

    test "list_skills_for_review/1 returns flagged skills" do
      skill1 = Skill.new("flagged", "Flagged", "...")
      skill2 = Skill.new("normal", "Normal", "...")

      registry =
        Registry.new()
        |> Registry.register_skill(skill1)
        |> Registry.register_skill(skill2)
        |> Registry.flag_skill_for_review("flagged", "test")

      flagged = Registry.list_skills_for_review(registry)
      assert length(flagged) == 1
      assert hd(flagged).id == "flagged"
    end
  end

  describe "archival" do
    test "archive_tool/3 moves tool to archived" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("old", fn _ -> [] end)
        |> Registry.archive_tool("old", "not used")

      assert Registry.get_tool(registry, "old") == nil
      assert length(Registry.list_archived(registry)) == 1

      [archived] = Registry.list_archived(registry)
      assert archived.type == :tool
      assert archived.entry.id == "old"
      assert archived.reason == "not used"
    end

    test "archive_skill/3 moves skill to archived" do
      skill = Skill.new("old", "Old Skill", "...")

      registry =
        Registry.new()
        |> Registry.register_skill(skill)
        |> Registry.archive_skill("old", "redundant")

      assert Registry.get_skill(registry, "old") == nil
      assert length(Registry.list_archived(registry)) == 1
    end

    test "restore/2 brings back archived tool" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("temp", fn _ -> :restored end)
        |> Registry.archive_tool("temp")
        |> Registry.restore("temp")

      assert Registry.get_tool(registry, "temp") != nil
      assert Registry.list_archived(registry) == []
    end

    test "restore/2 brings back archived skill" do
      skill = Skill.new("temp", "Temp", "...")

      registry =
        Registry.new()
        |> Registry.register_skill(skill)
        |> Registry.archive_skill("temp")
        |> Registry.restore("temp")

      assert Registry.get_skill(registry, "temp") != nil
    end
  end

  describe "counts/1" do
    test "returns statistics" do
      skill = Skill.new("s1", "Skill", "...")

      registry =
        Registry.new()
        |> Registry.register_base_tool("t1", fn _ -> [] end)
        |> Registry.register_base_tool("t2", fn _ -> [] end)
        |> Registry.register_skill(skill)
        |> Registry.archive_tool("t2")

      counts = Registry.counts(registry)
      assert counts.tools == 1
      assert counts.skills == 1
      assert counts.archived == 1
    end
  end
end
