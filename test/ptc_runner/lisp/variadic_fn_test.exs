defmodule PtcRunner.Lisp.VariadicFnTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  describe "variadic fn" do
    test "[& args] collects all arguments" do
      code = "(defn f [& args] args) (f 1 2 3)"
      assert {:ok, %{return: [1, 2, 3]}} = Lisp.run(code)
    end

    test "[& args] with no arguments" do
      code = "(defn f [& args] args) (f)"
      assert {:ok, %{return: []}} = Lisp.run(code)
    end

    test "[a & rest] fixed + variadic" do
      code = "(defn f [a & rest] [a rest]) (f 1 2 3 4)"
      assert {:ok, %{return: [1, [2, 3, 4]]}} = Lisp.run(code)
    end

    test "[a b & rest] multiple fixed + variadic" do
      code = "(defn f [a b & rest] [a b rest]) (f 1 2 3 4 5)"
      assert {:ok, %{return: [1, 2, [3, 4, 5]]}} = Lisp.run(code)
    end

    test "arity error when too few args for leading params" do
      code = "(defn f [a b & rest] rest) (f 1)"
      assert {:error, %{fail: %{reason: :arity_mismatch}}} = Lisp.run(code)
    end

    test "variadic with reduce" do
      code = "(defn sum [& nums] (reduce + 0 nums)) (sum 1 2 3 4 5)"
      assert {:ok, %{return: 15}} = Lisp.run(code)
    end

    test "anonymous variadic fn" do
      code = "((fn [& args] (count args)) 1 2 3)"
      assert {:ok, %{return: 3}} = Lisp.run(code)
    end

    test "recur in variadic fn" do
      code = """
      (defn my-sum [acc & nums]
        (if (empty? nums)
          acc
          (recur (+ acc (first nums)) (next nums))))
      (my-sum 0 1 2 3 4 5)
      """

      # Note: (next nums) returns a list or nil. recur should handle this.
      # Wait, if nums is [2, 3, 4, 5], (next nums) is [3, 4, 5].
      # If nums is [5], (next nums) is nil.
      # recur arity check for variadic fn with [acc & nums] expects 1+ args.
      # If (next nums) is nil, recur gets 2 args: new_acc and nil.
      # But nums pattern should match nil? Patterns.match_pattern(rest_pattern, rest_args)
      # rest_args will be [nil] if we pass nil as second arg to recur.
      # THAT IS WRONG. recur should probably spread the last arg if it's a list?
      # NO, Clojure recur for variadic fn: (recur 1 [2 3]) -> acc=1, nums=[2 3]
      # Wait, Clojure's recur doesn't auto-spread.
      # If I have (defn f [a & rest] (recur 1 [2 3])), then a=1, rest=[2 3].
      # This matches how I implemented it.
      assert {:ok, %{return: 15}} = Lisp.run(code)
    end

    test "variadic closure passed to HOF (reduce)" do
      code = """
      (defn sum-two [acc x] (+ acc x))
      (reduce sum-two 0 [1 2 3])
      """

      assert {:ok, %{return: 6}} = Lisp.run(code)
    end

    test "variadic closure with min_arity 2 passed to reduce" do
      code = """
      (defn my-reducer [acc x & rest] (+ acc x))
      (reduce my-reducer 0 [1 2 3])
      """

      assert {:ok, %{return: 6}} = Lisp.run(code)
    end

    test "destructuring in leading params" do
      code = "(defn f [{:keys [x]} & rest] [x rest]) (f {:x 1} 2 3)"
      assert {:ok, %{return: [1, [2, 3]]}} = Lisp.run(code)
    end

    test "nested destructure in rest position" do
      code = "(defn f [a & [b c]] [a b c]) (f 1 2 3)"
      assert {:ok, %{return: [1, 2, 3]}} = Lisp.run(code)
    end
  end
end
