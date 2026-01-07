defmodule PtcRunner.Lisp.Runtime.CollectionMapIndexedTest do
  use ExUnit.Case
  alias PtcRunner.Lisp.Runtime

  describe "map_indexed/2" do
    test "maps over a list with index" do
      result = Runtime.map_indexed(fn i, x -> [i, x] end, ["a", "b", "c"])
      assert result == [[0, "a"], [1, "b"], [2, "c"]]
    end

    test "maps over a string with index" do
      result = Runtime.map_indexed(fn i, x -> [i, x] end, "abc")
      assert result == [[0, "a"], [1, "b"], [2, "c"]]
    end

    test "maps over a MapSet with index" do
      set = MapSet.new(["a", "b"])
      result = Runtime.map_indexed(fn i, x -> [i, x] end, set)
      # Order is arbitrary but index should be correct
      assert length(result) == 2
      assert Enum.any?(result, fn [i, x] -> i == 0 and x in ["a", "b"] end)
      assert Enum.any?(result, fn [i, x] -> i == 1 and x in ["a", "b"] end)
    end

    test "maps over a map with index" do
      map = %{"a" => 1, "b" => 2}
      result = Runtime.map_indexed(fn i, x -> [i, x] end, map)
      assert length(result) == 2
      # For maps, it should pass [key, value] pairs
      assert Enum.any?(result, fn [i, x] -> i == 0 and x in [["a", 1], ["b", 2]] end)
      assert Enum.any?(result, fn [i, x] -> i == 1 and x in [["a", 1], ["b", 2]] end)
    end

    test "works with empty list" do
      assert Runtime.map_indexed(fn i, x -> [i, x] end, []) == []
    end

    test "works with empty string" do
      assert Runtime.map_indexed(fn i, x -> [i, x] end, "") == []
    end

    test "works with empty MapSet" do
      assert Runtime.map_indexed(fn i, x -> [i, x] end, MapSet.new()) == []
    end

    test "works with empty map" do
      assert Runtime.map_indexed(fn i, x -> [i, x] end, %{}) == []
    end
  end
end
