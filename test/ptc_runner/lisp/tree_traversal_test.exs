defmodule PtcRunner.Lisp.TreeTraversalTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "walk" do
    test "walks a list with inner and outer functions" do
      source = ~S|(walk inc #(apply + %) [1 2 3])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 9
    end

    test "identity walk returns original list" do
      source = ~S|(walk identity identity [1 2 3])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, 2, 3]
    end

    test "walks a map" do
      source = ~S|(walk identity identity {:a 1 :b 2})|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == %{a: 1, b: 2}
    end

    test "scalar passes through outer only" do
      source = ~S|(walk inc inc 5)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 6
    end

    test "nil passes through outer" do
      source = ~S|(walk identity identity nil)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == nil
    end

    test "walks nested list one level" do
      source = ~S|(walk first identity [[1] [2] [3]])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, 2, 3]
    end

    test "walks a set" do
      source = ~S|(walk inc identity #{1 2 3})|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == MapSet.new([2, 3, 4])
    end

    test "identity walk returns original set" do
      source = ~S|(walk identity identity #{1 2 3})|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == MapSet.new([1, 2, 3])
    end
  end

  describe "prewalk" do
    test "increments all numbers top-down" do
      source = ~S|(prewalk #(if (number? %) (inc %) %) [1 [2 3]])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [2, [3, 4]]
    end

    test "identity prewalk returns original" do
      source = ~S|(prewalk identity [1 [2 3]])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, [2, 3]]
    end

    test "doubles all numbers in nested structure" do
      source = ~S|(prewalk #(if (number? %) (* % 2) %) [1 [2 [3 4]]])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [2, [4, [6, 8]]]
    end

    test "works on maps" do
      source = ~S|(prewalk #(if (number? %) (inc %) %) {:a 1 :b {:c 2}})|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == %{a: 2, b: %{c: 3}}
    end

    test "works on sets" do
      source = ~S|(prewalk #(if (number? %) (inc %) %) #{1 2 3})|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == MapSet.new([2, 3, 4])
    end

    test "walks into nested sets" do
      source = ~S|(prewalk #(if (number? %) (* % 2) %) [#{1 2} #{3 4}])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [MapSet.new([2, 4]), MapSet.new([6, 8])]
    end

    test "works on scalar" do
      source = ~S|(prewalk inc 5)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 6
    end

    test "nil returns nil" do
      source = ~S|(prewalk identity nil)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == nil
    end

    test "empty collection returns empty collection" do
      source = ~S|(prewalk identity [])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "deeply nested structure" do
      source = ~S|(prewalk #(if (number? %) (+ % 10) %) [1 [2 [3 [4]]]])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [11, [12, [13, [14]]]]
    end
  end

  describe "postwalk" do
    test "increments all numbers bottom-up" do
      source = ~S|(postwalk #(if (number? %) (inc %) %) [1 [2 3]])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [2, [3, 4]]
    end

    test "identity postwalk returns original" do
      source = ~S|(postwalk identity [1 [2 3]])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, [2, 3]]
    end

    test "doubles all numbers in nested structure" do
      source = ~S|(postwalk #(if (number? %) (* % 2) %) [1 [2 [3 4]]])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [2, [4, [6, 8]]]
    end

    test "works on maps" do
      source = ~S|(postwalk #(if (number? %) (inc %) %) {:a 1 :b {:c 2}})|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == %{a: 2, b: %{c: 3}}
    end

    test "works on sets" do
      source = ~S|(postwalk #(if (number? %) (inc %) %) #{1 2 3})|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == MapSet.new([2, 3, 4])
    end

    test "walks into nested sets" do
      source = ~S|(postwalk #(if (number? %) (* % 2) %) [#{1 2} #{3 4}])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [MapSet.new([2, 4]), MapSet.new([6, 8])]
    end

    test "works on scalar" do
      source = ~S|(postwalk inc 5)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 6
    end

    test "nil returns nil" do
      source = ~S|(postwalk identity nil)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == nil
    end

    test "empty collection returns empty collection" do
      source = ~S|(postwalk identity [])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "can sum nested lists bottom-up" do
      # postwalk processes children first, so inner lists become sums before outer
      source = ~S|(postwalk #(if (vector? %) (apply + %) %) [[1 2] [3 4]])|
      {:ok, %{return: result}} = Lisp.run(source)
      # [1 2] -> 3, [3 4] -> 7, [3 7] -> 10
      assert result == 10
    end
  end

  describe "tree-seq" do
    test "flattens tree with :children key" do
      source = ~S|
        (let [tree {:id 1 :children [{:id 2 :children []} {:id 3 :children []}]}]
          (map :id (tree-seq :children :children tree)))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, 2, 3]
    end

    test "handles nested tree" do
      source = ~S|
        (let [tree {:id 1 :children [{:id 2 :children [{:id 4 :children []}]} {:id 3 :children []}]}]
          (map :id (tree-seq :children :children tree)))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, 2, 4, 3]
    end

    test "single node tree" do
      source = ~S|
        (let [tree {:id 1 :children []}]
          (map :id (tree-seq :children :children tree)))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1]
    end

    test "branch? can use custom predicate" do
      source = ~S|
        (let [tree {:id 1 :kids [{:id 2 :kids []} {:id 3 :kids []}]}]
          (map :id (tree-seq :kids :kids tree)))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, 2, 3]
    end

    test "works with nil children" do
      source = ~S|
        (let [tree {:id 1 :children nil}]
          (map :id (tree-seq :children :children tree)))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1]
    end

    test "works with function predicates" do
      source = ~S|
        (let [tree {:id 1 :items [{:id 2 :items []} {:id 3 :items []}]}]
          (map :id (tree-seq #(not (empty? (:items %))) :items tree)))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [1, 2, 3]
    end
  end

  describe "tree traversal practical use cases" do
    test "find all nodes matching criteria" do
      source = ~S|
        (let [tree {:name "root" :value 10 :children [
                     {:name "a" :value 5 :children []}
                     {:name "b" :value 15 :children [
                       {:name "c" :value 20 :children []}]}]}]
          (->> (tree-seq :children :children tree)
               (filter #(> (:value %) 10))
               (map :name)))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["b", "c"]
    end

    test "transform all values in tree" do
      source = ~S|
        (prewalk #(if (and (map? %) (:value %))
                     (update % :value inc)
                     %)
                 {:value 1 :nested {:value 2}})
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == %{value: 2, nested: %{value: 3}}
    end

    test "count nodes in tree" do
      source = ~S|
        (let [tree {:id 1 :children [{:id 2 :children [{:id 4 :children []}]} {:id 3 :children []}]}]
          (count (tree-seq :children :children tree)))
      |
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 4
    end
  end
end
