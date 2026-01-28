defmodule PtcRunner.Lisp.CombinationsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "pairs" do
    test "generates all pairs from a list" do
      source = ~S|(pairs [1 2 3])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[1, 2], [1, 3], [2, 3]]
    end

    test "generates pairs from a string" do
      source = ~S|(pairs "abc")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [["a", "b"], ["a", "c"], ["b", "c"]]
    end

    test "returns empty list for single element" do
      source = ~S|(pairs [1])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "returns empty list for empty collection" do
      source = ~S|(pairs [])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "works with mixed types" do
      source = ~S|(pairs [:a :b :c])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[:a, :b], [:a, :c], [:b, :c]]
    end

    test "works with two elements" do
      source = ~S|(pairs [1 2])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[1, 2]]
    end

    test "works with four elements" do
      source = ~S|(pairs [1 2 3 4])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[1, 2], [1, 3], [1, 4], [2, 3], [2, 4], [3, 4]]
    end
  end

  describe "combinations" do
    test "generates 3-combinations from a list" do
      source = ~S|(combinations [1 2 3 4] 3)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[1, 2, 3], [1, 2, 4], [1, 3, 4], [2, 3, 4]]
    end

    test "generates 0-combinations (empty subset)" do
      source = ~S|(combinations [1 2 3] 0)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[]]
    end

    test "returns empty list when n > length" do
      source = ~S|(combinations [1 2] 3)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "generates 1-combinations (singletons)" do
      source = ~S|(combinations [1 2 3] 1)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[1], [2], [3]]
    end

    test "combinations equal to length gives single combination" do
      source = ~S|(combinations [1 2 3] 3)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[1, 2, 3]]
    end

    test "works with strings" do
      source = ~S|(combinations "abcd" 2)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [["a", "b"], ["a", "c"], ["a", "d"], ["b", "c"], ["b", "d"], ["c", "d"]]
    end

    test "returns empty list for empty collection" do
      source = ~S|(combinations [] 1)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "0-combinations of empty list returns [[]]" do
      source = ~S|(combinations [] 0)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[]]
    end
  end

  describe "combinations practical use cases" do
    test "finding all pairs that sum to target" do
      source = ~S|
        (let [nums [1 2 3 4 5]
              target 6]
          (->> (pairs nums)
               (filter (fn [[a b]] (= (+ a b) target)))))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[1, 5], [2, 4]]
    end

    test "counting valid combinations" do
      source = ~S|(count (combinations [1 2 3 4 5] 3))|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 10
    end
  end
end
