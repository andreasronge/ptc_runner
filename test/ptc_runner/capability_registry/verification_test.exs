defmodule PtcRunner.CapabilityRegistry.VerificationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.CapabilityRegistry.{Registry, Skill, TestSuite, ToolEntry, Verification}

  describe "TestSuite" do
    test "new/2 creates empty suite" do
      suite = TestSuite.new("my_tool")
      assert suite.tool_id == "my_tool"
      assert suite.cases == []
    end

    test "add_case/4 adds test case" do
      suite =
        TestSuite.new("my_tool")
        |> TestSuite.add_case(%{"x" => 1}, 2, tags: [:smoke])

      assert length(suite.cases) == 1
      [c] = suite.cases
      assert c.input == %{"x" => 1}
      assert c.expected == 2
      assert :smoke in c.tags
    end

    test "add_regression/3 adds regression test" do
      suite =
        TestSuite.new("my_tool")
        |> TestSuite.add_regression(%{"bad" => "input"}, "crashed on null")

      assert length(suite.cases) == 1
      [c] = suite.cases
      assert c.expected == :should_not_crash
      assert :regression in c.tags
      assert c.added_reason == "crashed on null"
    end

    test "smoke_cases/1 returns only smoke tests" do
      suite =
        TestSuite.new("my_tool")
        |> TestSuite.add_case(%{"x" => 1}, 1, tags: [:smoke])
        |> TestSuite.add_case(%{"x" => 2}, 2, tags: [])
        |> TestSuite.add_case(%{"x" => 3}, 3, tags: [:smoke, :edge_case])

      smoke = TestSuite.smoke_cases(suite)
      assert length(smoke) == 2
    end

    test "merge/2 combines cases from both suites" do
      s1 =
        TestSuite.new("tool")
        |> TestSuite.add_case(%{"a" => 1}, 1)

      s2 =
        TestSuite.new("tool")
        |> TestSuite.add_case(%{"b" => 2}, 2)

      merged = TestSuite.merge(s1, s2)
      assert length(merged.cases) == 2
    end
  end

  describe "run_test_suite/2" do
    test "returns pass when all tests pass" do
      double_fn = fn args -> args["x"] * 2 end

      suite =
        TestSuite.new("double")
        |> TestSuite.add_case(%{"x" => 2}, 4)
        |> TestSuite.add_case(%{"x" => 3}, 6)

      registry =
        Registry.new()
        |> Registry.register_base_tool("double", double_fn)
        |> put_suite("double", suite)

      {:ok, result} = Verification.run_test_suite(registry, "double")
      assert result.status == :pass
      assert result.passed == 2
      assert result.failed == 0
    end

    test "returns fail when a test fails" do
      buggy_fn = fn args -> args["x"] + 1 end

      suite =
        TestSuite.new("buggy")
        |> TestSuite.add_case(%{"x" => 2}, 4)

      registry =
        Registry.new()
        |> Registry.register_base_tool("buggy", buggy_fn)
        |> put_suite("buggy", suite)

      {:ok, result} = Verification.run_test_suite(registry, "buggy")
      assert result.status == :fail
      assert result.failed == 1
    end

    test "handles :should_not_crash expectation" do
      safe_fn = fn args -> args["x"] end

      suite =
        TestSuite.new("safe")
        |> TestSuite.add_case(%{"x" => 1}, :should_not_crash)

      registry =
        Registry.new()
        |> Registry.register_base_tool("safe", safe_fn)
        |> put_suite("safe", suite)

      {:ok, result} = Verification.run_test_suite(registry, "safe")
      assert result.status == :pass
    end

    test "catches crashes when :should_not_crash" do
      crashing_fn = fn _args -> raise "boom" end

      suite =
        TestSuite.new("crashy")
        |> TestSuite.add_case(%{}, :should_not_crash)

      registry =
        Registry.new()
        |> Registry.register_base_tool("crashy", crashing_fn)
        |> put_suite("crashy", suite)

      {:ok, result} = Verification.run_test_suite(registry, "crashy")
      assert result.status == :fail
    end

    test "returns error when tool not found" do
      registry = Registry.new()
      assert {:error, :tool_not_found} = Verification.run_test_suite(registry, "nonexistent")
    end

    test "returns error when suite not found" do
      registry = Registry.new() |> Registry.register_base_tool("tool", fn _ -> nil end)
      assert {:error, :suite_not_found} = Verification.run_test_suite(registry, "tool")
    end
  end

  describe "run_smoke_tests/3" do
    test "only runs smoke-tagged tests" do
      fn_fn = fn args -> args["x"] end

      suite =
        TestSuite.new("tool")
        |> TestSuite.add_case(%{"x" => 1}, 1, tags: [:smoke])
        |> TestSuite.add_case(%{"x" => 2}, 999, tags: [])

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn_fn)
        |> put_suite("tool", suite)

      {:ok, result} = Verification.run_smoke_tests(registry, "tool")
      # Only the smoke test should run (and pass)
      assert result.status == :pass
      assert result.passed == 1
    end

    test "limits smoke tests" do
      fn_fn = fn args -> args["x"] end

      suite =
        TestSuite.new("tool")
        |> TestSuite.add_case(%{"x" => 1}, 1, tags: [:smoke])
        |> TestSuite.add_case(%{"x" => 2}, 2, tags: [:smoke])
        |> TestSuite.add_case(%{"x" => 3}, 3, tags: [:smoke])
        |> TestSuite.add_case(%{"x" => 4}, 4, tags: [:smoke])
        |> TestSuite.add_case(%{"x" => 5}, 5, tags: [:smoke])

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn_fn)
        |> put_suite("tool", suite)

      {:ok, result} = Verification.run_smoke_tests(registry, "tool", limit: 2)
      assert result.passed == 2
    end
  end

  describe "preflight_check/2" do
    test "marks healthy when smoke tests pass" do
      fn_fn = fn args -> args["x"] end

      suite =
        TestSuite.new("tool")
        |> TestSuite.add_case(%{"x" => 1}, 1, tags: [:smoke])

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn_fn)
        |> put_suite("tool", suite)

      {:ok, updated} = Verification.preflight_check(registry, "tool")
      assert Registry.get_health(updated, "tool") == :green
    end

    test "marks unhealthy when smoke tests fail" do
      buggy_fn = fn _ -> :wrong end

      suite =
        TestSuite.new("tool")
        |> TestSuite.add_case(%{"x" => 1}, 1, tags: [:smoke])

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", buggy_fn)
        |> put_suite("tool", suite)

      {:error, {:preflight_failed, _}} = Verification.preflight_check(registry, "tool")
    end
  end

  describe "register_with_verification/3" do
    test "registers tool when tests pass" do
      good_fn = fn args -> args["x"] * 2 end
      tool = ToolEntry.new_base("double", good_fn)

      suite =
        TestSuite.new("double")
        |> TestSuite.add_case(%{"x" => 2}, 4)

      registry = Registry.new()

      {:ok, updated} = Verification.register_with_verification(registry, tool, suite)

      assert Registry.get_tool(updated, "double") != nil
      assert Registry.get_health(updated, "double") == :green
    end

    test "rejects tool when tests fail" do
      bad_fn = fn _ -> :wrong end
      tool = ToolEntry.new_base("bad", bad_fn)

      suite =
        TestSuite.new("bad")
        |> TestSuite.add_case(%{"x" => 2}, 4)

      registry = Registry.new()

      {:error, {:tests_failed, _}} =
        Verification.register_with_verification(registry, tool, suite)

      # Tool should not be registered
      assert Registry.get_tool(registry, "bad") == nil
    end
  end

  describe "register_repair/3" do
    test "registers repair when all historical tests pass" do
      # Original tool
      original_fn = fn args -> args["x"] end

      suite_v1 =
        TestSuite.new("tool_v1")
        |> TestSuite.add_case(%{"x" => 1}, 1)
        |> TestSuite.add_case(%{"x" => 2}, 2)

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool_v1", original_fn)
        |> put_suite("tool_v1", suite_v1)

      # Repair tool that still passes all tests
      repair_fn = fn args -> args["x"] end
      repair_tool = ToolEntry.new_base("tool_v2", repair_fn, supersedes: "tool_v1")

      {:ok, updated} = Verification.register_repair(registry, repair_tool, [])

      assert Registry.get_tool(updated, "tool_v2") != nil
      assert Registry.get_health(updated, "tool_v2") == :green
    end

    test "rejects repair when historical tests regress" do
      # Original tool passes test
      original_fn = fn args -> args["x"] end

      suite_v1 =
        TestSuite.new("tool_v1")
        |> TestSuite.add_case(%{"x" => 1}, 1)

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool_v1", original_fn)
        |> put_suite("tool_v1", suite_v1)

      # Repair tool that breaks the test
      repair_fn = fn _ -> :broken end
      repair_tool = ToolEntry.new_base("tool_v2", repair_fn, supersedes: "tool_v1")

      {:error, {:regressions_detected, _}} =
        Verification.register_repair(registry, repair_tool, [])
    end

    test "flags related skills for review" do
      original_fn = fn args -> args["x"] end

      suite_v1 =
        TestSuite.new("tool_v1")
        |> TestSuite.add_case(%{"x" => 1}, 1)

      skill =
        Skill.new("tip", "Tip", "...", applies_to: ["tool_v1"])

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool_v1", original_fn)
        |> Registry.register_skill(skill)
        |> put_suite("tool_v1", suite_v1)

      repair_fn = fn args -> args["x"] end
      repair_tool = ToolEntry.new_base("tool_v2", repair_fn, supersedes: "tool_v1")

      {:ok, updated} = Verification.register_repair(registry, repair_tool, [])

      flagged_skill = Registry.get_skill(updated, "tip")
      assert flagged_skill.review_status == :flagged_for_review
    end
  end

  describe "add_test_case/5" do
    test "adds case to existing suite" do
      suite = TestSuite.new("tool") |> TestSuite.add_case(%{"a" => 1}, 1)

      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> nil end)
        |> put_suite("tool", suite)

      updated = Verification.add_test_case(registry, "tool", %{"b" => 2}, 2)
      new_suite = Verification.get_suite(updated, "tool")

      assert length(new_suite.cases) == 2
    end

    test "creates suite if doesn't exist" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> nil end)

      updated = Verification.add_test_case(registry, "tool", %{"a" => 1}, 1)
      new_suite = Verification.get_suite(updated, "tool")

      assert new_suite != nil
      assert length(new_suite.cases) == 1
    end
  end

  describe "record_failure_as_test/4" do
    test "adds regression test from failure" do
      registry =
        Registry.new()
        |> Registry.register_base_tool("tool", fn _ -> nil end)

      updated =
        Verification.record_failure_as_test(registry, "tool", %{"bad" => "data"}, "null pointer")

      suite = Verification.get_suite(updated, "tool")
      [test_case] = suite.cases

      assert test_case.expected == :should_not_crash
      assert :regression in test_case.tags
      assert test_case.added_reason == "null pointer"
    end
  end

  # Helper to add suite to registry
  defp put_suite(registry, tool_id, suite) do
    %{registry | test_suites: Map.put(registry.test_suites, tool_id, suite)}
  end
end
