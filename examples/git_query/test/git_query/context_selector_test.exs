defmodule GitQuery.ContextSelectorTest do
  use ExUnit.Case, async: true

  alias GitQuery.ContextSelector

  describe "select/3 with :all mode" do
    test "returns all results unchanged" do
      results = %{1 => %{contributor: "alice"}, 2 => %{commits: [1, 2, 3]}}

      assert ContextSelector.select(results, [], :all) == results
    end
  end

  describe "select/3 with :declared mode" do
    test "returns only declared dependencies by step_id and key" do
      results = %{
        1 => %{contributor: "alice", count: 15},
        2 => %{commits: [1, 2, 3], summary: "found 3"}
      }

      context = ContextSelector.select(results, [{1, :contributor}], :declared)

      assert context == %{contributor: "alice"}
    end

    test "returns empty map when no needs declared" do
      results = %{1 => %{contributor: "alice"}}

      context = ContextSelector.select(results, [], :declared)

      assert context == %{}
    end

    test "handles missing keys gracefully" do
      results = %{1 => %{contributor: "alice"}}

      context = ContextSelector.select(results, [{1, :nonexistent}], :declared)

      assert context == %{}
    end

    test "supports simple key lookup as fallback" do
      results = %{1 => %{contributor: "alice"}}

      context = ContextSelector.select(results, [:contributor], :declared)

      assert context == %{contributor: "alice"}
    end
  end

  describe "select/3 with :summary mode" do
    test "summarizes large lists" do
      results = %{
        1 => %{commits: Enum.to_list(1..15)}
      }

      context = ContextSelector.select(results, [{1, :commits}], :summary)

      assert context[:commits].type == :list
      assert context[:commits].count == 15
      assert length(context[:commits].sample) == 3
    end

    test "passes through small data unchanged" do
      results = %{
        1 => %{commits: [1, 2, 3]}
      }

      context = ContextSelector.select(results, [{1, :commits}], :summary)

      assert context[:commits] == [1, 2, 3]
    end
  end

  describe "maybe_summarize/1" do
    test "summarizes large lists" do
      data = Enum.to_list(1..15)
      result = ContextSelector.maybe_summarize(data)

      assert result.type == :list
      assert result.count == 15
      assert result.sample == [1, 2, 3]
    end

    test "summarizes lists of maps with keys" do
      data = Enum.map(1..15, fn i -> %{id: i, name: "item #{i}"} end)
      result = ContextSelector.maybe_summarize(data)

      assert result.type == :list
      assert result.keys == [:id, :name]
    end

    test "summarizes long strings" do
      data = String.duplicate("x", 3000)
      result = ContextSelector.maybe_summarize(data)

      assert result.type == :string
      assert result.length == 3000
      assert String.ends_with?(result.preview, "...")
    end

    test "summarizes large maps" do
      data = Map.new(1..25, fn i -> {:"key_#{i}", i} end)
      result = ContextSelector.maybe_summarize(data)

      assert result.type == :map
      assert result.size == 25
      assert is_list(result.keys)
    end

    test "passes through small data unchanged" do
      assert ContextSelector.maybe_summarize([1, 2, 3]) == [1, 2, 3]
      assert ContextSelector.maybe_summarize("hello") == "hello"
      assert ContextSelector.maybe_summarize(%{a: 1}) == %{a: 1}
      assert ContextSelector.maybe_summarize(42) == 42
    end
  end
end
