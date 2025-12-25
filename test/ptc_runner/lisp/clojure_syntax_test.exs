defmodule PtcRunner.Lisp.ClojureSyntaxTest do
  @moduledoc """
  Clojure syntax validation tests.

  These tests verify that PTC-Lisp programs are valid Clojure syntax.
  This ensures LLM-generated code can be validated against real Clojure.

  Run with: mix test
  Skip with: mix test --exclude clojure
  """
  use ExUnit.Case, async: true
  import PtcRunner.TestSupport.ClojureTestHelpers

  setup_all do
    require_babashka()
    :ok
  end

  describe "Clojure syntax validation - threading macros" do
    @describetag :clojure

    test "thread-last pipeline is valid Clojure" do
      assert_valid_clojure_syntax("(->> [1 2 3] (map inc) (filter even?))")
    end

    test "thread-last with multiple steps is valid Clojure" do
      assert_valid_clojure_syntax("""
      (->> products
           (filter (fn [p] (> (:price p) 100)))
           (map :name)
           (sort))
      """)
    end

    test "thread-first is valid Clojure" do
      assert_valid_clojure_syntax("(-> {:a 1} (assoc :b 2) (dissoc :a))")
    end
  end

  describe "Clojure syntax validation - let bindings" do
    @describetag :clojure

    test "simple let binding is valid Clojure" do
      assert_valid_clojure_syntax("(let [x 10] x)")
    end

    test "multiple let bindings is valid Clojure" do
      assert_valid_clojure_syntax("(let [x 10 y 20 z (+ x y)] (* z 2))")
    end

    test "let with destructuring is valid Clojure" do
      assert_valid_clojure_syntax("""
      (let [{:keys [name age]} {:name "Alice" :age 30}]
        name)
      """)
    end

    test "let with nested destructuring is valid Clojure" do
      assert_valid_clojure_syntax("""
      (let [{:keys [name] :or {name "Unknown"}} {}]
        name)
      """)
    end
  end

  describe "Clojure syntax validation - anonymous functions" do
    @describetag :clojure

    test "fn with single parameter is valid Clojure" do
      assert_valid_clojure_syntax("(fn [x] (* x 2))")
    end

    test "fn with multiple parameters is valid Clojure" do
      assert_valid_clojure_syntax("(fn [x y] (+ x y))")
    end

    test "fn with destructuring is valid Clojure" do
      assert_valid_clojure_syntax("(fn [{:keys [name age]}] name)")
    end
  end

  describe "Clojure syntax validation - control flow" do
    @describetag :clojure

    test "if expression is valid Clojure" do
      assert_valid_clojure_syntax(~S/(if (> x 10) "big" "small")/)
    end

    test "when expression is valid Clojure" do
      assert_valid_clojure_syntax("(when (> x 10) (inc x))")
    end

    test "cond expression is valid Clojure" do
      assert_valid_clojure_syntax("""
      (cond
        (< x 0) "negative"
        (= x 0) "zero"
        :else "positive")
      """)
    end
  end

  describe "Clojure syntax validation - collections" do
    @describetag :clojure

    test "vector literal is valid Clojure" do
      assert_valid_clojure_syntax("[1 2 3 4 5]")
    end

    test "map literal is valid Clojure" do
      assert_valid_clojure_syntax("{:name \"Alice\" :age 30}")
    end

    test "set literal is valid Clojure" do
      # Use sigil to avoid Elixir interpolation conflict with Clojure set syntax
      assert_valid_clojure_syntax(~S"#{1 2 3}")
    end

    test "nested collections are valid Clojure" do
      assert_valid_clojure_syntax(~S/{:users [{:name "A"} {:name "B"}]}/)
    end
  end

  describe "Clojure syntax validation - complex programs" do
    @describetag :clojure

    test "data transformation pipeline is valid Clojure" do
      assert_valid_clojure_syntax("""
      (let [active-users (->> users
                              (filter (fn [u] (:active u)))
                              (sort-by :name))]
        {:count (count active-users)
         :names (map :name active-users)})
      """)
    end

    test "aggregation with group-by is valid Clojure" do
      assert_valid_clojure_syntax("""
      (->> orders
           (group-by :status)
           (map (fn [[status items]]
                  [status (count items)]))
           (into {}))
      """)
    end
  end
end
