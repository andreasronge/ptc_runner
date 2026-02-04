defmodule PtcRunner.CapabilityRegistry.LinkerTest do
  use ExUnit.Case, async: true

  alias PtcRunner.CapabilityRegistry.{Linker, Registry, Skill, ToolEntry}

  describe "extract_dependencies/1" do
    test "extracts tool calls from code" do
      code = "(-> (tool/read {:path p}) (tool/parse {}) (tool/format {}))"
      deps = Linker.extract_dependencies(code)
      assert Enum.sort(deps) == ["format", "parse", "read"]
    end

    test "handles empty code" do
      assert Linker.extract_dependencies("") == []
      assert Linker.extract_dependencies(nil) == []
    end

    test "deduplicates repeated tools" do
      code = "(do (tool/read {}) (tool/read {}))"
      deps = Linker.extract_dependencies(code)
      assert deps == ["read"]
    end
  end

  describe "resolve_dependencies/2" do
    test "resolves single tool with no dependencies" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)

      {:ok, tools} = Linker.resolve_dependencies(registry, ["search"])
      assert length(tools) == 1
      assert hd(tools).id == "search"
    end

    test "resolves transitive dependencies" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("file_read", fn _ -> [] end)
        |> Registry.register_composed_tool(
          "parse_csv",
          "(defn parse-csv [text] (tool/file_read {}))",
          dependencies: ["file_read"]
        )
        |> Registry.register_composed_tool(
          "analyze_data",
          "(defn analyze [path] (parse-csv path))",
          dependencies: ["parse_csv"]
        )

      {:ok, tools} = Linker.resolve_dependencies(registry, ["analyze_data"])

      ids = Enum.map(tools, & &1.id)
      # Dependencies should come before dependents
      file_read_idx = Enum.find_index(ids, &(&1 == "file_read"))
      parse_csv_idx = Enum.find_index(ids, &(&1 == "parse_csv"))
      analyze_idx = Enum.find_index(ids, &(&1 == "analyze_data"))

      assert file_read_idx < parse_csv_idx
      assert parse_csv_idx < analyze_idx
    end

    test "extracts dependencies from code when not explicit" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("read", fn _ -> [] end)
        |> Registry.register_composed_tool(
          "process",
          "(defn process [x] (tool/read {:input x}))"
          # No explicit dependencies
        )

      {:ok, tools} = Linker.resolve_dependencies(registry, ["process"])
      ids = Enum.map(tools, & &1.id)
      assert "read" in ids
      assert "process" in ids
    end

    test "detects cycles" do
      registry =
        Registry.new()
        |> Registry.register_composed_tool("a", "(defn a [] (b))", dependencies: ["b"])
        |> Registry.register_composed_tool("b", "(defn b [] (a))", dependencies: ["a"])

      {:error, {:dependency_cycle, _}} = Linker.resolve_dependencies(registry, ["a"])
    end

    test "returns error for missing tool" do
      registry = Registry.new()
      {:error, {:tool_not_found, "missing"}} = Linker.resolve_dependencies(registry, ["missing"])
    end
  end

  describe "generate_prelude/1" do
    test "generates code for composed tools only" do
      base = ToolEntry.new_base("base", fn _ -> nil end)

      composed =
        ToolEntry.new_composed(
          "composed",
          "(defn composed [x] (+ x 1))"
        )

      prelude = Linker.generate_prelude([base, composed])
      assert prelude =~ "(defn composed [x]"
      refute prelude =~ "base"
    end

    test "joins multiple composed tools" do
      t1 = ToolEntry.new_composed("t1", "(defn t1 [] 1)")
      t2 = ToolEntry.new_composed("t2", "(defn t2 [] 2)")

      prelude = Linker.generate_prelude([t1, t2])
      assert prelude =~ "(defn t1"
      assert prelude =~ "(defn t2"
    end

    test "returns empty for no composed tools" do
      base = ToolEntry.new_base("base", fn _ -> nil end)
      assert Linker.generate_prelude([base]) == ""
    end
  end

  describe "generate_skill_prompt/1" do
    test "formats skills with headers" do
      skill = Skill.new("tips", "CSV Tips", "Use semicolons for European files")

      prompt = Linker.generate_skill_prompt([skill])
      assert prompt =~ "## Expertise"
      assert prompt =~ "### CSV Tips"
      assert prompt =~ "Use semicolons"
    end

    test "combines multiple skills" do
      s1 = Skill.new("s1", "Skill One", "Content one")
      s2 = Skill.new("s2", "Skill Two", "Content two")

      prompt = Linker.generate_skill_prompt([s1, s2])
      assert prompt =~ "### Skill One"
      assert prompt =~ "### Skill Two"
    end

    test "returns empty for no skills" do
      assert Linker.generate_skill_prompt([]) == ""
    end
  end

  describe "extract_base_tools/1" do
    test "extracts functions from base tools" do
      fn1 = fn _ -> :one end
      fn2 = fn _ -> :two end

      base1 = ToolEntry.new_base("t1", fn1)
      base2 = ToolEntry.new_base("t2", fn2)
      composed = ToolEntry.new_composed("t3", "(defn t3 [] 3)")

      result = Linker.extract_base_tools([base1, base2, composed])

      assert map_size(result) == 2
      assert is_function(result["t1"])
      assert is_function(result["t2"])
      refute Map.has_key?(result, "t3")
    end
  end

  describe "link/3" do
    test "links tools with dependencies" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("read", fn _ -> :read end)
        |> Registry.register_composed_tool(
          "process",
          "(defn process [x] (tool/read x))",
          dependencies: ["read"]
        )

      {:ok, result} = Linker.link(registry, ["process"])

      assert length(result.tools) == 2
      assert map_size(result.base_tools) == 1
      assert result.lisp_prelude =~ "defn process"
    end

    test "links skills by tool association" do
      skill = Skill.new("tips", "Tips", "Some tips", applies_to: ["search"])

      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.register_skill(skill)

      {:ok, result} = Linker.link(registry, ["search"])

      assert length(result.skills) == 1
      assert hd(result.skills).id == "tips"
      assert result.skill_prompt =~ "Tips"
    end

    test "links skills by context tags" do
      skill = Skill.new("euro", "European", "Handle EU formats", tags: ["european"])

      registry =
        Registry.new()
        |> Registry.register_base_tool("parse", fn _ -> [] end)
        |> Registry.register_skill(skill)

      {:ok, result} = Linker.link(registry, ["parse"], context_tags: ["european"])

      assert length(result.skills) == 1
      assert hd(result.skills).id == "euro"
    end

    test "excludes skills when include_skills is false" do
      skill = Skill.new("tips", "Tips", "...", applies_to: ["search"])

      registry =
        Registry.new()
        |> Registry.register_base_tool("search", fn _ -> [] end)
        |> Registry.register_skill(skill)

      {:ok, result} = Linker.link(registry, ["search"], include_skills: false)

      assert result.skills == []
      assert result.skill_prompt == ""
    end

    test "filters skills by model effectiveness" do
      good_skill =
        Skill.new("good", "Good", "...", applies_to: ["tool"])
        |> then(&%{&1 | model_success: %{"claude-3" => 0.9}})

      bad_skill =
        Skill.new("bad", "Bad", "...", applies_to: ["tool"])
        |> then(&%{&1 | model_success: %{"claude-3" => 0.3}})

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> [] end)
        |> Registry.register_skill(good_skill)
        |> Registry.register_skill(bad_skill)

      {:ok, result} = Linker.link(registry, ["tool"], model_id: "claude-3")

      # Only effective skill should be included
      ids = Enum.map(result.skills, & &1.id)
      assert "good" in ids
      refute "bad" in ids
    end

    test "returns error for missing tool" do
      registry = Registry.new()
      {:error, {:tool_not_found, _}} = Linker.link(registry, ["missing"])
    end
  end
end
