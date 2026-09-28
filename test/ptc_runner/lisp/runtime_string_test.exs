defmodule PtcRunner.Lisp.RuntimeStringTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime

  test "string key parameters use the same lookup across collection functions" do
    for items <- [
          [%{"value" => 30}, %{"value" => 10}, %{"value" => 20}],
          [%{value: 30}, %{value: 10}, %{value: 20}]
        ] do
      sorted = Runtime.sort_by("value", items)
      assert Enum.map(sorted, &(&1["value"] || &1[:value])) == [10, 20, 30]

      assert Enum.map(Runtime.sort_by("value", &>=/2, items), &(&1["value"] || &1[:value])) == [
               30,
               20,
               10
             ]

      assert Runtime.sum_by("value", items) == 60
      assert Runtime.avg_by("value", items) == 20.0
      assert Runtime.min_by("value", items) == Enum.at(items, 1)
      assert Runtime.max_by("value", items) == hd(items)
      assert map_size(Runtime.group_by("value", items)) == 3
      assert Runtime.get(hd(items), "value") == 30
      assert Runtime.contains?(hd(items), "value")
      refute Runtime.contains?(hd(items), "missing")
    end

    assert Runtime.get(%{"value" => nil}, "value", "fallback") == nil
    assert Runtime.get(%{value: nil}, "value", "fallback") == nil
    assert Runtime.get(%{"value" => 30}, "missing", 0) == 0
  end

  # These edge cases do not have matching source-level assertions in
  # Lisp.IntegrationTest's index-of and last-index-of groups.
  describe "index boundary cases" do
    test "index_of skips an earlier match" do
      assert Runtime.index_of("abcabc", "bc", 2) == 4
    end

    test "index_of clamps an empty substring and negative from-index" do
      assert Runtime.index_of("hello", "", 3) == 3
      assert Runtime.index_of("hello", "", 10) == 5
      assert Runtime.index_of("hello", "he", -5) == 0
    end

    test "last_index_of handles Unicode overlap" do
      assert Runtime.last_index_of("ééé", "éé") == 1
    end

    test "last_index_of handles absent earlier matches and index bounds" do
      assert Runtime.last_index_of("hello", "l", 1) == nil
      assert Runtime.last_index_of("hello", "", 3) == 3
      assert Runtime.last_index_of("hello", "", 10) == 5
      assert Runtime.last_index_of("abcabc", "a", -1) == 0
    end
  end
end
