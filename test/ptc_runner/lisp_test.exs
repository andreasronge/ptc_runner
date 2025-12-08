defmodule PtcRunner.LispTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "basic execution" do
    test "evaluates simple expression" do
      assert {:ok, 3, %{}, %{}} = Lisp.run("(+ 1 2)")
    end

    test "propagates parser errors" do
      assert {:error, {:parse_error, _}} = Lisp.run("(invalid syntax!")
    end
  end

  describe "memory contract - non-map results" do
    test "non-map result leaves memory unchanged" do
      assert {:ok, 3, %{}, %{}} = Lisp.run("(+ 1 2)")
    end

    test "non-map result with context" do
      assert {:ok, 10, %{}, %{}} = Lisp.run("ctx/x", context: %{x: 10})
    end

    test "non-map result with initial memory" do
      initial_mem = %{stored: 42}
      assert {:ok, 5, %{}, ^initial_mem} = Lisp.run("(+ 2 3)", memory: initial_mem)
    end
  end

  describe "memory contract - map without :result key" do
    test "map without :result merges into memory and returns map" do
      source = "{:cached-count 3}"
      {:ok, result, delta, new_memory} = Lisp.run(source)

      assert result == %{:"cached-count" => 3}
      assert delta == %{:"cached-count" => 3}
      assert new_memory == %{:"cached-count" => 3}
    end

    test "map merge preserves existing memory keys" do
      initial_memory = %{x: 10}
      source = "{:y 20}"
      {:ok, result, delta, new_memory} = Lisp.run(source, memory: initial_memory)

      assert result == %{y: 20}
      assert delta == %{y: 20}
      assert new_memory == %{x: 10, y: 20}
    end

    test "map update overwrites memory keys" do
      initial_memory = %{counter: 5}
      source = "{:counter 10}"
      {:ok, result, delta, new_memory} = Lisp.run(source, memory: initial_memory)

      assert result == %{counter: 10}
      assert delta == %{counter: 10}
      assert new_memory == %{counter: 10}
    end

    test "empty map merges with memory but returns empty map" do
      initial_memory = %{x: 10}
      source = "{}"
      {:ok, result, delta, new_memory} = Lisp.run(source, memory: initial_memory)

      assert result == %{}
      assert delta == %{}
      assert new_memory == %{x: 10}
    end
  end

  describe "memory contract - map with :result key" do
    test "map with :result extracts return value" do
      source = "{:result 42, :stored 100}"
      {:ok, result, delta, new_memory} = Lisp.run(source)

      assert result == 42
      assert delta == %{stored: 100}
      assert new_memory == %{stored: 100}
    end

    test "map with :result key and multiple updates" do
      source = "{:result \"done\", :count 5, :status \"ok\"}"
      {:ok, result, delta, new_memory} = Lisp.run(source)

      assert result == "done"
      assert delta == %{count: 5, status: "ok"}
      assert new_memory == %{count: 5, status: "ok"}
    end

    test "map with only :result key" do
      source = "{:result \"return-value\"}"
      {:ok, result, delta, new_memory} = Lisp.run(source)

      assert result == "return-value"
      assert delta == %{}
      assert new_memory == %{}
    end

    test "map with :result merges with initial memory" do
      initial_memory = %{x: 10}
      source = "{:result \"ok\", :y 20}"
      {:ok, result, delta, new_memory} = Lisp.run(source, memory: initial_memory)

      assert result == "ok"
      assert delta == %{y: 20}
      assert new_memory == %{x: 10, y: 20}
    end

    test "map with :result key set to nil returns nil" do
      source = "{:result nil, :stored 100}"
      {:ok, result, delta, new_memory} = Lisp.run(source)

      assert result == nil
      assert delta == %{stored: 100}
      assert new_memory == %{stored: 100}
    end
  end

  describe "context and memory access" do
    test "accesses context variables" do
      assert {:ok, 10, %{}, %{}} = Lisp.run("ctx/x", context: %{x: 10})
    end

    test "accesses memory variables" do
      assert {:ok, 5, %{}, %{}} = Lisp.run("memory/value", memory: %{value: 5})
    end

    test "memory access returns nil for missing keys" do
      assert {:ok, nil, %{}, %{}} = Lisp.run("memory/missing")
    end

    test "context access returns nil for missing keys" do
      assert {:ok, nil, %{}, %{}} = Lisp.run("ctx/missing")
    end
  end

  describe "basic arithmetic" do
    test "addition" do
      assert {:ok, 10, %{}, %{}} = Lisp.run("(+ 3 7)")
    end

    test "multiplication" do
      assert {:ok, 20, %{}, %{}} = Lisp.run("(* 4 5)")
    end

    test "division" do
      {:ok, result, %{}, %{}} = Lisp.run("(/ 10 2)")
      assert result == 5.0
    end
  end

  describe "if conditionals" do
    test "if with true condition" do
      assert {:ok, 1, %{}, %{}} = Lisp.run("(if true 1 2)")
    end

    test "if with false condition" do
      assert {:ok, 2, %{}, %{}} = Lisp.run("(if false 1 2)")
    end

    test "if with truthy value" do
      assert {:ok, 1, %{}, %{}} = Lisp.run("(if 42 1 2)")
    end

    test "if with nil (falsy)" do
      assert {:ok, 2, %{}, %{}} = Lisp.run("(if nil 1 2)")
    end
  end

  describe "logical operators" do
    test "or returns first truthy" do
      assert {:ok, 5, %{}, %{}} = Lisp.run("(or false nil 5)")
    end

    test "or with no truthy values" do
      assert {:ok, nil, %{}, %{}} = Lisp.run("(or false nil)")
    end

    test "and returns first falsy" do
      assert {:ok, false, %{}, %{}} = Lisp.run("(and true false)")
    end

    test "and with all truthy" do
      assert {:ok, true, %{}, %{}} = Lisp.run("(and true 2 3)")
    end
  end

  describe "let bindings" do
    test "simple let binding" do
      assert {:ok, 15, %{}, %{}} = Lisp.run("(let [x 10] (+ x 5))")
    end

    test "multiple let bindings" do
      assert {:ok, 30, %{}, %{}} = Lisp.run("(let [x 10 y 20] (+ x y))")
    end
  end

  describe "literals and types" do
    test "integer" do
      assert {:ok, 42, %{}, %{}} = Lisp.run("42")
    end

    test "string" do
      assert {:ok, "hello", %{}, %{}} = Lisp.run(~S/"hello"/)
    end

    test "keyword" do
      assert {:ok, :name, %{}, %{}} = Lisp.run(":name")
    end

    test "boolean true" do
      assert {:ok, true, %{}, %{}} = Lisp.run("true")
    end

    test "boolean false" do
      assert {:ok, false, %{}, %{}} = Lisp.run("false")
    end

    test "nil" do
      assert {:ok, nil, %{}, %{}} = Lisp.run("nil")
    end
  end

  describe "vectors" do
    test "empty vector" do
      assert {:ok, [], %{}, %{}} = Lisp.run("[]")
    end

    test "vector with numbers" do
      assert {:ok, [1, 2, 3], %{}, %{}} = Lisp.run("[1 2 3]")
    end

    test "vector with context access" do
      assert {:ok, [10, 20], %{}, %{}} = Lisp.run("[ctx/x ctx/y]", context: %{x: 10, y: 20})
    end
  end

  describe "maps" do
    test "empty map" do
      assert {:ok, %{}, %{}, %{}} = Lisp.run("{}")
    end

    test "map with keywords and numbers" do
      assert {:ok, %{a: 1, b: 2}, %{}, %{}} = Lisp.run("{:a 1 :b 2}")
    end

    test "map with context values" do
      assert {:ok, %{x: 10}, %{}, %{}} = Lisp.run("{:x ctx/x}", context: %{x: 10})
    end
  end

  describe "keyword as function" do
    test "extract key from map" do
      assert {:ok, "Alice", %{}, %{}} =
               Lisp.run("(:name ctx/user)", context: %{user: %{name: "Alice"}})
    end

    test "extract with default" do
      assert {:ok, "default", %{}, %{}} =
               Lisp.run("(:missing ctx/user \"default\")", context: %{user: %{}})
    end

    test "extract from nil" do
      assert {:ok, nil, %{}, %{}} = Lisp.run("(:key nil)")
    end
  end

  describe "where predicates" do
    test "equality predicate" do
      source = "(filter (where :status = \"active\") ctx/items)"
      ctx = %{items: [%{status: "active"}, %{status: "inactive"}]}
      assert {:ok, [%{status: "active"}], %{}, %{}} = Lisp.run(source, context: ctx)
    end

    test "greater than predicate" do
      source = "(filter (where :age > 18) ctx/items)"
      ctx = %{items: [%{age: 20}, %{age: 15}]}
      assert {:ok, [%{age: 20}], %{}, %{}} = Lisp.run(source, context: ctx)
    end

    test "truthy predicate" do
      source = "(filter (where :active) ctx/items)"
      ctx = %{items: [%{active: true}, %{active: false}, %{active: nil}]}
      assert {:ok, [%{active: true}], %{}, %{}} = Lisp.run(source, context: ctx)
    end
  end

  describe "predicate combinators" do
    test "all-of combines predicates" do
      source = "(filter (all-of (where :a = 1) (where :b = 2)) ctx/items)"
      ctx = %{items: [%{a: 1, b: 2}, %{a: 1, b: 3}, %{a: 2, b: 2}]}
      assert {:ok, [%{a: 1, b: 2}], %{}, %{}} = Lisp.run(source, context: ctx)
    end

    test "empty all-of is true" do
      source = "(filter (all-of) ctx/items)"
      ctx = %{items: [%{a: 1}, %{a: 2}]}
      assert {:ok, [%{a: 1}, %{a: 2}], %{}, %{}} = Lisp.run(source, context: ctx)
    end

    test "empty any-of is false" do
      source = "(filter (any-of) ctx/items)"
      ctx = %{items: [%{a: 1}, %{a: 2}]}
      assert {:ok, [], %{}, %{}} = Lisp.run(source, context: ctx)
    end
  end

  describe "collection operations" do
    test "count" do
      assert {:ok, 3, %{}, %{}} = Lisp.run("(count [1 2 3])")
    end

    test "first" do
      assert {:ok, 1, %{}, %{}} = Lisp.run("(first [1 2 3])")
    end

    test "last" do
      assert {:ok, 3, %{}, %{}} = Lisp.run("(last [1 2 3])")
    end

    test "sort" do
      assert {:ok, [1, 2, 3], %{}, %{}} = Lisp.run("(sort [3 1 2])")
    end
  end

  describe "comparison operators" do
    test "equals" do
      assert {:ok, true, %{}, %{}} = Lisp.run("(= 5 5)")
      assert {:ok, false, %{}, %{}} = Lisp.run("(= 5 6)")
    end

    test "greater than" do
      assert {:ok, true, %{}, %{}} = Lisp.run("(> 10 5)")
      assert {:ok, false, %{}, %{}} = Lisp.run("(> 5 10)")
    end

    test "less than" do
      assert {:ok, true, %{}, %{}} = Lisp.run("(< 5 10)")
      assert {:ok, false, %{}, %{}} = Lisp.run("(< 10 5)")
    end
  end

  describe "tool execution" do
    test "executes provided tools" do
      tools = %{"greet" => fn _args -> "hello" end}
      assert {:ok, "hello", %{}, %{}} = Lisp.run("(call \"greet\" {})", tools: tools)
    end

    test "raises on unknown tool during execution" do
      # Tool executor raises RuntimeError for unknown tools
      catch_error(Lisp.run("(call \"unknown\" {})"))
    end
  end

  describe "closure creation" do
    test "creates and evaluates closure" do
      source = "((fn [x] (+ x 1)) 5)"
      assert {:ok, 6, %{}, %{}} = Lisp.run(source)
    end
  end

  describe "error propagation" do
    test "parser error is propagated" do
      assert {:error, {:parse_error, _}} = Lisp.run("(missing closing paren")
    end

    test "unbound variable error" do
      assert {:error, {:unbound_var, :"undefined-var"}} = Lisp.run("undefined-var")
    end

    test "not callable error" do
      assert {:error, {:not_callable, 42}} = Lisp.run("(42)")
    end
  end

  describe "integration - chained memory updates" do
    test "first call stores in memory" do
      source = "{:result 42, :step1 100}"
      {:ok, result1, _, mem1} = Lisp.run(source)
      assert result1 == 42
      assert mem1 == %{step1: 100}
    end

    test "second call uses persisted memory" do
      mem = %{previous: 50}
      source = "{:result memory/previous}"
      {:ok, result, _, _} = Lisp.run(source, memory: mem)
      assert result == 50
    end
  end

  describe "integration - full E2E pipeline with threading and tool calls" do
    test "high-paid employees example exercises complete pipeline" do
      # Exercises: tool call, threading (->>) filter, where predicate with comparison,
      # let binding, map literal with pluck, and memory contract
      source = ~S"""
      (let [high-paid (->> (call "find-employees" {})
                           (filter (where :salary > 100000)))]
        {:result (pluck :email high-paid)
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

      {:ok, result, delta, new_memory} = Lisp.run(source, tools: tools)

      # Memory contract: :result is extracted, rest goes to delta
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
        {:result (count results)
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

      {:ok, result, delta, new_memory} = Lisp.run(source, tools: tools)

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
        {:result z
         :cached-x x
         :cached-y y})
      """

      {:ok, result, delta, new_memory} = Lisp.run(source)

      assert result == 30
      assert delta == %{:"cached-x" => 10, :"cached-y" => 20}
      assert new_memory == %{:"cached-x" => 10, :"cached-y" => 20}
    end

    test "where predicate safely handles nil field values" do
      # Tests that comparison with nil doesn't error and filters correctly
      source = ~S"""
      (let [filtered (->> ctx/items
                         (filter (where :age > 18)))]
        {:result (count filtered)
         :matches filtered})
      """

      ctx = %{
        items: [
          %{id: 1, name: "Alice", age: 25},
          %{id: 2, name: "Bob", age: nil},
          %{id: 3, name: "Carol", age: 30}
        ]
      }

      {:ok, result, delta, new_memory} = Lisp.run(source, context: ctx)

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
  end
end
