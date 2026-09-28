defmodule PtcRunner.Lisp.EvalControlFlowTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.Eval

  describe "variable access" do
    test "unbound variable returns error" do
      assert {:error, {:unbound_var, :x}} = Eval.eval({:var, :x}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "bound variable returns value" do
      env = %{x: 42}
      assert {:ok, 42, %{}} = Eval.eval({:var, :x}, %{}, %{}, env, &dummy_tool/2)
    end

    test "context access" do
      ctx = %{user: "alice"}
      assert {:ok, "alice", %{}} = Eval.eval({:data, :user}, ctx, %{}, %{}, &dummy_tool/2)
    end

    test "context access returns nil if key missing" do
      assert {:ok, nil, %{}} = Eval.eval({:data, :missing}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "short-circuit logic: or" do
    test "unbound memory variable falls through to default" do
      # The canonical memory pattern: (or my-counter 0)
      # When the variable has never been def'd, it should behave like nil
      # and return the default — not crash with :unbound_var.
      exprs = [{:var, :my_counter}, 0]
      # ctx=%{}, memory=%{} (empty — variable never defined), env=%{}
      assert {:ok, 0, _} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "truthy memory variable is returned without hitting default" do
      exprs = [{:var, :my_counter}, 0]
      # ctx=%{}, memory=%{"my_counter" => 42}, env=%{}
      assert {:ok, 42, _} =
               Eval.eval({:or, exprs}, %{}, %{"my_counter" => 42}, %{}, &dummy_tool/2)
    end

    test "unbound variable in non-first position falls through" do
      # (or nil unbound-b) should return nil, not crash
      exprs = [nil, {:var, :unbound_b}]
      assert {:ok, nil, _} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "multiple unbound variables all fall through to nil" do
      # (or unbound-a unbound-b) should return nil, not crash
      exprs = [{:var, :unbound_a}, {:var, :unbound_b}]
      assert {:ok, nil, _} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "unbound variables nested in an expression fall through to the default" do
      exprs = [{:do, [{:var, :missing}]}, 42]

      assert {:ok, 42, _} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "non-unbound errors still propagate" do
      # Only :unbound_var is suppressed; other errors (e.g. type errors) surface.
      # Test via Lisp.run where error handling is clean.
      assert {:error, _step} = PtcRunner.Lisp.run("(or (+ 1 \"bad\") 99)")
    end
  end

  describe "case — value dispatch" do
    alias PtcRunner.Lisp

    test "keyword matching" do
      assert {:ok, %{return: 1}} = Lisp.run("(case :a :a 1 :b 2)")
    end

    test "string matching" do
      assert {:ok, %{return: 1}} = Lisp.run(~s|(case "x" "x" 1 "y" 2)|)
    end

    test "number matching" do
      assert {:ok, %{return: "forty-two"}} = Lisp.run(~s|(case 42 1 "one" 42 "forty-two")|)
    end

    test "grouped match" do
      assert {:ok, %{return: 2}} = Lisp.run("(case :c (:a :b) 1 (:c :d) 2)")
    end

    test "default" do
      assert {:ok, %{return: "default"}} = Lisp.run(~s|(case :z :a 1 :b 2 "default")|)
    end

    test "no match, no default returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(case :z :a 1 :b 2)")
    end

    test "nil matching" do
      assert {:ok, %{return: "matched"}} = Lisp.run(~s|(case nil nil "matched" :a "nope")|)
    end

    test "boolean matching" do
      assert {:ok, %{return: "yes"}} = Lisp.run(~s|(case true true "yes" false "no")|)
    end

    test "expression evaluated once" do
      # Use def to track evaluation count
      code = """
      (do
        (def counter 0)
        (case (do (def counter (inc counter)) :a)
          :a "matched"
          :b "nope")
        counter)
      """

      assert {:ok, %{return: 1}} = Lisp.run(code)
    end

    test "expression only, no clauses returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(case :a)")
    end

    test "float test value" do
      assert {:ok, %{return: "pi"}} = Lisp.run(~s|(case 3.14 3.14 "pi" 2.71 "e")|)
    end
  end

  describe "condp — predicate dispatch" do
    alias PtcRunner.Lisp

    test "basic equality" do
      assert {:ok, %{return: 1}} = Lisp.run("(condp = :a :a 1 :b 2)")
    end

    test "comparison: (pred test expr) order" do
      # (condp > 5 10 "big" 3 "small")
      # calls (> 10 5) → true → "big"
      assert {:ok, %{return: "big"}} = Lisp.run(~s|(condp > 5 10 "big" 3 "small")|)
    end

    test "default" do
      assert {:ok, %{return: "default"}} = Lisp.run(~s|(condp = :z :a 1 "default")|)
    end

    test "no match, no default returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(condp = :z :a 1 :b 2)")
    end

    test "pred invoked per clause" do
      code = """
      (do
        (def pred-count 0)
        (let [my-pred (fn [a b] (do (def pred-count (inc pred-count)) (= a b)))]
          (condp my-pred :b :a 1 :b 2))
        pred-count)
      """

      assert {:ok, %{return: 2}} = Lisp.run(code)
    end

    test "pred expression evaluated once" do
      code = """
      (do
        (def build-count 0)
        (condp (do (def build-count (inc build-count)) =) :b
          :a 1
          :b 2
          :c 3)
        build-count)
      """

      assert {:ok, %{return: 1}} = Lisp.run(code)
    end

    test "expr evaluated once" do
      code = """
      (do
        (def expr-count 0)
        (condp = (do (def expr-count (inc expr-count)) :a)
          :a "matched"
          :b "nope")
        expr-count)
      """

      assert {:ok, %{return: 1}} = Lisp.run(code)
    end

    test "condp with custom predicate" do
      code = """
      (condp = (+ 1 1)
        1 "one"
        2 "two"
        3 "three")
      """

      assert {:ok, %{return: "two"}} = Lisp.run(code)
    end
  end
end
