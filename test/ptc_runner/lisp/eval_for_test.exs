defmodule PtcRunner.Lisp.EvalForTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  describe "for - single binding" do
    test "basic transform" do
      assert {:ok, %Step{return: [2, 4, 6]}} = Lisp.run("(for [x [1 2 3]] (* x 2))")
    end

    test "identity" do
      assert {:ok, %Step{return: [1, 2, 3]}} = Lisp.run("(for [x [1 2 3]] x)")
    end

    test "empty collection returns empty vector" do
      assert {:ok, %Step{return: []}} = Lisp.run("(for [x []] x)")
    end

    test "nil collection returns empty vector" do
      assert {:ok, %Step{return: []}} = Lisp.run("(for [x nil] x)")
    end

    test "string iteration" do
      assert {:ok, %Step{return: ["a!", "b!", "c!"]}} =
               Lisp.run(~S|(for [c "abc"] (str c "!"))|)
    end

    test "vector destructuring" do
      assert {:ok, %Step{return: [3, 7]}} =
               Lisp.run("(for [[a b] [[1 2] [3 4]]] (+ a b))")
    end

    test "map destructuring" do
      assert {:ok, %Step{return: [10, 20]}} =
               Lisp.run("(for [{:keys [x]} [{:x 10} {:x 20}]] x)")
    end
  end

  describe "for - multiple bindings (cartesian product)" do
    test "two bindings" do
      assert {:ok, %Step{return: [[1, "a"], [1, "b"], [2, "a"], [2, "b"]]}} =
               Lisp.run(~S|(for [x [1 2] y ["a" "b"]] [x y])|)
    end

    test "three bindings" do
      assert {:ok, %Step{return: result}} =
               Lisp.run("(for [x [1 2] y [10 20] z [100]] (+ x y z))")

      assert result == [111, 121, 112, 122]
    end

    test "empty inner collection" do
      assert {:ok, %Step{return: []}} =
               Lisp.run("(for [x [1 2] y []] [x y])")
    end
  end

  describe "for - multi-expression body" do
    test "implicit do, last value collected" do
      assert {:ok, %Step{} = step} =
               Lisp.run("""
               (for [x [1 2 3]]
                 (println x)
                 (* x 10))
               """)

      assert step.return == [10, 20, 30]
      assert step.prints == ["1", "2", "3"]
    end
  end

  describe "for - map iteration" do
    test "iterating over map entries" do
      assert {:ok, %Step{return: result}} =
               Lisp.run("(for [[k v] {:a 1 :b 2}] [k v])")

      assert Enum.sort(result) == [[:a, 1], [:b, 2]]
    end
  end

  describe "for - :when modifier" do
    test "basic filtering" do
      assert {:ok, %Step{return: [1, 3, 5]}} =
               Lisp.run("(for [x [1 2 3 4 5] :when (odd? x)] x)")
    end

    test "with cartesian product" do
      assert {:ok, %Step{return: [[1, 10], [1, 20]]}} =
               Lisp.run("(for [x [1 2] :when (odd? x) y [10 20]] [x y])")
    end

    test "all filtered out" do
      assert {:ok, %Step{return: []}} =
               Lisp.run("(for [x [1 2] :when false] x)")
    end

    test "multiple :when (AND)" do
      assert {:ok, %Step{return: [4, 5, 6]}} =
               Lisp.run("(for [x (range 10) :when (> x 3) :when (< x 7)] x)")
    end

    test ":when on inner binding" do
      assert {:ok, %Step{return: [[1, 4], [2, 4]]}} =
               Lisp.run("(for [x [1 2] y [3 4 5] :when (even? y)] [x y])")
    end
  end

  describe "for - :let modifier" do
    test "basic let" do
      assert {:ok, %Step{return: [10, 20, 30]}} =
               Lisp.run("(for [x [1 2 3] :let [y (* x 10)]] y)")
    end

    test "let with destructuring" do
      assert {:ok, %Step{return: [3, 7]}} =
               Lisp.run("(for [[a b] [[1 2] [3 4]] :let [s (+ a b)]] s)")
    end

    test "let references earlier binding" do
      assert {:ok, %Step{return: [11, 21, 14, 24]}} =
               Lisp.run("(for [x [1 2] :let [x2 (* x x)] y [10 20]] (+ x2 y))")
    end

    test "multiple let bindings in one :let vector" do
      assert {:ok, %Step{return: [13, 24, 35]}} =
               Lisp.run("(for [x [1 2 3] :let [y (* x 10) z (+ x 2)]] (+ y z))")
    end
  end

  describe "for - :while modifier" do
    test "basic while" do
      assert {:ok, %Step{return: [1, 2, 3]}} =
               Lisp.run("(for [x [1 2 3 4 5] :while (< x 4)] x)")
    end

    test "stops immediately" do
      assert {:ok, %Step{return: []}} =
               Lisp.run("(for [x [1 2 3] :while false] x)")
    end

    test "on inner binding only stops inner" do
      assert {:ok, %Step{return: [[1, 10], [1, 20], [2, 10], [2, 20]]}} =
               Lisp.run("(for [x [1 2] y [10 20 30] :while (< y 25)] [x y])")
    end
  end

  describe "for - combined modifiers" do
    test ":when + :let" do
      assert {:ok, %Step{return: [10, 30]}} =
               Lisp.run("(for [x [1 2 3 4] :when (odd? x) :let [y (* x 10)]] y)")
    end

    test ":let + :when (let visible to when)" do
      assert {:ok, %Step{return: [4, 6]}} =
               Lisp.run("(for [x [1 2 3] :let [y (* x 2)] :when (> y 3)] y)")
    end
  end

  describe "for - modifier errors" do
    test ":let without vector" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(for [x [1 2] :let x] x)")
      assert fail.message =~ ":let modifier requires a vector"
    end

    test "dangling modifier" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(for [x [1 2] :when] x)")
      assert fail.message =~ "modifier :when requires a value"
    end

    test "unknown modifier keyword" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(for [x [1 2] :whend true] x)")
      assert fail.message =~ "unknown modifier :whend"
    end

    test "keyword in binding position" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(for [:when [1 2]] x)")
      assert fail.message =~ "expected a binding symbol, got keyword"
    end
  end

  describe "for - errors" do
    test "odd number of bindings" do
      assert {:error, _} = Lisp.run("(for [x] x)")
    end

    test "non-vector bindings" do
      assert {:error, _} = Lisp.run("(for (x [1 2]) x)")
    end

    test "missing body" do
      assert {:error, _} = Lisp.run("(for [x [1 2]])")
    end

    test "non-collection value" do
      assert {:error, _} = Lisp.run("(for [x 42] x)")
    end
  end
end
