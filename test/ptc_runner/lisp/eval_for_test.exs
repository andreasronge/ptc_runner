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

  describe "for - errors" do
    test "odd number of bindings" do
      assert {:error, _} = Lisp.run("(for [x] x)")
    end

    test "non-vector bindings" do
      assert {:error, _} = Lisp.run("(for (x [1 2]) x)")
    end

    test "modifier rejected" do
      assert {:error, _} = Lisp.run("(for [x [1 2] :when (odd? x)] x)")
    end

    test "missing body" do
      assert {:error, _} = Lisp.run("(for [x [1 2]])")
    end

    test "non-collection value" do
      assert {:error, _} = Lisp.run("(for [x 42] x)")
    end
  end
end
