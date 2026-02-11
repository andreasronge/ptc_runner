defmodule PtcRunner.Lisp.EvalDoseqTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  describe "doseq" do
    test "basic single binding" do
      assert {:ok, %Step{} = step} = Lisp.run("(doseq [x [1 2 3]] (println x))")

      assert step.return == nil
      assert step.prints == ["1", "2", "3"]
    end

    test "multiple bindings (nested loops)" do
      assert {:ok, %Step{} = step} = Lisp.run(~S|(doseq [x [1 2] y ["a" "b"]] (println x y))|)

      assert step.return == nil
      assert step.prints == ["1 a", "1 b", "2 a", "2 b"]
    end

    test "destructuring in bindings" do
      assert {:ok, %Step{} = step} = Lisp.run("(doseq [[a b] [[1 2] [3 4]]] (println (+ a b)))")

      assert step.return == nil
      assert step.prints == ["3", "7"]
    end

    test "empty collection" do
      assert {:ok, %Step{} = step} = Lisp.run("(doseq [x []] (println x))")

      assert step.return == nil
      assert step.prints == []
    end

    test "nil collection" do
      assert {:ok, %Step{} = step} = Lisp.run("(doseq [x nil] (println x))")

      assert step.return == nil
      assert step.prints == []
    end

    test "body with multiple expressions" do
      assert {:ok, %Step{} = step} =
               Lisp.run(~S|(doseq [x [1]] (println "start") (println x) (println "end"))|)

      assert step.return == nil
      assert step.prints == ["start", "1", "end"]
    end

    test "nested explicit doseq" do
      assert {:ok, %Step{} = step} = Lisp.run("(doseq [x [1 2]] (doseq [y [3 4]] (println x y)))")

      assert step.return == nil
      assert step.prints == ["1 3", "1 4", "2 3", "2 4"]
    end

    test "map iteration" do
      # Maps iterate as [key value] pairs
      # Using sort because map iteration order is stable in PTC-Lisp but let's be sure.
      source = "(doseq [[k v] {:a 1 :b 2}] (println k v))"
      assert {:ok, %Step{prints: prints}} = Lisp.run(source)
      # PTC-Lisp map iteration order is currently stable (alphabetic keys)
      # Keywords print with a colon
      assert Enum.sort(prints) == [":a 1", ":b 2"]
    end

    test "string iteration" do
      assert {:ok, %Step{prints: prints}} = Lisp.run("(doseq [c \"abc\"] (println c))")
      assert prints == ["a", "b", "c"]
    end
  end

  describe "doseq - :when modifier" do
    test "basic filtering" do
      assert {:ok, %Step{prints: prints}} =
               Lisp.run("(doseq [x [1 2 3 4 5] :when (odd? x)] (println x))")

      assert prints == ["1", "3", "5"]
    end

    test "all filtered out" do
      assert {:ok, %Step{prints: prints}} =
               Lisp.run("(doseq [x [1 2] :when false] (println x))")

      assert prints == []
    end

    test ":when on inner binding" do
      assert {:ok, %Step{prints: prints}} =
               Lisp.run("(doseq [x [1 2] y [3 4 5] :when (even? y)] (println x y))")

      assert prints == ["1 4", "2 4"]
    end
  end

  describe "doseq - :let modifier" do
    test "basic let" do
      assert {:ok, %Step{prints: prints}} =
               Lisp.run("(doseq [x [1 2 3] :let [y (* x 10)]] (println y))")

      assert prints == ["10", "20", "30"]
    end
  end

  describe "doseq - :while modifier" do
    test "basic while" do
      assert {:ok, %Step{prints: prints}} =
               Lisp.run("(doseq [x [1 2 3 4 5] :while (< x 4)] (println x))")

      assert prints == ["1", "2", "3"]
    end

    test "on inner binding only stops inner" do
      assert {:ok, %Step{prints: prints}} =
               Lisp.run("(doseq [x [1 2] y [10 20 30] :while (< y 25)] (println x y))")

      assert prints == ["1 10", "1 20", "2 10", "2 20"]
    end
  end

  describe "doseq - combined modifiers" do
    test ":when + :let" do
      assert {:ok, %Step{prints: prints}} =
               Lisp.run("(doseq [x [1 2 3 4] :when (odd? x) :let [y (* x 10)]] (println y))")

      assert prints == ["10", "30"]
    end
  end

  describe "doseq error handling" do
    test "odd number of bindings" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(doseq [x] (println x))")
      assert fail.reason == :invalid_form
      assert fail.message =~ "trailing element"
    end

    test "non-vector bindings" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(doseq x (println x))")
      assert fail.reason == :invalid_arity
      assert fail.message =~ "expected (doseq [bindings] body ...)"
    end

    test "unknown modifier keyword" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(doseq [x [1 2] :whend true] (println x))")
      assert fail.reason == :invalid_form
      assert fail.message =~ "unknown modifier :whend"
    end

    test "body missing" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(doseq [x [1 2]])")
      assert fail.reason == :invalid_arity
      assert fail.message =~ "missing body"
    end

    test "non-collection value" do
      assert {:error, %Step{fail: fail}} = Lisp.run("(doseq [x 42] (println x))")
      assert fail.reason == :invalid_arity
      assert fail.message =~ "expected a collection, got: 42 (number)"
    end
  end
end
