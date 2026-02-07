defmodule PtcRunner.LispTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "basic execution" do
    test "evaluates simple expression" do
      assert {:ok, %{return: 3, memory: %{}}} = Lisp.run("(+ 1 2)")
    end

    test "propagates parser errors" do
      assert {:error, %{fail: %{reason: :parse_error}}} = Lisp.run("(invalid syntax!")
    end
  end

  describe "context access" do
    test "accesses context variables" do
      assert {:ok, %{return: 10, memory: %{}}} =
               Lisp.run("data/x", context: %{x: 10})
    end

    test "context access returns nil for missing keys" do
      assert {:ok, %{return: nil, memory: %{}}} = Lisp.run("data/missing")
    end
  end

  describe "basic arithmetic" do
    test "addition" do
      assert {:ok, %{return: 10, memory: %{}}} = Lisp.run("(+ 3 7)")
    end

    test "multiplication" do
      assert {:ok, %{return: 20, memory: %{}}} = Lisp.run("(* 4 5)")
    end

    test "division" do
      {:ok, %{return: result, memory: %{}}} = Lisp.run("(/ 10 2)")
      assert result == 5.0
    end
  end

  describe "if conditionals" do
    test "if with true condition" do
      assert {:ok, %{return: 1, memory: %{}}} = Lisp.run("(if true 1 2)")
    end

    test "if with false condition" do
      assert {:ok, %{return: 2, memory: %{}}} = Lisp.run("(if false 1 2)")
    end

    test "if with truthy value" do
      assert {:ok, %{return: 1, memory: %{}}} = Lisp.run("(if 42 1 2)")
    end

    test "if with nil (falsy)" do
      assert {:ok, %{return: 2, memory: %{}}} = Lisp.run("(if nil 1 2)")
    end
  end

  describe "logical operators" do
    test "or returns first truthy" do
      assert {:ok, %{return: 5, memory: %{}}} = Lisp.run("(or false nil 5)")
    end

    test "or with no truthy values" do
      assert {:ok, %{return: nil, memory: %{}}} = Lisp.run("(or false nil)")
    end

    test "and returns first falsy" do
      assert {:ok, %{return: false, memory: %{}}} =
               Lisp.run("(and true false)")
    end

    test "and with all truthy" do
      assert {:ok, %{return: true, memory: %{}}} = Lisp.run("(and true 2 3)")
    end
  end

  describe "let bindings" do
    test "simple let binding" do
      assert {:ok, %{return: 15, memory: %{}}} =
               Lisp.run("(let [x 10] (+ x 5))")
    end

    test "multiple let bindings" do
      assert {:ok, %{return: 30, memory: %{}}} =
               Lisp.run("(let [x 10 y 20] (+ x y))")
    end
  end

  describe "literals and types" do
    test "integer" do
      assert {:ok, %{return: 42, memory: %{}}} = Lisp.run("42")
    end

    test "string" do
      assert {:ok, %{return: "hello", memory: %{}}} = Lisp.run(~S/"hello"/)
    end

    test "keyword" do
      assert {:ok, %{return: :name, memory: %{}}} = Lisp.run(":name")
    end

    test "boolean true" do
      assert {:ok, %{return: true, memory: %{}}} = Lisp.run("true")
    end

    test "boolean false" do
      assert {:ok, %{return: false, memory: %{}}} = Lisp.run("false")
    end

    test "nil" do
      assert {:ok, %{return: nil, memory: %{}}} = Lisp.run("nil")
    end
  end

  describe "vectors" do
    test "empty vector" do
      assert {:ok, %{return: [], memory: %{}}} = Lisp.run("[]")
    end

    test "vector with numbers" do
      assert {:ok, %{return: [1, 2, 3], memory: %{}}} = Lisp.run("[1 2 3]")
    end

    test "vector with context access" do
      assert {:ok, %{return: [10, 20], memory: %{}}} =
               Lisp.run("[data/x data/y]", context: %{x: 10, y: 20})
    end
  end

  describe "maps" do
    test "empty map" do
      assert {:ok, %{return: %{}, memory: %{}}} = Lisp.run("{}")
    end

    test "map with keywords and numbers" do
      # V2: maps pass through, no implicit memory merge
      assert {:ok, %{return: %{a: 1, b: 2}, memory: %{}}} =
               Lisp.run("{:a 1 :b 2}")
    end

    test "map with context values" do
      assert {:ok, %{return: %{x: 10}, memory: %{}}} =
               Lisp.run("{:x data/x}", context: %{x: 10})
    end
  end

  describe "keyword as function" do
    test "extract key from map" do
      assert {:ok, %{return: "Alice", memory: %{}}} =
               Lisp.run("(:name data/user)", context: %{user: %{name: "Alice"}})
    end

    test "extract with default" do
      assert {:ok, %{return: "default", memory: %{}}} =
               Lisp.run("(:missing data/user \"default\")", context: %{user: %{}})
    end

    test "extract from nil" do
      assert {:ok, %{return: nil, memory: %{}}} = Lisp.run("(:key nil)")
    end
  end

  describe "where predicates" do
    test "equality predicate" do
      source = "(filter (where :status = \"active\") data/items)"
      ctx = %{items: [%{status: "active"}, %{status: "inactive"}]}

      assert {:ok, %{return: [%{status: "active"}], memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "greater than predicate" do
      source = "(filter (where :age > 18) data/items)"
      ctx = %{items: [%{age: 20}, %{age: 15}]}

      assert {:ok, %{return: [%{age: 20}], memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "truthy predicate" do
      source = "(filter (where :active) data/items)"
      ctx = %{items: [%{active: true}, %{active: false}, %{active: nil}]}

      assert {:ok, %{return: [%{active: true}], memory: %{}}} =
               Lisp.run(source, context: ctx)
    end
  end

  describe "predicate combinators" do
    test "all-of combines predicates" do
      source = "(filter (all-of (where :a = 1) (where :b = 2)) data/items)"
      ctx = %{items: [%{a: 1, b: 2}, %{a: 1, b: 3}, %{a: 2, b: 2}]}

      assert {:ok, %{return: [%{a: 1, b: 2}], memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "empty all-of is true" do
      source = "(filter (all-of) data/items)"
      ctx = %{items: [%{a: 1}, %{a: 2}]}

      assert {:ok, %{return: [%{a: 1}, %{a: 2}], memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "empty any-of is false" do
      source = "(filter (any-of) data/items)"
      ctx = %{items: [%{a: 1}, %{a: 2}]}
      assert {:ok, %{return: [], memory: %{}}} = Lisp.run(source, context: ctx)
    end
  end

  describe "collection operations" do
    test "count" do
      assert {:ok, %{return: 3, memory: %{}}} = Lisp.run("(count [1 2 3])")
    end

    test "first" do
      assert {:ok, %{return: 1, memory: %{}}} = Lisp.run("(first [1 2 3])")
    end

    test "second" do
      assert {:ok, %{return: 2, memory: %{}}} = Lisp.run("(second [1 2 3])")
    end

    test "last" do
      assert {:ok, %{return: 3, memory: %{}}} = Lisp.run("(last [1 2 3])")
    end

    test "sort" do
      assert {:ok, %{return: [1, 2, 3], memory: %{}}} =
               Lisp.run("(sort [3 1 2])")
    end
  end

  describe "comparison operators" do
    test "equals" do
      assert {:ok, %{return: true, memory: %{}}} = Lisp.run("(= 5 5)")
      assert {:ok, %{return: false, memory: %{}}} = Lisp.run("(= 5 6)")
    end

    test "greater than" do
      assert {:ok, %{return: true, memory: %{}}} = Lisp.run("(> 10 5)")
      assert {:ok, %{return: false, memory: %{}}} = Lisp.run("(> 5 10)")
    end

    test "less than" do
      assert {:ok, %{return: true, memory: %{}}} = Lisp.run("(< 5 10)")
      assert {:ok, %{return: false, memory: %{}}} = Lisp.run("(< 10 5)")
    end
  end

  describe "tool execution" do
    test "executes provided tools" do
      tools = %{"greet" => fn _args -> "hello" end}

      assert {:ok, %{return: "hello", memory: %{}}} =
               Lisp.run("(tool/greet)", tools: tools)
    end

    test "gives helpful message for unknown tool" do
      tools = %{"greet" => fn _args -> "hello" end}

      assert {:error, %{fail: %{reason: :unknown_tool, message: msg}}} =
               Lisp.run("(tool/unknown)", tools: tools)

      assert msg =~ "Unknown tool: unknown"
      assert msg =~ "Available tools: greet"
    end

    test "handles tool execution failures" do
      tools = %{"kaboom" => fn _args -> {:error, "boom"} end}

      assert {:error, %{fail: %{reason: :tool_error, message: msg}}} =
               Lisp.run("(tool/kaboom)", tools: tools)

      assert msg =~ "Tool 'kaboom' failed: \"boom\""
    end

    test "gives helpful message for unknown tool with no tools" do
      assert {:error, %{fail: %{reason: :unknown_tool, message: msg}}} =
               Lisp.run("(tool/unknown)", tools: %{})

      assert msg =~ "No tools available"
    end

    test "catches unexpected tool exceptions" do
      tools = %{
        "kaboom" => fn _args -> raise ArgumentError, "unexpected error" end
      }

      assert {:error, %{fail: %{reason: :tool_error, message: msg}}} =
               Lisp.run("(tool/kaboom)", tools: tools)

      assert msg =~ "Tool 'kaboom' failed: \"unexpected error\""
    end
  end

  describe "closure creation" do
    test "creates and evaluates closure" do
      source = "((fn [x] (+ x 1)) 5)"
      assert {:ok, %{return: 6, memory: %{}}} = Lisp.run(source)
    end
  end

  describe "validate/1" do
    test "valid predicate with builtins" do
      assert :ok = Lisp.validate("(and (map? data/result) (> (count data/result) 0))")
    end

    test "predicate builtins are recognized" do
      for builtin <-
            ~w(boolean? number? string? nil? coll? empty? map? count first rest get get-in) do
        assert :ok = Lisp.validate("(#{builtin} data/result)"),
               "expected #{builtin} to be recognized as a builtin"
      end
    end

    test "undefined variable returns error" do
      assert {:error, ["foo"]} = Lisp.validate("(and (map? foo) true)")
    end

    test "parse error returns formatted message" do
      assert {:error, [msg]} = Lisp.validate("(unclosed paren")
      assert msg =~ "Parse error"
    end

    test "let-bound variables are not flagged" do
      assert :ok = Lisp.validate("(let [x 1] (> x 0))")
    end

    test "invalid arity caught by Analyze" do
      assert {:error, [msg]} = Lisp.validate("(if a b c d)")
      assert msg =~ "Analysis error"
    end

    test "data/ references are always valid" do
      assert :ok = Lisp.validate("(get data/result :key)")
    end

    test "fn params are scoped correctly" do
      assert :ok = Lisp.validate("(fn [x y] (+ x y))")
    end

    test "loop bindings are scoped correctly" do
      assert :ok = Lisp.validate("(loop [i 0] (if (>= i 10) i (recur (inc i))))")
    end

    test "map destructuring renames are scoped correctly" do
      assert :ok = Lisp.validate("(let [{x :id} data/result] (> x 0))")
    end

    test "def in do block scopes subsequent expressions" do
      assert :ok = Lisp.validate("(do (def x 1) x)")
    end

    test "recursive defn is not flagged as undefined" do
      assert :ok =
               Lisp.validate("(defn factorial [n] (if (= n 0) 1 (* n (factorial (dec n)))))")
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

    test "tool call with positional args returns invalid_tool_args error" do
      # Simulate what the LLM might generate: (tool/query "corpus") instead of (tool/query {:corpus "..."})
      tools = %{"query" => fn _args -> {:ok, %{}} end}

      assert {:error, %{fail: %{reason: :invalid_tool_args, message: msg}}} =
               Lisp.run(~S|(tool/query "some corpus")|, tools: tools)

      assert msg =~ "Tool calls require named arguments"
    end

    test "undefined vars rejected before tool side effects execute" do
      call_count = :counters.new(1, [:atomics])

      tools = %{
        "send-sms" => fn _args ->
          :counters.add(call_count, 1, 1)
          {:ok, "sent"}
        end
      }

      # Program has a tool call followed by an undefined variable
      source = ~S|(do (tool/send-sms {:to "+1234" :msg "hello"}) undefined-var)|

      assert {:error, %{fail: %{reason: :unbound_var}}} = Lisp.run(source, tools: tools)
      # Tool must NOT have been called — the program was rejected before execution
      assert :counters.get(call_count, 1) == 0
    end

    test "memory vars from previous turns are allowed" do
      # In multi-turn SubAgent, def'd vars from turn 1 are in memory for turn 2
      assert {:ok, %{return: 11}} =
               Lisp.run("(+ counter 1)", memory: %{counter: 10})
    end

    test "unknown tool rejected before side effects execute" do
      call_count = :counters.new(1, [:atomics])

      tools = %{
        "send-sms" => fn _args ->
          :counters.add(call_count, 1, 1)
          {:ok, "sent"}
        end
      }

      # Program calls a valid tool then a non-existent tool
      source = ~S|(do (tool/send-sms {:to "+1234" :msg "hi"}) (tool/non-existent {}))|

      assert {:error, %{fail: %{reason: :unknown_tool, message: msg}}} =
               Lisp.run(source, tools: tools)

      assert msg =~ "non-existent"
      assert msg =~ "Available tools: send-sms"
      # Valid tool must NOT have been called
      assert :counters.get(call_count, 1) == 0
    end

    test "unknown tool with no tools available" do
      source = ~S|(tool/query {:q "hello"})|

      assert {:error, %{fail: %{reason: :unknown_tool, message: msg}}} =
               Lisp.run(source, tools: %{})

      assert msg =~ "No tools available"
    end

    test "all tools valid allows execution" do
      tools = %{
        "greet" => fn _args -> "hello" end,
        "farewell" => fn _args -> "bye" end
      }

      source = ~S|(do (tool/greet {}) (tool/farewell {}))|
      assert {:ok, %{return: "bye"}} = Lisp.run(source, tools: tools)
    end
  end
end
