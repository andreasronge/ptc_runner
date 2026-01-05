defmodule PtcRunner.LispTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "basic execution" do
    test "evaluates simple expression" do
      assert {:ok, %{return: 3, memory_delta: %{}, memory: %{}}} = Lisp.run("(+ 1 2)")
    end

    test "propagates parser errors" do
      assert {:error, %{fail: %{reason: :parse_error}}} = Lisp.run("(invalid syntax!")
    end
  end

  describe "context access" do
    test "accesses context variables" do
      assert {:ok, %{return: 10, memory_delta: %{}, memory: %{}}} =
               Lisp.run("ctx/x", context: %{x: 10})
    end

    test "context access returns nil for missing keys" do
      assert {:ok, %{return: nil, memory_delta: %{}, memory: %{}}} = Lisp.run("ctx/missing")
    end
  end

  describe "basic arithmetic" do
    test "addition" do
      assert {:ok, %{return: 10, memory_delta: %{}, memory: %{}}} = Lisp.run("(+ 3 7)")
    end

    test "multiplication" do
      assert {:ok, %{return: 20, memory_delta: %{}, memory: %{}}} = Lisp.run("(* 4 5)")
    end

    test "division" do
      {:ok, %{return: result, memory_delta: %{}, memory: %{}}} = Lisp.run("(/ 10 2)")
      assert result == 5.0
    end
  end

  describe "if conditionals" do
    test "if with true condition" do
      assert {:ok, %{return: 1, memory_delta: %{}, memory: %{}}} = Lisp.run("(if true 1 2)")
    end

    test "if with false condition" do
      assert {:ok, %{return: 2, memory_delta: %{}, memory: %{}}} = Lisp.run("(if false 1 2)")
    end

    test "if with truthy value" do
      assert {:ok, %{return: 1, memory_delta: %{}, memory: %{}}} = Lisp.run("(if 42 1 2)")
    end

    test "if with nil (falsy)" do
      assert {:ok, %{return: 2, memory_delta: %{}, memory: %{}}} = Lisp.run("(if nil 1 2)")
    end
  end

  describe "logical operators" do
    test "or returns first truthy" do
      assert {:ok, %{return: 5, memory_delta: %{}, memory: %{}}} = Lisp.run("(or false nil 5)")
    end

    test "or with no truthy values" do
      assert {:ok, %{return: nil, memory_delta: %{}, memory: %{}}} = Lisp.run("(or false nil)")
    end

    test "and returns first falsy" do
      assert {:ok, %{return: false, memory_delta: %{}, memory: %{}}} =
               Lisp.run("(and true false)")
    end

    test "and with all truthy" do
      assert {:ok, %{return: true, memory_delta: %{}, memory: %{}}} = Lisp.run("(and true 2 3)")
    end
  end

  describe "let bindings" do
    test "simple let binding" do
      assert {:ok, %{return: 15, memory_delta: %{}, memory: %{}}} =
               Lisp.run("(let [x 10] (+ x 5))")
    end

    test "multiple let bindings" do
      assert {:ok, %{return: 30, memory_delta: %{}, memory: %{}}} =
               Lisp.run("(let [x 10 y 20] (+ x y))")
    end
  end

  describe "literals and types" do
    test "integer" do
      assert {:ok, %{return: 42, memory_delta: %{}, memory: %{}}} = Lisp.run("42")
    end

    test "string" do
      assert {:ok, %{return: "hello", memory_delta: %{}, memory: %{}}} = Lisp.run(~S/"hello"/)
    end

    test "keyword" do
      assert {:ok, %{return: :name, memory_delta: %{}, memory: %{}}} = Lisp.run(":name")
    end

    test "boolean true" do
      assert {:ok, %{return: true, memory_delta: %{}, memory: %{}}} = Lisp.run("true")
    end

    test "boolean false" do
      assert {:ok, %{return: false, memory_delta: %{}, memory: %{}}} = Lisp.run("false")
    end

    test "nil" do
      assert {:ok, %{return: nil, memory_delta: %{}, memory: %{}}} = Lisp.run("nil")
    end
  end

  describe "vectors" do
    test "empty vector" do
      assert {:ok, %{return: [], memory_delta: %{}, memory: %{}}} = Lisp.run("[]")
    end

    test "vector with numbers" do
      assert {:ok, %{return: [1, 2, 3], memory_delta: %{}, memory: %{}}} = Lisp.run("[1 2 3]")
    end

    test "vector with context access" do
      assert {:ok, %{return: [10, 20], memory_delta: %{}, memory: %{}}} =
               Lisp.run("[ctx/x ctx/y]", context: %{x: 10, y: 20})
    end
  end

  describe "maps" do
    test "empty map" do
      assert {:ok, %{return: %{}, memory_delta: %{}, memory: %{}}} = Lisp.run("{}")
    end

    test "map with keywords and numbers" do
      # V2: maps pass through, no implicit memory merge
      assert {:ok, %{return: %{a: 1, b: 2}, memory_delta: %{}, memory: %{}}} =
               Lisp.run("{:a 1 :b 2}")
    end

    test "map with context values" do
      assert {:ok, %{return: %{x: 10}, memory_delta: %{}, memory: %{}}} =
               Lisp.run("{:x ctx/x}", context: %{x: 10})
    end
  end

  describe "keyword as function" do
    test "extract key from map" do
      assert {:ok, %{return: "Alice", memory_delta: %{}, memory: %{}}} =
               Lisp.run("(:name ctx/user)", context: %{user: %{name: "Alice"}})
    end

    test "extract with default" do
      assert {:ok, %{return: "default", memory_delta: %{}, memory: %{}}} =
               Lisp.run("(:missing ctx/user \"default\")", context: %{user: %{}})
    end

    test "extract from nil" do
      assert {:ok, %{return: nil, memory_delta: %{}, memory: %{}}} = Lisp.run("(:key nil)")
    end
  end

  describe "where predicates" do
    test "equality predicate" do
      source = "(filter (where :status = \"active\") ctx/items)"
      ctx = %{items: [%{status: "active"}, %{status: "inactive"}]}

      assert {:ok, %{return: [%{status: "active"}], memory_delta: %{}, memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "greater than predicate" do
      source = "(filter (where :age > 18) ctx/items)"
      ctx = %{items: [%{age: 20}, %{age: 15}]}

      assert {:ok, %{return: [%{age: 20}], memory_delta: %{}, memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "truthy predicate" do
      source = "(filter (where :active) ctx/items)"
      ctx = %{items: [%{active: true}, %{active: false}, %{active: nil}]}

      assert {:ok, %{return: [%{active: true}], memory_delta: %{}, memory: %{}}} =
               Lisp.run(source, context: ctx)
    end
  end

  describe "predicate combinators" do
    test "all-of combines predicates" do
      source = "(filter (all-of (where :a = 1) (where :b = 2)) ctx/items)"
      ctx = %{items: [%{a: 1, b: 2}, %{a: 1, b: 3}, %{a: 2, b: 2}]}

      assert {:ok, %{return: [%{a: 1, b: 2}], memory_delta: %{}, memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "empty all-of is true" do
      source = "(filter (all-of) ctx/items)"
      ctx = %{items: [%{a: 1}, %{a: 2}]}

      assert {:ok, %{return: [%{a: 1}, %{a: 2}], memory_delta: %{}, memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "empty any-of is false" do
      source = "(filter (any-of) ctx/items)"
      ctx = %{items: [%{a: 1}, %{a: 2}]}
      assert {:ok, %{return: [], memory_delta: %{}, memory: %{}}} = Lisp.run(source, context: ctx)
    end
  end

  describe "collection operations" do
    test "count" do
      assert {:ok, %{return: 3, memory_delta: %{}, memory: %{}}} = Lisp.run("(count [1 2 3])")
    end

    test "first" do
      assert {:ok, %{return: 1, memory_delta: %{}, memory: %{}}} = Lisp.run("(first [1 2 3])")
    end

    test "second" do
      assert {:ok, %{return: 2, memory_delta: %{}, memory: %{}}} = Lisp.run("(second [1 2 3])")
    end

    test "last" do
      assert {:ok, %{return: 3, memory_delta: %{}, memory: %{}}} = Lisp.run("(last [1 2 3])")
    end

    test "sort" do
      assert {:ok, %{return: [1, 2, 3], memory_delta: %{}, memory: %{}}} =
               Lisp.run("(sort [3 1 2])")
    end
  end

  describe "comparison operators" do
    test "equals" do
      assert {:ok, %{return: true, memory_delta: %{}, memory: %{}}} = Lisp.run("(= 5 5)")
      assert {:ok, %{return: false, memory_delta: %{}, memory: %{}}} = Lisp.run("(= 5 6)")
    end

    test "greater than" do
      assert {:ok, %{return: true, memory_delta: %{}, memory: %{}}} = Lisp.run("(> 10 5)")
      assert {:ok, %{return: false, memory_delta: %{}, memory: %{}}} = Lisp.run("(> 5 10)")
    end

    test "less than" do
      assert {:ok, %{return: true, memory_delta: %{}, memory: %{}}} = Lisp.run("(< 5 10)")
      assert {:ok, %{return: false, memory_delta: %{}, memory: %{}}} = Lisp.run("(< 10 5)")
    end
  end

  describe "tool execution" do
    test "executes provided tools" do
      tools = %{"greet" => fn _args -> "hello" end}

      assert {:ok, %{return: "hello", memory_delta: %{}, memory: %{}}} =
               Lisp.run("(call \"greet\" {})", tools: tools)
    end

    @tag :capture_log
    test "returns error for unknown tool during execution" do
      # Unknown tool raises error in the sandbox process
      assert {:error, %{fail: _}} = Lisp.run("(call \"unknown\" {})")
    end
  end

  describe "closure creation" do
    test "creates and evaluates closure" do
      source = "((fn [x] (+ x 1)) 5)"
      assert {:ok, %{return: 6, memory_delta: %{}, memory: %{}}} = Lisp.run(source)
    end
  end

  describe "error propagation" do
    test "parser error is propagated" do
      assert {:error, %{fail: %{reason: :parse_error}}} = Lisp.run("(missing closing paren")
    end

    test "unbound variable error" do
      assert {:error, %{fail: %{reason: :unbound_var}}} = Lisp.run("undefined-var")
    end

    test "not callable error" do
      assert {:error, %{fail: %{reason: :not_callable}}} = Lisp.run("(42)")
    end
  end
end
