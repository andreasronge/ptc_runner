defmodule PtcRunner.Lisp.IntegrationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "chained memory updates" do
    test "first call stores in memory" do
      source = "{:return 42, :step1 100}"
      {:ok, %{return: result1, memory_delta: _, memory: mem1}} = Lisp.run(source)
      assert result1 == 42
      assert mem1 == %{step1: 100}
    end

    test "second call uses persisted memory" do
      mem = %{previous: 50}
      source = "{:return memory/previous}"
      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source, memory: mem)
      assert result == 50
    end
  end

  describe "full E2E pipeline with threading and tool calls" do
    test "high-paid employees example exercises complete pipeline" do
      # Exercises: tool call, threading (->>) filter, where predicate with comparison,
      # let binding, map literal with pluck, and memory contract
      source = ~S"""
      (let [high-paid (->> (call "find-employees" {})
                           (filter (where :salary > 100000)))]
        {:return (pluck :email high-paid)
         :high-paid high-paid
         :count (count high-paid)})
      """

      tools = %{
        "find-employees" => fn _args ->
          [
            %{id: 1, name: "Alice", salary: 150_000, email: "alice@ex.com"},
            %{id: 2, name: "Bob", salary: 80_000, email: "bob@ex.com"}
          ]
        end
      }

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, tools: tools)

      # Memory contract: :return is extracted, rest goes to delta
      assert result == ["alice@ex.com"]

      assert delta == %{
               :"high-paid" => [%{id: 1, name: "Alice", salary: 150_000, email: "alice@ex.com"}],
               :count => 1
             }

      assert new_memory == %{
               :"high-paid" => [%{id: 1, name: "Alice", salary: 150_000, email: "alice@ex.com"}],
               :count => 1
             }
    end

    test "tool returning empty list is handled correctly" do
      # Tests behavior when filter produces empty list
      source = ~S"""
      (let [results (->> (call "search" {})
                         (filter (where :active = true)))]
        {:return (count results)
         :items results})
      """

      tools = %{
        "search" => fn _args ->
          [
            %{id: 1, name: "Alice", active: false},
            %{id: 2, name: "Bob", active: false}
          ]
        end
      }

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, tools: tools)

      assert result == 0
      assert delta == %{items: []}
      assert new_memory == %{items: []}
    end

    test "nested let bindings with multiple levels" do
      # Tests complex let binding scenarios
      source = ~S"""
      (let [x 10
            y 20
            z (+ x y)]
        {:return z
         :cached-x x
         :cached-y y})
      """

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} = Lisp.run(source)

      assert result == 30
      assert delta == %{:"cached-x" => 10, :"cached-y" => 20}
      assert new_memory == %{:"cached-x" => 10, :"cached-y" => 20}
    end

    test "where predicate safely handles nil field values" do
      # Tests that comparison with nil doesn't error and filters correctly
      source = ~S"""
      (let [filtered (->> ctx/items
                         (filter (where :age > 18)))]
        {:return (count filtered)
         :matches filtered})
      """

      ctx = %{
        items: [
          %{id: 1, name: "Alice", age: 25},
          %{id: 2, name: "Bob", age: nil},
          %{id: 3, name: "Carol", age: 30}
        ]
      }

      {:ok, %{return: result, memory_delta: delta, memory: new_memory}} =
        Lisp.run(source, context: ctx)

      # Only Alice and Carol match (age > 18), Bob's nil is safely filtered
      assert result == 2

      assert delta == %{
               matches: [
                 %{id: 1, name: "Alice", age: 25},
                 %{id: 3, name: "Carol", age: 30}
               ]
             }

      assert new_memory == delta
    end

    test "thread-first with assoc chains" do
      # Thread-first: value goes as first argument
      source = "(-> {:a 1} (assoc :b 2) (assoc :c 3))"
      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source)
      assert result == %{a: 1, b: 2, c: 3}
    end

    test "thread-last with multiple transformations" do
      # Thread-last: value goes as last argument
      source = ~S"""
      (->> (call "get-numbers" {})
           (filter (where :value > 1))
           first
           (:name))
      """

      tools = %{
        "get-numbers" => fn _args ->
          [
            %{name: "one", value: 1},
            %{name: "two", value: 2},
            %{name: "three", value: 3}
          ]
        end
      }

      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source, tools: tools)
      assert result == "two"
    end

    test "cond desugars to nested if correctly" do
      source = ~S"""
      (let [x ctx/x]
        (cond
          (> x 10) "big"
          (> x 5) "medium"
          :else "small"))
      """

      {:ok, %{return: result1, memory_delta: _, memory: _}} = Lisp.run(source, context: %{x: 15})
      assert result1 == "big"

      {:ok, %{return: result2, memory_delta: _, memory: _}} = Lisp.run(source, context: %{x: 7})
      assert result2 == "medium"

      {:ok, %{return: result3, memory_delta: _, memory: _}} = Lisp.run(source, context: %{x: 3})
      assert result3 == "small"
    end

    test "map destructuring in let bindings" do
      source = ~S"""
      (let [{:keys [name age]} ctx/user]
        {:name name
         :age age})
      """

      ctx = %{user: %{name: "Alice", age: 30}}
      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source, context: ctx)
      assert result == %{name: "Alice", age: 30}
    end

    test "underscore in vector destructuring skips positions" do
      assert {:ok, %{return: 2, memory_delta: _, memory: _}} = Lisp.run("(let [[_ b] [1 2]] b)")

      assert {:ok, %{return: 3, memory_delta: _, memory: _}} =
               Lisp.run("(let [[_ _ c] [1 2 3]] c)")
    end

    test "closure captures let-bound variable in filter" do
      source = ~S"""
      (let [threshold 100]
        {:return (filter (fn [x] (> (:price x) threshold)) ctx/products)
         :threshold threshold})
      """

      ctx = %{
        products: [
          %{name: "laptop", price: 1200},
          %{name: "mouse", price: 25},
          %{name: "keyboard", price: 150}
        ]
      }

      {:ok, %{return: result, memory_delta: delta, memory: _}} = Lisp.run(source, context: ctx)

      assert result == [
               %{name: "laptop", price: 1200},
               %{name: "keyboard", price: 150}
             ]

      assert delta == %{threshold: 100}
    end

    test "renaming bindings in fn destructuring works" do
      # This tests that renaming bindings {bind-name :key} now work
      # This is now a valid feature matching Clojure destructuring conventions
      source = ~S"""
      (map (fn [{item :id}] item) ctx/items)
      """

      ctx = %{items: [%{id: 1}, %{id: 2}]}

      # Should work and return the extracted values
      assert {:ok, %{return: [1, 2], memory_delta: %{}, memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "juxt enables multi-criteria sorting" do
      source = ~S"""
      (sort-by (juxt :priority :name) ctx/tasks)
      """

      ctx = %{
        tasks: [
          %{priority: 2, name: "Deploy"},
          %{priority: 1, name: "Test"},
          %{priority: 1, name: "Build"}
        ]
      }

      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source, context: ctx)

      # Should sort by priority first, then by name
      assert result == [
               %{priority: 1, name: "Build"},
               %{priority: 1, name: "Test"},
               %{priority: 2, name: "Deploy"}
             ]
    end

    test "juxt with map extracts multiple values" do
      source = "(map (juxt :x :y) ctx/points)"

      ctx = %{points: [%{x: 1, y: 2}, %{x: 3, y: 4}]}

      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source, context: ctx)
      assert result == [[1, 2], [3, 4]]
    end

    test "juxt with closures applies multiple transformations" do
      source = "((juxt #(+ % 1) #(* % 2)) 5)"

      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source)
      assert result == [6, 10]
    end

    test "juxt with builtin functions" do
      source = "((juxt first last) [1 2 3])"

      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source)
      assert result == [1, 3]
    end

    test "empty juxt returns empty vector" do
      source = "((juxt) {:a 1})"

      {:ok, %{return: result, memory_delta: _, memory: _}} = Lisp.run(source)
      assert result == []
    end
  end
end
