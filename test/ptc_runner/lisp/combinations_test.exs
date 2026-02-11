defmodule PtcRunner.Lisp.CombinationsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "combinations" do
    test "generates 2-combinations from a list" do
      source = ~S|(combinations [1 2 3] 2)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [[1, 2], [1, 3], [2, 3]]
    end

    test "generates 2-combinations from a string" do
      source = ~S|(combinations "abc" 2)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [["a", "b"], ["a", "c"], ["b", "c"]]
    end

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
          (->> (combinations nums 2)
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
