defmodule PtcRunner.Lisp.ClojureConformanceTest do
  @moduledoc """
  Clojure conformance tests.

  These tests verify that PTC-Lisp behaves identically to Clojure
  for pure functions in the standard library.

  Run with: mix test
  Skip with: mix test --exclude clojure
  """
  use ExUnit.Case, async: true
  import PtcRunner.TestSupport.ClojureTestHelpers

  setup_all do
    require_babashka()
    :ok
  end

  describe "Clojure conformance - arithmetic" do
    @describetag :clojure

    test "addition" do
      assert_clojure_equivalent("(+ 1 2)")
      assert_clojure_equivalent("(+ 1 2 3 4 5)")
      assert_clojure_equivalent("(+ 10)")
      assert_clojure_equivalent("(+)")
    end

    test "subtraction" do
      assert_clojure_equivalent("(- 10 3)")
      assert_clojure_equivalent("(- 10 3 2)")
      assert_clojure_equivalent("(- 5)")
    end

    test "multiplication" do
      assert_clojure_equivalent("(* 2 3)")
      assert_clojure_equivalent("(* 2 3 4)")
      assert_clojure_equivalent("(* 5)")
      assert_clojure_equivalent("(*)")
    end

    test "division" do
      assert_clojure_equivalent("(/ 10 2)")
      assert_clojure_equivalent("(/ 100 5 2)")
    end

    test "inc and dec" do
      assert_clojure_equivalent("(inc 5)")
      assert_clojure_equivalent("(dec 5)")
      assert_clojure_equivalent("(inc 0)")
      assert_clojure_equivalent("(dec 0)")
    end

    test "abs" do
      assert_clojure_equivalent("(abs 5)")
      assert_clojure_equivalent("(abs -5)")
      assert_clojure_equivalent("(abs 0)")
    end

    test "max and min" do
      assert_clojure_equivalent("(max 1 5 3)")
      assert_clojure_equivalent("(min 1 5 3)")
      assert_clojure_equivalent("(max 42)")
      assert_clojure_equivalent("(min 42)")
    end

    test "mod" do
      assert_clojure_equivalent("(mod 10 3)")
      assert_clojure_equivalent("(mod 15 5)")
      assert_clojure_equivalent("(mod 7 2)")
    end
  end

  describe "Clojure conformance - collections" do
    @describetag :clojure

    test "count" do
      assert_clojure_equivalent("(count [1 2 3])")
      assert_clojure_equivalent("(count [])")
      assert_clojure_equivalent("(count {:a 1 :b 2})")
    end

    test "first and last" do
      assert_clojure_equivalent("(first [1 2 3])")
      assert_clojure_equivalent("(last [1 2 3])")
      assert_clojure_equivalent("(first [])")
      assert_clojure_equivalent("(last [])")
    end

    test "take and drop" do
      assert_clojure_equivalent("(take 2 [1 2 3 4])")
      assert_clojure_equivalent("(drop 2 [1 2 3 4])")
      assert_clojure_equivalent("(take 10 [1 2 3])")
      assert_clojure_equivalent("(drop 10 [1 2 3])")
    end

    test "reverse" do
      assert_clojure_equivalent("(reverse [1 2 3])")
      assert_clojure_equivalent("(reverse [])")
    end

    test "sort" do
      assert_clojure_equivalent("(sort [3 1 2])")
      assert_clojure_equivalent("(sort [])")
    end

    test "distinct" do
      assert_clojure_equivalent("(distinct [1 2 1 3 2])")
      assert_clojure_equivalent("(distinct [])")
    end

    test "concat" do
      assert_clojure_equivalent("(concat [1 2] [3 4])")
      assert_clojure_equivalent("(concat [1] [2] [3])")
    end

    test "conj" do
      assert_clojure_equivalent("(conj [1 2] 3)")
      assert_clojure_equivalent("(conj [1] 2 3)")
      assert_clojure_equivalent("(conj \#{1 2} 3)")
      assert_clojure_equivalent("(conj {:a 1} [:b 2])")
      assert_clojure_equivalent("(conj nil 1)")
      assert_clojure_equivalent("(conj [1] nil)")
    end

    test "flatten" do
      assert_clojure_equivalent("(flatten [[1 2] [3 4]])")
      assert_clojure_equivalent("(flatten [1 [2 [3 4]]])")
    end

    test "nth" do
      assert_clojure_equivalent("(nth [1 2 3] 0)")
      assert_clojure_equivalent("(nth [1 2 3] 2)")
    end
  end

  describe "Clojure conformance - map operations" do
    @describetag :clojure

    test "get" do
      assert_clojure_equivalent("(get {:a 1 :b 2} :a)")
      assert_clojure_equivalent("(get {:a 1} :missing)")
      assert_clojure_equivalent("(get {:a 1} :missing :default)")
    end

    test "keys and vals" do
      # Note: order may differ, so we test sorted results
      assert_clojure_equivalent("(sort (keys {:a 1 :b 2}))")
      assert_clojure_equivalent("(sort (vals {:a 1 :b 2}))")
    end

    test "assoc" do
      assert_clojure_equivalent("(assoc {:a 1} :b 2)")
      assert_clojure_equivalent("(assoc {} :a 1)")
    end

    test "dissoc" do
      assert_clojure_equivalent("(dissoc {:a 1 :b 2} :b)")
      assert_clojure_equivalent("(dissoc {:a 1} :missing)")
    end

    test "merge" do
      assert_clojure_equivalent("(merge {:a 1} {:b 2})")
      assert_clojure_equivalent("(merge {:a 1} {:a 2})")
    end

    test "select-keys" do
      assert_clojure_equivalent("(select-keys {:a 1 :b 2 :c 3} [:a :c])")
    end
  end

  describe "Clojure conformance - logic" do
    @describetag :clojure

    test "and" do
      assert_clojure_equivalent("(and true true)")
      assert_clojure_equivalent("(and true false)")
      assert_clojure_equivalent("(and false true)")
      assert_clojure_equivalent("(and nil true)")
    end

    test "or" do
      assert_clojure_equivalent("(or false true)")
      assert_clojure_equivalent("(or false false)")
      assert_clojure_equivalent("(or nil false)")
    end

    test "not" do
      assert_clojure_equivalent("(not true)")
      assert_clojure_equivalent("(not false)")
      assert_clojure_equivalent("(not nil)")
    end
  end

  describe "Clojure conformance - predicates" do
    @describetag :clojure

    test "nil?" do
      assert_clojure_equivalent("(nil? nil)")
      assert_clojure_equivalent("(nil? false)")
      assert_clojure_equivalent("(nil? 0)")
    end

    test "some?" do
      assert_clojure_equivalent("(some? nil)")
      assert_clojure_equivalent("(some? false)")
      assert_clojure_equivalent("(some? 0)")
    end

    test "empty?" do
      assert_clojure_equivalent("(empty? [])")
      assert_clojure_equivalent("(empty? [1])")
      assert_clojure_equivalent("(empty? {})")
    end

    test "zero?" do
      assert_clojure_equivalent("(zero? 0)")
      assert_clojure_equivalent("(zero? 1)")
    end

    test "pos? and neg?" do
      assert_clojure_equivalent("(pos? 5)")
      assert_clojure_equivalent("(pos? -1)")
      assert_clojure_equivalent("(pos? 0)")
      assert_clojure_equivalent("(neg? -5)")
      assert_clojure_equivalent("(neg? 1)")
      assert_clojure_equivalent("(neg? 0)")
    end

    test "even? and odd?" do
      assert_clojure_equivalent("(even? 4)")
      assert_clojure_equivalent("(even? 3)")
      assert_clojure_equivalent("(odd? 3)")
      assert_clojure_equivalent("(odd? 4)")
    end
  end

  describe "Clojure conformance - higher-order functions" do
    @describetag :clojure

    test "map" do
      assert_clojure_equivalent("(map inc [1 2 3])")
      assert_clojure_equivalent("(map dec [1 2 3])")
    end

    test "filter" do
      assert_clojure_equivalent("(filter even? [1 2 3 4])")
      assert_clojure_equivalent("(filter odd? [1 2 3 4])")
    end

    test "remove" do
      assert_clojure_equivalent("(remove even? [1 2 3 4])")
      assert_clojure_equivalent("(remove odd? [1 2 3 4])")
    end

    test "reduce" do
      assert_clojure_equivalent("(reduce + [1 2 3])")
      assert_clojure_equivalent("(reduce + 10 [1 2 3])")
      assert_clojure_equivalent("(reduce * [1 2 3 4])")
      # Non-commutative operations verify correct argument order
      assert_clojure_equivalent("(reduce - [10 1 2 3])")
      assert_clojure_equivalent("(reduce - 10 [1 2 3])")
    end

    test "every?" do
      assert_clojure_equivalent("(every? even? [2 4 6])")
      assert_clojure_equivalent("(every? even? [2 3 4])")
      assert_clojure_equivalent("(every? even? [])")
    end

    test "some" do
      assert_clojure_equivalent("(some even? [1 2 3])")
      assert_clojure_equivalent("(some even? [1 3 5])")
    end
  end

  describe "Clojure conformance - control flow" do
    @describetag :clojure

    test "if" do
      assert_clojure_equivalent("(if true 1 2)")
      assert_clojure_equivalent("(if false 1 2)")
      assert_clojure_equivalent("(if nil 1 2)")
    end

    test "when" do
      assert_clojure_equivalent("(when true 42)")
      assert_clojure_equivalent("(when false 42)")
    end

    test "cond" do
      assert_clojure_equivalent("(cond false 1 true 2)")
      assert_clojure_equivalent("(cond false 1 false 2 :else 3)")
    end

    test "let" do
      assert_clojure_equivalent("(let [x 10] x)")
      assert_clojure_equivalent("(let [x 10 y 20] (+ x y))")
      assert_clojure_equivalent("(let [x 5 y (* x 2)] (+ x y))")
    end

    test "if-let" do
      assert_clojure_equivalent("(if-let [x 42] x 0)")
      assert_clojure_equivalent("(if-let [x nil] x 0)")
      assert_clojure_equivalent("(if-let [x false] x 0)")
    end

    test "when-let" do
      assert_clojure_equivalent("(when-let [x 42] x)")
      assert_clojure_equivalent("(when-let [x nil] x)")
      assert_clojure_equivalent("(when-let [x false] x)")
    end
  end

  describe "Clojure conformance - threading macros" do
    @describetag :clojure

    test "thread-last" do
      assert_clojure_equivalent("(->> [1 2 3] (map inc))")
      assert_clojure_equivalent("(->> [1 2 3 4] (filter even?) (map inc))")
      assert_clojure_equivalent("(->> [1 2 3] (reduce +))")
    end

    test "thread-first" do
      assert_clojure_equivalent("(-> {:a 1} (assoc :b 2))")
      assert_clojure_equivalent("(-> {:a {:b 1}} (get :a) (get :b))")
    end
  end
end
