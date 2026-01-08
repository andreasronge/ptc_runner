defmodule PtcRunner.Lisp.EvalLoopTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  describe "loop/recur" do
    test "basic loop with increment" do
      code = "(loop [x 0] (if (< x 5) (recur (+ x 1)) x))"
      assert {:ok, %{return: 5}} = Lisp.run(code)
    end

    test "loop with multiple bindings (summing)" do
      code = """
      (loop [i 0 acc 0]
        (if (< i 5)
          (recur (+ i 1) (+ acc i))
          acc))
      """

      assert {:ok, %{return: 10}} = Lisp.run(code)
    end

    test "recur in fn body" do
      code = """
      ((fn [n]
         (loop [i n acc 1]
           (if (> i 0)
             (recur (- i 1) (* acc i))
             acc)))
       5)
      """

      assert {:ok, %{return: 120}} = Lisp.run(code)
    end

    test "recursion through fn head" do
      code = """
      ((fn [n acc]
         (if (> n 0)
           (recur (- n 1) (* acc n))
           acc))
       5 1)
      """

      assert {:ok, %{return: 120}} = Lisp.run(code)
    end

    test "nested loops" do
      code = """
      (loop [i 0 result []]
        (if (< i 3)
          (recur (+ i 1)
                 (conj result
                       (loop [j 0 sum 0]
                         (if (< j i)
                           (recur (+ j 1) (+ sum j))
                           sum))))
          result))
      """

      assert {:ok, %{return: [0, 0, 1]}} = Lisp.run(code)
    end
  end

  describe "safety limits" do
    test "infinite loop is caught by iteration limit" do
      code = "(loop [x 0] (recur x))"
      assert {:error, %{fail: %{reason: :loop_limit_exceeded}}} = Lisp.run(code)
    end

    test "custom loop limit would fail similarly" do
      code = "(loop [x 0] (recur (inc x)))"
      # Default is 1000, so it should fail when x reaches 1000
      assert {:error, %{fail: %{reason: :loop_limit_exceeded}}} = Lisp.run(code)
    end
  end

  describe "tail position validation" do
    test "recur not in tail position (rejected by analyzer)" do
      code = "(loop [x 0] (+ 1 (recur x)))"
      assert {:error, %{fail: %{reason: :invalid_form}}} = Lisp.run(code)
    end

    test "recur in non-tail branch of if" do
      code = "(loop [x 0] (if (recur x) true false))"
      assert {:error, %{fail: %{reason: :invalid_form}}} = Lisp.run(code)
    end

    test "recur in thread macro (tail position of thread)" do
      code = "(loop [x 0] (if (< x 5) (-> x inc recur) x))"
      assert {:ok, %{return: 5}} = Lisp.run(code)
    end

    test "recur in thread macro (non-tail position of thread)" do
      code = "(loop [x 0] (-> x recur inc))"
      assert {:error, %{fail: %{reason: :invalid_form}}} = Lisp.run(code)
    end
  end

  describe "arity check" do
    test "recur wrong arity for loop" do
      code = "(loop [x 0] (recur))"
      assert {:error, %{fail: %{reason: :arity_mismatch}}} = Lisp.run(code)
    end

    test "recur wrong arity for fn" do
      code = "((fn [x] (recur x 1)) 0)"
      assert {:error, %{fail: %{reason: :arity_mismatch}}} = Lisp.run(code)
    end
  end

  describe "calling functions from loop" do
    test "calling defn from loop preserves loop bindings" do
      # Regression test: calling user-defined functions from within a loop
      # should not corrupt the loop's environment
      code = """
      (defn twice [x] (* x 2))
      (loop [acc 0 n 3]
        (if (zero? n)
          acc
          (recur (+ acc (twice n)) (dec n))))
      """

      # twice(3) + twice(2) + twice(1) = 6 + 4 + 2 = 12
      assert {:ok, %{return: 12}} = Lisp.run(code)
    end

    test "calling defn with internal loop from outer loop" do
      code = """
      (defn is-prime? [n]
        (if (<= n 1)
          false
          (loop [i 2]
            (if (> (* i i) n)
              true
              (if (zero? (mod n i))
                false
                (recur (inc i)))))))

      (loop [primes []
             num 2]
        (if (= (count primes) 5)
          primes
          (if (is-prime? num)
            (recur (conj primes num) (inc num))
            (recur primes (inc num)))))
      """

      assert {:ok, %{return: [2, 3, 5, 7, 11]}} = Lisp.run(code)
    end

    test "calling anonymous function from loop preserves bindings" do
      code = """
      (def triple (fn [x] (* x 3)))
      (loop [acc [] n 3]
        (if (zero? n)
          acc
          (recur (conj acc (triple n)) (dec n))))
      """

      assert {:ok, %{return: [9, 6, 3]}} = Lisp.run(code)
    end
  end
end
