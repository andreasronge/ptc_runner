defmodule PtcRunner.Lisp.RuntimeStringTest do
  use ExUnit.Case

  alias PtcRunner.Lisp.Runtime

  # ============================================================
  # String Key Parameters (LLM compatibility)
  # ============================================================
  # These tests verify that functions accept string keys as parameters,
  # not just atoms. LLMs sometimes generate "price" instead of :price.

  describe "string key parameters - sort_by" do
    test "sort_by accepts string key parameter with string-keyed data" do
      data = [%{"price" => 30}, %{"price" => 10}, %{"price" => 20}]
      result = Runtime.sort_by("price", data)
      assert Enum.map(result, & &1["price"]) == [10, 20, 30]
    end

    test "sort_by accepts string key parameter with atom-keyed data" do
      data = [%{price: 30}, %{price: 10}, %{price: 20}]
      result = Runtime.sort_by("price", data)
      assert Enum.map(result, & &1.price) == [10, 20, 30]
    end

    test "sort_by with comparator accepts string key parameter" do
      data = [%{"price" => 10}, %{"price" => 30}, %{"price" => 20}]
      result = Runtime.sort_by("price", &>=/2, data)
      assert Enum.map(result, & &1["price"]) == [30, 20, 10]
    end
  end

  describe "string key parameters - sum_by" do
    test "sum_by accepts string key parameter with string-keyed data" do
      data = [%{"amount" => 10}, %{"amount" => 20}, %{"amount" => 30}]
      result = Runtime.sum_by("amount", data)
      assert result == 60
    end

    test "sum_by accepts string key parameter with atom-keyed data" do
      data = [%{amount: 10}, %{amount: 20}, %{amount: 30}]
      result = Runtime.sum_by("amount", data)
      assert result == 60
    end
  end

  describe "string key parameters - avg_by" do
    test "avg_by accepts string key parameter with string-keyed data" do
      data = [%{"score" => 10}, %{"score" => 20}, %{"score" => 30}]
      result = Runtime.avg_by("score", data)
      assert result == 20.0
    end

    test "avg_by accepts string key parameter with atom-keyed data" do
      data = [%{score: 10}, %{score: 20}, %{score: 30}]
      result = Runtime.avg_by("score", data)
      assert result == 20.0
    end
  end

  describe "string key parameters - min_by" do
    test "min_by accepts string key parameter with string-keyed data" do
      data = [%{"score" => 30}, %{"score" => 10}, %{"score" => 20}]
      result = Runtime.min_by("score", data)
      assert result == %{"score" => 10}
    end

    test "min_by accepts string key parameter with atom-keyed data" do
      data = [%{score: 30}, %{score: 10}, %{score: 20}]
      result = Runtime.min_by("score", data)
      assert result == %{score: 10}
    end
  end

  describe "string key parameters - max_by" do
    test "max_by accepts string key parameter with string-keyed data" do
      data = [%{"score" => 10}, %{"score" => 30}, %{"score" => 20}]
      result = Runtime.max_by("score", data)
      assert result == %{"score" => 30}
    end

    test "max_by accepts string key parameter with atom-keyed data" do
      data = [%{score: 10}, %{score: 30}, %{score: 20}]
      result = Runtime.max_by("score", data)
      assert result == %{score: 30}
    end
  end

  describe "string key parameters - group_by" do
    test "group_by accepts string key parameter with string-keyed data" do
      data = [%{"category" => "a"}, %{"category" => "b"}, %{"category" => "a"}]
      result = Runtime.group_by("category", data)
      assert length(result["a"]) == 2
      assert length(result["b"]) == 1
    end

    test "group_by accepts string key parameter with atom-keyed data" do
      data = [%{category: "a"}, %{category: "b"}, %{category: "a"}]
      result = Runtime.group_by("category", data)
      assert length(result["a"]) == 2
      assert length(result["b"]) == 1
    end
  end

  describe "string key parameters - pluck" do
    test "pluck accepts string key parameter with string-keyed data" do
      data = [%{"name" => "Alice"}, %{"name" => "Bob"}]
      result = Runtime.pluck("name", data)
      assert result == ["Alice", "Bob"]
    end

    test "pluck accepts string key parameter with atom-keyed data" do
      data = [%{name: "Alice"}, %{name: "Bob"}]
      result = Runtime.pluck("name", data)
      assert result == ["Alice", "Bob"]
    end
  end

  describe "string key parameters - get" do
    test "get accepts string key parameter with string-keyed map" do
      map = %{"name" => "Alice"}
      assert Runtime.get(map, "name") == "Alice"
    end

    test "get accepts string key parameter with atom-keyed map" do
      map = %{name: "Alice"}
      assert Runtime.get(map, "name") == "Alice"
    end

    test "get with default accepts string key parameter" do
      map = %{"name" => "Alice"}
      assert Runtime.get(map, "age", 0) == 0
    end

    test "get with default preserves explicit nil values" do
      map = %{status: nil}
      assert Runtime.get(map, :status, "unknown") == nil
      assert Runtime.get(map, "status", "unknown") == nil
    end

    test "get with default and string key preserves explicit nil values in string-keyed map" do
      map = %{"status" => nil}
      assert Runtime.get(map, "status", "unknown") == nil
      assert Runtime.get(map, :status, "unknown") == nil
    end
  end

  describe "string key parameters - contains?" do
    test "contains? accepts string key parameter with string-keyed map" do
      map = %{"name" => "Alice"}
      assert Runtime.contains?(map, "name") == true
      assert Runtime.contains?(map, "age") == false
    end

    test "contains? accepts string key parameter with atom-keyed map" do
      map = %{name: "Alice"}
      assert Runtime.contains?(map, "name") == true
      assert Runtime.contains?(map, "age") == false
    end
  end

  # ============================================================
  # index_of
  # ============================================================

  describe "index_of/2" do
    test "finds first occurrence" do
      assert Runtime.index_of("hello", "ll") == 2
    end

    test "returns nil when not found" do
      assert Runtime.index_of("hello", "x") == nil
    end

    test "empty substring returns 0" do
      assert Runtime.index_of("hello", "") == 0
    end

    test "finds single character" do
      assert Runtime.index_of("hello", "l") == 2
    end

    test "finds at beginning" do
      assert Runtime.index_of("hello", "he") == 0
    end

    test "finds at end" do
      assert Runtime.index_of("hello", "lo") == 3
    end

    test "unicode string" do
      assert Runtime.index_of("héllo", "l") == 2
    end
  end

  describe "index_of/3 (with from-index)" do
    test "finds occurrence starting from index" do
      assert Runtime.index_of("hello", "l", 3) == 3
    end

    test "skips earlier occurrences" do
      assert Runtime.index_of("abcabc", "bc", 2) == 4
    end

    test "returns nil when from-index beyond string length" do
      assert Runtime.index_of("hello", "l", 10) == nil
    end

    test "empty substring with from-index returns min(from, length)" do
      assert Runtime.index_of("hello", "", 3) == 3
      assert Runtime.index_of("hello", "", 10) == 5
    end

    test "from-index 0 behaves like 2-arity" do
      assert Runtime.index_of("hello", "ll", 0) == 2
    end

    test "negative from-index is clamped to 0" do
      assert Runtime.index_of("hello", "he", -5) == 0
    end
  end

  # ============================================================
  # last_index_of
  # ============================================================

  describe "last_index_of/2" do
    test "finds last occurrence" do
      assert Runtime.last_index_of("hello", "l") == 3
    end

    test "returns nil when not found" do
      assert Runtime.last_index_of("hello", "x") == nil
    end

    test "empty substring returns string length" do
      assert Runtime.last_index_of("hello", "") == 5
    end

    test "single occurrence" do
      assert Runtime.last_index_of("hello", "he") == 0
    end

    test "multiple occurrences returns last" do
      assert Runtime.last_index_of("abcabc", "abc") == 3
    end

    test "overlapping matches finds last start position" do
      assert Runtime.last_index_of("aaa", "aa") == 1
      assert Runtime.last_index_of("aaaa", "aa") == 2
      assert Runtime.last_index_of("abab", "abab") == 0
    end

    test "overlapping matches with unicode" do
      assert Runtime.last_index_of("ééé", "éé") == 1
    end
  end

  describe "last_index_of/3 (with from-index)" do
    test "searches backwards from from-index" do
      assert Runtime.last_index_of("hello", "l", 2) == 2
    end

    test "returns nil when no match before from-index" do
      assert Runtime.last_index_of("hello", "l", 1) == nil
    end

    test "empty substring with from-index returns min(from, length)" do
      assert Runtime.last_index_of("hello", "", 3) == 3
      assert Runtime.last_index_of("hello", "", 10) == 5
    end

    test "from-index at last occurrence" do
      assert Runtime.last_index_of("hello", "l", 3) == 3
    end

    test "negative from-index is clamped to 0" do
      assert Runtime.last_index_of("abcabc", "a", -1) == 0
    end
  end
end
