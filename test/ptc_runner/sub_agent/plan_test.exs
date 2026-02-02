defmodule PtcRunner.SubAgent.PlanTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  describe "plan normalization" do
    test "string list gets numeric IDs" do
      agent = SubAgent.new(prompt: "test", plan: ["Gather data", "Analyze"])

      assert agent.plan == [{"1", "Gather data"}, {"2", "Analyze"}]
    end

    test "explicit tuple IDs are preserved" do
      agent =
        SubAgent.new(prompt: "test", plan: [{"gather", "Gather data"}, {"analyze", "Analyze"}])

      assert agent.plan == [{"gather", "Gather data"}, {"analyze", "Analyze"}]
    end

    test "atom IDs are converted to strings" do
      agent = SubAgent.new(prompt: "test", plan: [{:gather, "Gather data"}])

      assert agent.plan == [{"gather", "Gather data"}]
    end

    test "empty plan is default" do
      agent = SubAgent.new(prompt: "test")
      assert agent.plan == []
    end
  end

  describe "plan validation" do
    test "raises on invalid plan items" do
      assert_raise ArgumentError, ~r/invalid plan item/, fn ->
        SubAgent.new(prompt: "test", plan: [123])
      end
    end

    test "raises on non-list plan" do
      assert_raise ArgumentError, ~r/plan must be a list/, fn ->
        SubAgent.new(prompt: "test", plan: "not a list")
      end
    end

    test "raises on duplicate IDs" do
      assert_raise ArgumentError, ~r/duplicate plan IDs/, fn ->
        SubAgent.new(prompt: "test", plan: [{"a", "First"}, {"a", "Second"}])
      end
    end

    test "raises on empty description with explicit ID" do
      assert_raise ArgumentError, ~r/description cannot be empty/, fn ->
        SubAgent.new(prompt: "test", plan: [{"a", ""}])
      end
    end

    test "raises on empty description with string item" do
      assert_raise ArgumentError, ~r/description cannot be empty/, fn ->
        SubAgent.new(prompt: "test", plan: [""])
      end
    end
  end
end
