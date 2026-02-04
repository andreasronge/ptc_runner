defmodule PtcRunner.CapabilityRegistry.PersistenceTest do
  use ExUnit.Case, async: true

  alias PtcRunner.CapabilityRegistry.{
    Persistence,
    Promotion,
    Registry,
    Skill,
    TestSuite,
    Verification
  }

  @test_dir System.tmp_dir!()

  describe "to_json/1 and from_json/2" do
    test "round-trips empty registry" do
      registry = Registry.new()

      json = Persistence.to_json(registry)
      {:ok, loaded} = Persistence.from_json(json, fn _ -> nil end)

      assert loaded.tools == %{}
      assert loaded.skills == %{}
      assert loaded.capabilities == %{}
    end

    test "round-trips base tools" do
      double_fn = fn args -> args["x"] * 2 end

      registry =
        Registry.new()
        |> Registry.register_base_tool("double", double_fn,
          signature: "(x :int) -> :int",
          tags: ["math"]
        )
        |> Registry.mark_healthy("double")

      json = Persistence.to_json(registry)

      # Resolver returns the function for "double"
      {:ok, loaded} =
        Persistence.from_json(json, fn
          "double" -> double_fn
          _ -> nil
        end)

      tool = Registry.get_tool(loaded, "double")
      assert tool.id == "double"
      assert tool.signature == "(x :int) -> :int"
      assert tool.tags == ["math"]
      assert is_function(tool.function)
      assert tool.function.(%{"x" => 5}) == 10

      assert Registry.get_health(loaded, "double") == :green
    end

    test "round-trips composed tools" do
      code = "(defn process [x] (+ x 1))"

      registry =
        Registry.new()
        |> Registry.register_composed_tool("process", code,
          signature: "(x :int) -> :int",
          dependencies: ["add"]
        )

      json = Persistence.to_json(registry)
      {:ok, loaded} = Persistence.from_json(json, fn _ -> nil end)

      tool = Registry.get_tool(loaded, "process")
      assert tool.id == "process"
      assert tool.code == code
      assert tool.layer == :composed
    end

    test "round-trips skills" do
      skill =
        Skill.new("tips", "CSV Tips", "Use semicolons...",
          applies_to: ["parse_csv"],
          tags: ["csv"]
        )

      registry =
        Registry.new()
        |> Registry.register_skill(skill)

      json = Persistence.to_json(registry)
      {:ok, loaded} = Persistence.from_json(json, fn _ -> nil end)

      loaded_skill = Registry.get_skill(loaded, "tips")
      assert loaded_skill.id == "tips"
      assert loaded_skill.name == "CSV Tips"
      assert loaded_skill.prompt == "Use semicolons..."
      assert loaded_skill.applies_to == ["parse_csv"]
    end

    test "round-trips test suites" do
      suite =
        TestSuite.new("tool")
        |> TestSuite.add_case(%{"x" => 1}, 2, tags: [:smoke])
        |> TestSuite.add_case(%{"x" => 2}, 4, tags: [:regression])

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> nil end)
        |> then(&%{&1 | test_suites: Map.put(&1.test_suites, "tool", suite)})

      json = Persistence.to_json(registry)
      {:ok, loaded} = Persistence.from_json(json, fn _ -> nil end)

      loaded_suite = Verification.get_suite(loaded, "tool")
      assert loaded_suite != nil
      assert length(loaded_suite.cases) == 2
    end

    test "round-trips promotion candidates" do
      plan = %{
        agents: %{"a" => %{tools: ["t1"]}},
        tasks: [%{id: "t", agent: "a", type: :task}]
      }

      registry =
        Registry.new()
        |> Promotion.track_pattern(plan, :success, mission: "m1")
        |> Promotion.track_pattern(plan, :success, mission: "m2")

      json = Persistence.to_json(registry)
      {:ok, loaded} = Persistence.from_json(json, fn _ -> nil end)

      candidates = Promotion.list_candidates(loaded)
      assert length(candidates) == 1
      assert length(hd(candidates).occurrences) == 2
    end

    test "round-trips archived items" do
      skill = Skill.new("old", "Old Skill", "...")

      registry =
        Registry.new()
        |> Registry.register_skill(skill)
        |> Registry.archive_skill("old", "not used")

      json = Persistence.to_json(registry)
      {:ok, loaded} = Persistence.from_json(json, fn _ -> nil end)

      archived = Registry.list_archived(loaded)
      assert length(archived) == 1
      assert hd(archived).type == :skill
      assert hd(archived).reason == "not used"
    end

    test "round-trips trial history" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> nil end)
        |> Registry.record_trial("tool", ["web"], true)
        |> Registry.record_trial("tool", ["web"], false)

      json = Persistence.to_json(registry)
      {:ok, loaded} = Persistence.from_json(json, fn _ -> nil end)

      assert length(loaded.history) == 2
    end

    test "round-trips capabilities" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("v1", fn _ -> nil end, capability_id: "parse")
        |> Registry.register_base_tool("v2", fn _ -> nil end, capability_id: "parse")

      json = Persistence.to_json(registry)
      {:ok, loaded} = Persistence.from_json(json, fn _ -> nil end)

      cap = Registry.get_capability(loaded, "parse")
      assert cap != nil
      assert length(cap.implementations) == 2
    end
  end

  describe "persist_json/3 and load_json/2" do
    test "writes and reads from file" do
      path = Path.join(@test_dir, "test_registry_#{:rand.uniform(1_000_000)}.json")

      add_fn = fn args -> args["a"] + args["b"] end

      registry =
        Registry.new()
        |> Registry.register_base_tool("add", add_fn, signature: "(a :int, b :int) -> :int")
        |> Registry.register_skill(Skill.new("tip", "Tip", "..."))

      :ok = Persistence.persist_json(registry, path)

      # Verify file exists
      assert File.exists?(path)

      # Load with resolver
      {:ok, loaded} =
        Persistence.load_json(path, fn
          "add" -> add_fn
          _ -> nil
        end)

      assert Registry.get_tool(loaded, "add") != nil
      assert Registry.get_skill(loaded, "tip") != nil

      # Cleanup
      File.rm!(path)
    end

    test "returns error for missing file" do
      {:error, :enoent} = Persistence.load_json("/nonexistent/path.json")
    end

    test "returns error for invalid JSON" do
      path = Path.join(@test_dir, "invalid_#{:rand.uniform(1_000_000)}.json")
      File.write!(path, "{ invalid json }")

      {:error, {:json_decode_failed, _}} = Persistence.load_json(path)

      File.rm!(path)
    end
  end
end
