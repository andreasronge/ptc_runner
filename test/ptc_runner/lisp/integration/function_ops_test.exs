defmodule PtcRunner.Lisp.Integration.FunctionOpsTest do
  @moduledoc """
  Tests for function operations in PTC-Lisp.

  Covers higher-order functions, string parsing, and sequential evaluation.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  # ==========================================================================
  # Builtins as Higher-Order Function Arguments
  # ==========================================================================

  describe "builtins as HOF arguments" do
    test "sort-by with > comparator for descending order" do
      source = ~S"""
      (sort-by :price > data/products)
      """

      ctx = %{
        products: [
          %{name: "Book", price: 15},
          %{name: "Laptop", price: 999},
          %{name: "Phone", price: 599}
        ]
      }

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      assert Enum.map(result, & &1.name) == ["Laptop", "Phone", "Book"]
    end

    test "sort-by with < comparator for ascending order" do
      source = ~S"""
      (sort-by :name < data/users)
      """

      ctx = %{
        users: [
          %{name: "Charlie"},
          %{name: "Alice"},
          %{name: "Bob"}
        ]
      }

      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)

      assert Enum.map(result, & &1.name) == ["Alice", "Bob", "Charlie"]
    end

    test "sort-by with first function" do
      source = ~S"""
      (let [pairs [["b" 2] ["a" 1] ["c" 3]]]
        (sort-by first pairs))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == [["a", 1], ["b", 2], ["c", 3]]
    end

    test "sort-by with function key and comparator" do
      source = ~S"""
      (let [pairs [["Food" 500] ["Transport" 300] ["Entertainment" 800]]]
        (sort-by (fn [x] (nth x 1)) > pairs))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == [["Entertainment", 800], ["Food", 500], ["Transport", 300]]
    end

    test "group-by with first function" do
      source = ~S"""
      (let [pairs [["a" 1] ["a" 2] ["b" 3]]]
        (group-by first pairs))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == %{"a" => [["a", 1], ["a", 2]], "b" => [["b", 3]]}
    end

    test "min-by with function key" do
      source = ~S"""
      (let [pairs [["a" 10] ["b" 5] ["c" 30]]]
        (min-by (fn [x] (nth x 1)) pairs))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == ["b", 5]
    end

    test "max-by with function key" do
      source = ~S"""
      (let [pairs [["a" 10] ["b" 5] ["c" 30]]]
        (max-by (fn [x] (nth x 1)) pairs))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == ["c", 30]
    end

    test "max-key returns element with greatest (f x)" do
      source = ~S|(max-key count "a" "abc" "ab")|

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == "abc"
    end

    test "max-key with anonymous function" do
      source = ~S|(max-key #(nth % 1) ["a" 1] ["b" 5] ["c" 3])|

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == ["b", 5]
    end

    test "max-key on map entries" do
      # Map entries are [:key value], use second to get the value
      source = ~S"""
      (def counts {:alice 3 :bob 7 :carol 2})
      (max-key second (first (seq counts)) (second (seq counts)) (nth (seq counts) 2))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == [:bob, 7]
    end

    test "max-key with apply on map entries" do
      # Use second to extract value from map entry [:key value]
      source = ~S|(apply max-key second (seq {:alice 3 :bob 7 :carol 2}))|

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == [:bob, 7]
    end

    test "min-key returns element with least (f x)" do
      source = ~S|(min-key count "abc" "a" "ab")|

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == "a"
    end

    test "min-key with anonymous function" do
      source = ~S|(min-key #(nth % 1) ["a" 5] ["b" 1] ["c" 3])|

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == ["b", 1]
    end

    test "max-key with single element returns that element" do
      source = ~S|(max-key count "hello")|

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == "hello"
    end

    test "sum-by with function key" do
      source = ~S"""
      (let [pairs [["a" 10] ["b" 20] ["c" 30]]]
        (sum-by (fn [x] (nth x 1)) pairs))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == 60
    end

    test "avg-by with function key" do
      source = ~S"""
      (let [pairs [["a" 10] ["b" 20] ["c" 30]]]
        (avg-by (fn [x] (nth x 1)) pairs))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == 20.0
    end

    test "reduce with + accumulator" do
      source = ~S"""
      (reduce + 0 [1 2 3 4 5])
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == 15
    end

    test "reduce with * accumulator" do
      source = ~S"""
      (reduce * 1 [1 2 3 4 5])
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == 120
    end

    # Issue #586: reduce argument order must match Clojure (f acc elem)
    test "reduce with - uses Clojure argument order (3-arg)" do
      # (reduce (fn [acc x] (- acc x)) 10 [1 2 3])
      # = (- (- (- 10 1) 2) 3) = (- (- 9 2) 3) = (- 7 3) = 4
      source = ~S"""
      (reduce (fn [acc x] (- acc x)) 10 [1 2 3])
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == 4
    end

    test "reduce with - uses Clojure argument order (2-arg)" do
      # (reduce - [10 1 2 3])
      # = (- (- (- 10 1) 2) 3) = 4
      source = ~S"""
      (reduce - [10 1 2 3])
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == 4
    end

    # Issue #245: Fix `or` to track last evaluated value
    test "or with all falsy values returns last evaluated value" do
      source = ~S"""
      (or false nil)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == nil
    end

    test "or with all falsy values (different order) returns last evaluated value" do
      source = ~S"""
      (or nil false)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == false
    end

    # Issue #245: Fix `some` to return predicate result (not boolean)
    test "some returns first truthy predicate result" do
      source = ~S"""
      (some nil? [1 nil 3])
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == true
    end

    test "some returns nil when no match" do
      source = ~S"""
      (some nil? [1 2 3])
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == nil
    end

    # Issue #245: Fix subtraction to use correct reduce order
    test "unary minus returns negation" do
      source = ~S"""
      (- 10)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == -10
    end

    test "binary subtraction works correctly" do
      source = ~S"""
      (- 10 3)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == 7
    end

    test "variadic subtraction evaluates left-to-right" do
      source = ~S"""
      (- 10 3 2 1)
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      assert result == 4
    end
  end

  describe "String parsing" do
    test "parse-long and parse-double for string to number conversion" do
      # Parse and sum numeric strings, filtering invalid
      {:ok, %Step{return: result}} =
        Lisp.run("""
          (reduce + 0 (filter some? (map parse-long ["1" "2" "three" "4"])))
        """)

      assert result == 7
    end

    test "safe parsing with default" do
      {:ok, %Step{return: result}} =
        Lisp.run("""
          (let [val (parse-double "invalid")]
            (if (some? val) val 0.0))
        """)

      assert result == 0.0
    end

    test "parse API response data" do
      {:ok, %Step{return: result}} =
        Lisp.run(
          """
          (let [response data/response]
            (* (parse-double (:price response))
               (parse-long (:quantity response))))
          """,
          context: %{"response" => %{"price" => "19.99", "quantity" => "3"}}
        )

      assert_in_delta result, 59.97, 0.001
    end
  end

  # ==========================================================================
  # Calling User-Defined Functions from Loops
  # ==========================================================================

  describe "calling closures from loop" do
    # Regression test for environment corruption when calling closures from loops.
    # Before fix: calling a user-defined function from within a loop would cause
    # "undefined variable" errors because the closure's environment was returned
    # instead of the caller's environment.

    test "defn called from loop preserves loop bindings" do
      source = ~S"""
      (defn square [x] (* x x))
      (loop [acc 0 n 3]
        (if (zero? n)
          acc
          (recur (+ acc (square n)) (dec n))))
      """

      # square(3) + square(2) + square(1) = 9 + 4 + 1 = 14
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == 14
    end

    test "defn with internal loop called from outer loop" do
      # This is the exact pattern that was failing: is-prime? has its own loop,
      # and calling it from another loop was corrupting the outer loop's environment
      source = ~S"""
      (defn is-prime? [n]
        (if (<= n 1)
          false
          (loop [i 2]
            (if (> (* i i) n)
              true
              (if (zero? (mod n i))
                false
                (recur (inc i)))))))

      (loop [primes [] num 2]
        (if (= (count primes) 5)
          primes
          (if (is-prime? num)
            (recur (conj primes num) (inc num))
            (recur primes (inc num)))))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [2, 3, 5, 7, 11]
    end

    test "anonymous function via def called from loop" do
      source = ~S"""
      (def cube (fn [x] (* x x x)))
      (loop [results [] n 3]
        (if (zero? n)
          results
          (recur (conj results (cube n)) (dec n))))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [27, 8, 1]
    end
  end

  # ==========================================================================
  # Sequential Evaluation with do
  # ==========================================================================

  describe "sequential evaluation: do" do
    test "do evaluates expressions sequentially without short-circuiting" do
      source = ~S"""
      (do
        (let [x 1] x)
        (let [y 2] y)
        (let [z 3] z))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == 3
    end

    test "do enables sequential tool call patterns" do
      source = ~S"""
      (do
        (+ 1 1)
        (+ 2 2)
        (+ 3 3))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)

      # All three additions evaluate in sequence, returning the last result
      assert result == 6
    end

    test "do propagates errors without evaluating remaining expressions" do
      source = ~S"""
      (do
        (+ 1 1)
        (+ "string" 42)
        (+ 3 3))
      """

      # Type errors return helpful messages about the argument types
      assert {:error, %Step{fail: %{reason: :type_error}}} = Lisp.run(source)
    end
  end

  # ==========================================================================
  # Maps as Functions (Clojure-style)
  # ==========================================================================

  describe "maps as functions" do
    test "map with keyword key" do
      source = ~S"""
      (let [m {:name "Alice" :age 30}]
        (m :name))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == "Alice"
    end

    test "map with keyword key returns nil for missing key" do
      source = ~S"""
      (let [m {:name "Alice"}]
        (m :missing))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == nil
    end

    test "map with keyword key and default value" do
      source = ~S"""
      (let [m {:name "Alice"}]
        (m :missing "default"))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == "default"
    end

    test "map with string key" do
      source = ~S"""
      (let [m {"name" "Bob" "city" "NYC"}]
        (m "city"))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == "NYC"
    end

    test "map with string key and default" do
      source = ~S"""
      (let [m {"a" 1}]
        (m "missing" "fallback"))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == "fallback"
    end

    test "map with integer key" do
      source = ~S"""
      (let [m {0 "zero" 1 "one" 2 "two"}]
        (m 1))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == "one"
    end

    test "map with integer key and default" do
      source = ~S"""
      (let [m {0 "zero"}]
        (m 99 "not found"))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == "not found"
    end

    test "map as function in higher-order context with mapv" do
      # Note: Maps can't be passed directly to HOFs like mapv because Elixir's
      # Enum.map can't call them. Use keyword accessor syntax instead.
      source = ~S"""
      (let [lookup {:a 1 :b 2 :c 3}]
        (mapv #(lookup %) [:a :b :c]))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1, 2, 3]
    end

    test "map as function with filter" do
      source = ~S"""
      (let [valid-ids #{1 2 3}
            lookup {1 "one" 2 "two" 4 "four"}]
        (mapv #(lookup %) (filter valid-ids [1 2 3 4])))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == ["one", "two", nil]
    end

    test "nested map access using map-as-function" do
      source = ~S"""
      (let [users {:alice {:name "Alice" :age 30}
                   :bob {:name "Bob" :age 25}}
            alice (users :alice)]
        (alice :age))
      """

      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == 30
    end

    test "map from context used as function" do
      source = ~S"""
      (let [config data/config]
        (config :database))
      """

      ctx = %{config: %{database: "postgres", port: 5432}}
      {:ok, %Step{return: result}} = Lisp.run(source, context: ctx)
      assert result == "postgres"
    end
  end
end
