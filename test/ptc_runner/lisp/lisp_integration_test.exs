defmodule PtcRunner.Lisp.IntegrationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "explicit storage via def" do
    test "def stores value in user_ns, accessible in same expression" do
      source = "(do (def step1 100) step1)"
      {:ok, %{return: result, memory: %{}}} = Lisp.run(source)
      assert result == 100
    end

    test "memory values become available as user_ns symbols" do
      # Previous memory values become available in user_ns during evaluation.
      mem = %{previous: 50}
      source = "previous"
      {:ok, %{return: result, memory: _}} = Lisp.run(source, memory: mem)
      assert result == 50
    end
  end

  describe "full E2E pipeline with threading and tool calls" do
    test "high-paid employees example exercises complete pipeline" do
      # Exercises: tool call, threading (->>) filter, where predicate with comparison,
      # let binding, map literal with pluck
      # V2: just returns the map, no implicit memory merge
      source = ~S"""
      (let [high-paid (->> (tool/find-employees {})
                           (filter (where :salary > 100000)))]
        {:emails (pluck :email high-paid)
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

      {:ok, %{return: result, memory: new_memory}} =
        Lisp.run(source, tools: tools)

      # V2: Map returns as-is, no implicit memory merge
      assert result == %{
               :"high-paid" => [%{id: 1, name: "Alice", salary: 150_000, email: "alice@ex.com"}],
               emails: ["alice@ex.com"],
               count: 1
             }

      assert new_memory == %{}
    end

    test "tool returning empty list is handled correctly" do
      # Tests behavior when filter produces empty list
      # V2: returns count directly, no implicit memory
      source = ~S"""
      (let [results (->> (tool/search {})
                         (filter (where :active = true)))]
        (count results))
      """

      tools = %{
        "search" => fn _args ->
          [
            %{id: 1, name: "Alice", active: false},
            %{id: 2, name: "Bob", active: false}
          ]
        end
      }

      {:ok, %{return: result, memory: new_memory}} =
        Lisp.run(source, tools: tools)

      assert result == 0
      assert new_memory == %{}
    end

    test "nested let bindings with multiple levels" do
      # Tests complex let binding scenarios
      # V2: returns map directly, no implicit memory
      source = ~S"""
      (let [x 10
            y 20
            z (+ x y)]
        {:result z
         :cached-x x
         :cached-y y})
      """

      {:ok, %{return: result, memory: new_memory}} = Lisp.run(source)

      assert result == %{:"cached-x" => 10, :"cached-y" => 20, result: 30}
      assert new_memory == %{}
    end

    test "where predicate safely handles nil field values" do
      # Tests that comparison with nil doesn't error and filters correctly
      # V2: returns count directly, no implicit memory
      source = ~S"""
      (let [filtered (->> data/items
                         (filter (where :age > 18)))]
        (count filtered))
      """

      ctx = %{
        items: [
          %{id: 1, name: "Alice", age: 25},
          %{id: 2, name: "Bob", age: nil},
          %{id: 3, name: "Carol", age: 30}
        ]
      }

      {:ok, %{return: result, memory: new_memory}} =
        Lisp.run(source, context: ctx)

      # Only Alice and Carol match (age > 18), Bob's nil is safely filtered
      assert result == 2
      assert new_memory == %{}
    end

    test "thread-first with assoc chains" do
      # Thread-first: value goes as first argument
      source = "(-> {:a 1} (assoc :b 2) (assoc :c 3))"
      {:ok, %{return: result, memory: _}} = Lisp.run(source)
      assert result == %{a: 1, b: 2, c: 3}
    end

    test "thread-last with multiple transformations" do
      # Thread-last: value goes as last argument
      source = ~S"""
      (->> (tool/get-numbers {})
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

      {:ok, %{return: result, memory: _}} = Lisp.run(source, tools: tools)
      assert result == "two"
    end

    test "cond desugars to nested if correctly" do
      source = ~S"""
      (let [x data/x]
        (cond
          (> x 10) "big"
          (> x 5) "medium"
          :else "small"))
      """

      {:ok, %{return: result1, memory: _}} = Lisp.run(source, context: %{x: 15})
      assert result1 == "big"

      {:ok, %{return: result2, memory: _}} = Lisp.run(source, context: %{x: 7})
      assert result2 == "medium"

      {:ok, %{return: result3, memory: _}} = Lisp.run(source, context: %{x: 3})
      assert result3 == "small"
    end

    test "map destructuring in let bindings" do
      source = ~S"""
      (let [{:keys [name age]} data/user]
        {:name name
         :age age})
      """

      ctx = %{user: %{name: "Alice", age: 30}}
      {:ok, %{return: result, memory: _}} = Lisp.run(source, context: ctx)
      assert result == %{name: "Alice", age: 30}
    end

    test "underscore in vector destructuring skips positions" do
      assert {:ok, %{return: 2, memory: _}} = Lisp.run("(let [[_ b] [1 2]] b)")

      assert {:ok, %{return: 3, memory: _}} =
               Lisp.run("(let [[_ _ c] [1 2 3]] c)")
    end

    test "closure captures let-bound variable in filter" do
      # V2: no :return special handling, just return filtered list directly
      source = ~S"""
      (let [threshold 100]
        (filter (fn [x] (> (:price x) threshold)) data/products))
      """

      ctx = %{
        products: [
          %{name: "laptop", price: 1200},
          %{name: "mouse", price: 25},
          %{name: "keyboard", price: 150}
        ]
      }

      {:ok, %{return: result, memory: _}} = Lisp.run(source, context: ctx)

      assert result == [
               %{name: "laptop", price: 1200},
               %{name: "keyboard", price: 150}
             ]
    end

    test "renaming bindings in fn destructuring works" do
      # This tests that renaming bindings {bind-name :key} now work
      # This is now a valid feature matching Clojure destructuring conventions
      source = ~S"""
      (map (fn [{item :id}] item) data/items)
      """

      ctx = %{items: [%{id: 1}, %{id: 2}]}

      # Should work and return the extracted values
      assert {:ok, %{return: [1, 2], memory: %{}}} =
               Lisp.run(source, context: ctx)
    end

    test "juxt enables multi-criteria sorting" do
      source = ~S"""
      (sort-by (juxt :priority :name) data/tasks)
      """

      ctx = %{
        tasks: [
          %{priority: 2, name: "Deploy"},
          %{priority: 1, name: "Test"},
          %{priority: 1, name: "Build"}
        ]
      }

      {:ok, %{return: result, memory: _}} = Lisp.run(source, context: ctx)

      # Should sort by priority first, then by name
      assert result == [
               %{priority: 1, name: "Build"},
               %{priority: 1, name: "Test"},
               %{priority: 2, name: "Deploy"}
             ]
    end

    test "juxt with map extracts multiple values" do
      source = "(map (juxt :x :y) data/points)"

      ctx = %{points: [%{x: 1, y: 2}, %{x: 3, y: 4}]}

      {:ok, %{return: result, memory: _}} = Lisp.run(source, context: ctx)
      assert result == [[1, 2], [3, 4]]
    end

    test "juxt with closures applies multiple transformations" do
      source = "((juxt #(+ % 1) #(* % 2)) 5)"

      {:ok, %{return: result, memory: _}} = Lisp.run(source)
      assert result == [6, 10]
    end

    test "juxt with builtin functions" do
      source = "((juxt first last) [1 2 3])"

      {:ok, %{return: result, memory: _}} = Lisp.run(source)
      assert result == [1, 3]
    end

    test "empty juxt returns empty vector" do
      source = "((juxt) {:a 1})"

      {:ok, %{return: result, memory: _}} = Lisp.run(source)
      assert result == []
    end
  end

  describe "Clojure namespace compatibility" do
    test "clojure.string/join works end-to-end" do
      source = ~S|(clojure.string/join "," ["a" "b" "c"])|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == "a,b,c"
    end

    test "str/split works end-to-end" do
      source = ~S|(str/split "a,b,c" ",")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["a", "b", "c"]
    end

    test "core/map works end-to-end" do
      source = "(core/map inc [1 2 3])"
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [2, 3, 4]
    end

    test "Clojure namespaces work in threading" do
      source = ~S|(->> ["a" "b"] (str/join "-"))|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == "a-b"
    end

    test "unknown function in known namespace gives helpful error" do
      source = ~S|(clojure.string/capitalize "hello")|
      {:error, %{fail: %{message: msg}}} = Lisp.run(source)
      assert msg =~ "capitalize is not available"
      assert msg =~ "String functions:"
    end
  end

  describe "map-indexed integration" do
    test "map-indexed basic functionality" do
      assert {:ok, %{return: [[0, "a"], [1, "b"]]}} =
               Lisp.run(~S|(map-indexed (fn [i x] [i x]) ["a" "b"])|)
    end

    test "map-indexed with string" do
      assert {:ok, %{return: [[0, "a"], [1, "b"]]}} =
               Lisp.run(~S|(map-indexed (fn [i x] [i x]) "ab")|)
    end

    test "map-indexed with map" do
      {:ok, %{return: result}} = Lisp.run(~S|(map-indexed (fn [i x] [i x]) {:a 1 :b 2})|)
      assert length(result) == 2
      # Order is arbitrary but structure should be [index, [key, value]]
      assert Enum.any?(result, fn [i, x] -> i in [0, 1] and x in [[:a, 1], [:b, 2]] end)
    end
  end

  describe "character literals and string-as-sequence" do
    test "filter characters in string - the main use case" do
      source = ~S|(count (filter #(= \r %) "raspberry"))|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 3
    end

    test "character literal equals single-char string" do
      {:ok, %{return: true}} = Lisp.run(~S|(= \r "r")|)
      {:ok, %{return: true}} = Lisp.run(~S|(= \newline "\n")|)
      {:ok, %{return: true}} = Lisp.run(~S|(= \space " ")|)
      {:ok, %{return: true}} = Lisp.run(~S|(= \tab "\t")|)
    end

    test "char? predicate returns true for single characters" do
      {:ok, %{return: true}} = Lisp.run(~S|(char? \a)|)
      {:ok, %{return: true}} = Lisp.run(~S|(char? \newline)|)
      {:ok, %{return: true}} = Lisp.run(~S|(char? "x")|)
    end

    test "char? predicate returns false for multi-char strings" do
      {:ok, %{return: false}} = Lisp.run(~S|(char? "ab")|)
      {:ok, %{return: false}} = Lisp.run(~S|(char? "hello")|)
    end

    test "char? predicate returns false for empty string" do
      {:ok, %{return: false}} = Lisp.run(~S|(char? "")|)
    end

    test "char? handles Unicode characters" do
      {:ok, %{return: true}} = Lisp.run(~S|(char? \λ)|)
      {:ok, %{return: true}} = Lisp.run(~S|(char? (first "👍"))|)
    end

    test "first/last/nth work on strings" do
      {:ok, %{return: "h"}} = Lisp.run(~S|(first "hello")|)
      {:ok, %{return: "o"}} = Lisp.run(~S|(last "hello")|)
      {:ok, %{return: "l"}} = Lisp.run(~S|(nth "hello" 2)|)
    end

    test "first on empty string returns nil" do
      {:ok, %{return: nil}} = Lisp.run(~S|(first "")|)
    end

    test "map on string returns list of characters" do
      {:ok, %{return: ["a", "b", "c"]}} = Lisp.run(~S|(map identity "abc")|)
    end

    test "filter on string returns matching characters" do
      {:ok, %{return: ["e", "o"]}} =
        Lisp.run(~S|(filter #(contains? #{"a" "e" "i" "o" "u"} %) "hello")|)
    end

    test "take/drop work on strings" do
      {:ok, %{return: ["h", "e"]}} = Lisp.run(~S|(take 2 "hello")|)
      {:ok, %{return: ["l", "l", "o"]}} = Lisp.run(~S|(drop 2 "hello")|)
    end

    test "reverse on string returns reversed list" do
      {:ok, %{return: ["c", "b", "a"]}} = Lisp.run(~S|(reverse "abc")|)
    end

    test "distinct on string removes duplicates" do
      {:ok, %{return: result}} = Lisp.run(~S|(distinct "aabbcc")|)
      assert Enum.sort(result) == ["a", "b", "c"]
    end

    test "some/every?/not-any? work on strings" do
      {:ok, %{return: true}} = Lisp.run(~S|(some #(= % \l) "hello")|)
      {:ok, %{return: true}} = Lisp.run(~S|(every? char? "abc")|)
      {:ok, %{return: true}} = Lisp.run(~S|(not-any? #(= % \z) "hello")|)
    end

    test "sort on string returns sorted list" do
      {:ok, %{return: ["a", "b", "c", "d"]}} = Lisp.run(~S|(sort "dcba")|)
    end

    test "count on string returns character count" do
      {:ok, %{return: 5}} = Lisp.run(~S|(count "hello")|)
      {:ok, %{return: 4}} = Lisp.run(~S|(count "café")|)
    end
  end

  describe "implicit do (multiple expressions)" do
    test "top-level multiple expressions" do
      source = "(def x 1) (def y 2) (+ x y)"
      {:ok, %{return: result, memory: mem}} = Lisp.run(source)
      assert result == 3
      assert mem[:x] == 1
      assert mem[:y] == 2
    end

    test "let with multiple bodies" do
      source = "(let [x 1] (def saved x) (* x 2))"
      {:ok, %{return: result, memory: mem}} = Lisp.run(source)
      assert result == 2
      assert mem[:saved] == 1
    end

    test "fn with multiple bodies via defn" do
      source = "(do (defn f [x] (def last-x x) x) (f 42))"
      {:ok, %{return: result, memory: mem}} = Lisp.run(source)
      assert result == 42
      assert mem[:"last-x"] == 42
    end

    test "fn with multiple bodies directly" do
      source = "(do (def f (fn [x] (def captured x) (* x 2))) (f 10))"
      {:ok, %{return: result, memory: mem}} = Lisp.run(source)
      assert result == 20
      assert mem[:captured] == 10
    end

    test "when with multiple bodies" do
      source = "(when true (def side 1) 42)"
      {:ok, %{return: result, memory: mem}} = Lisp.run(source)
      assert result == 42
      assert mem[:side] == 1
    end

    test "when-let with multiple bodies" do
      source = "(when-let [x 5] (def found x) (* x 2))"
      {:ok, %{return: result, memory: mem}} = Lisp.run(source)
      assert result == 10
      assert mem[:found] == 5
    end

    test "when-let with nil binding skips body" do
      source = "(when-let [x nil] (def should-not-run true) 42)"
      {:ok, %{return: result, memory: mem}} = Lisp.run(source)
      assert result == nil
      assert mem[:"should-not-run"] == nil
    end

    test "nested implicit do forms" do
      source = """
      (let [x 1]
        (def a x)
        (let [y 2]
          (def b y)
          (+ x y)))
      """

      {:ok, %{return: result, memory: mem}} = Lisp.run(source)
      assert result == 3
      assert mem[:a] == 1
      assert mem[:b] == 2
    end
  end

  describe "key/val Clojure compatibility" do
    test "key extracts key from map entry vector" do
      {:ok, %{return: result}} = Lisp.run("(key [:a 1])")
      assert result == :a
    end

    test "val extracts value from map entry vector" do
      {:ok, %{return: result}} = Lisp.run("(val [:a 1])")
      assert result == 1
    end

    test "key/val work with map iteration (seq)" do
      {:ok, %{return: result}} = Lisp.run("(map key (seq {:a 1 :b 2}))")
      assert Enum.sort(result) == [:a, :b]
    end

    test "max-key finds entry with max value" do
      {:ok, %{return: result}} = Lisp.run(~S|(max-key count "a" "abc" "ab")|)
      assert result == "abc"
    end

    test "min-key finds entry with min value" do
      {:ok, %{return: result}} = Lisp.run(~S|(min-key count "apple" "pear" "banana")|)
      assert result == "pear"
    end

    test "apply max-key with val on map (Clojure pattern)" do
      {:ok, %{return: result}} = Lisp.run("(apply max-key val (seq {:a 10 :b 42 :c 7}))")
      assert result == [:b, 42]
    end

    test "key extracts from max-key result" do
      {:ok, %{return: result}} = Lisp.run("(key (apply max-key val (seq {:a 10 :b 42 :c 7})))")
      assert result == :b
    end

    test "val extracts from min-key result" do
      {:ok, %{return: result}} = Lisp.run("(val (apply min-key val (seq {:a 10 :b 42 :c 7})))")
      assert result == 7
    end
  end

  describe "apply function E2E" do
    test "apply with max spreads collection" do
      source = "(apply max [3 1 4 1 5])"
      {:ok, %{return: 5}} = Lisp.run(source)
    end

    test "apply with reduce (multi-arity)" do
      source = "(apply reduce [+ 0 [1 2 3]])"
      {:ok, %{return: 6}} = Lisp.run(source)
    end

    test "apply in thread-last" do
      source = "(->> [1 2 3 4] (apply +))"
      {:ok, %{return: 10}} = Lisp.run(source)
    end

    test "apply with get (multi-arity 3-arg)" do
      source = ~S|(apply get [{:a 1} :b "default"])|
      {:ok, %{return: "default"}} = Lisp.run(source)
    end

    test "apply with closure arity error E2E" do
      source = "(apply (fn [x y] (+ x y)) [1])"
      {:error, %{fail: %{message: msg}}} = Lisp.run(source)
      assert msg =~ "arity_mismatch"
    end
  end

  describe "tool call argument recording" do
    test "keyword-style args are recorded as string-keyed map" do
      # When LLM calls (tool/summarize :text "hello"), the tool receives string keys
      # This prevents atom memory leaks and matches JSON conventions
      tools = %{
        "summarize" => fn %{"text" => text} -> %{summary: "Summary of: #{text}"} end
      }

      source = ~S|(tool/summarize :text "hello world")|

      {:ok, step} = Lisp.run(source, tools: tools)

      assert [tool_call] = step.tool_calls
      assert tool_call.name == "summarize"
      # Args should be a string-keyed map
      assert tool_call.args == %{"text" => "hello world"}
      refute Map.has_key?(tool_call.args, "args")
    end

    test "multiple keyword args are recorded as string-keyed map" do
      tools = %{
        "search" => fn %{"query" => q, "limit" => l} -> [q, l] end
      }

      source = ~S|(tool/search :query "elixir" :limit 10)|

      {:ok, step} = Lisp.run(source, tools: tools)

      assert [tool_call] = step.tool_calls
      assert tool_call.args == %{"query" => "elixir", "limit" => 10}
    end

    test "single map arg is converted to string keys" do
      tools = %{
        "fetch" => fn %{"url" => url} -> "content from #{url}" end
      }

      source = ~S|(tool/fetch {:url "http://example.com"})|

      {:ok, step} = Lisp.run(source, tools: tools)

      assert [tool_call] = step.tool_calls
      assert tool_call.args == %{"url" => "http://example.com"}
    end
  end

  describe "tool_calls preserved across closure calls" do
    test "tool calls before a closure call are not lost" do
      # Regression: execute_closure created a fresh EvalContext with tool_calls: [],
      # so any tool calls made before the closure call were discarded.
      tools = %{
        "fetch" => fn %{"id" => id} -> "data_#{id}" end
      }

      source = ~S"""
      (defn format-it [x] (str "formatted:" x))
      (let [a (tool/fetch {:id "1"})
            b (format-it a)
            c (tool/fetch {:id "2"})]
        {:first b :second c})
      """

      {:ok, step} = Lisp.run(source, tools: tools)

      assert step.return == %{first: "formatted:data_1", second: "data_2"}
      assert length(step.tool_calls) == 2
      assert Enum.map(step.tool_calls, & &1.name) == ["fetch", "fetch"]
    end

    test "child_steps from tool calls survive intervening closure calls" do
      # Simulates the planner-worker-reviewer do-step pattern:
      # tool/worker → (format-result ...) → tool/reviewer
      # The format-result closure must not discard worker's child_step.
      worker_step = %PtcRunner.Step{return: %{data: "ok"}, trace_id: "worker_1"}
      reviewer_step = %PtcRunner.Step{return: %{approved: true}, trace_id: "reviewer_1"}

      tools = %{
        "worker" =>
          {fn %{"task" => _} ->
             %{__child_step__: worker_step, value: %{data: "ok"}}
           end, signature: "(task :string) -> :map"},
        "reviewer" =>
          {fn %{"result" => _} ->
             %{__child_step__: reviewer_step, value: %{approved: true}}
           end, signature: "(result :string) -> :map"}
      }

      source = ~S"""
      (defn format-result [m]
        (reduce (fn [acc k] (str acc k ": " (get m k) "\n")) "" (keys m)))
      (let [result (tool/worker {:task "research"})
            result_str (format-result result)
            review (tool/reviewer {:result result_str})]
        {:result result :review review})
      """

      {:ok, step} = Lisp.run(source, tools: tools)

      assert length(step.child_steps) == 2
      assert Enum.map(step.child_steps, & &1.trace_id) == ["worker_1", "reviewer_1"]
    end
  end

  describe "boolean builtin" do
    test "nil returns false" do
      {:ok, %{return: result}} = Lisp.run("(boolean nil)")
      assert result == false
    end

    test "false returns false" do
      {:ok, %{return: result}} = Lisp.run("(boolean false)")
      assert result == false
    end

    test "true returns true" do
      {:ok, %{return: result}} = Lisp.run("(boolean true)")
      assert result == true
    end

    test "numbers are truthy" do
      {:ok, %{return: result}} = Lisp.run("(boolean 0)")
      assert result == true
    end

    test "empty string is truthy" do
      {:ok, %{return: result}} = Lisp.run(~s|(boolean "")|)
      assert result == true
    end

    test "empty vector is truthy" do
      {:ok, %{return: result}} = Lisp.run("(boolean [])")
      assert result == true
    end

    test "map is truthy" do
      {:ok, %{return: result}} = Lisp.run("(boolean {})")
      assert result == true
    end

    test "keyword is truthy" do
      {:ok, %{return: result}} = Lisp.run("(boolean :foo)")
      assert result == true
    end
  end

  describe "index-of" do
    test "basic substring search" do
      {:ok, %{return: 2}} = Lisp.run(~S|(index-of "hello" "ll")|)
    end

    test "returns nil when not found" do
      {:ok, %{return: nil}} = Lisp.run(~S|(index-of "hello" "x")|)
    end

    test "empty substring returns 0" do
      {:ok, %{return: 0}} = Lisp.run(~S|(index-of "hello" "")|)
    end

    test "with from-index" do
      {:ok, %{return: 3}} = Lisp.run(~S|(index-of "hello" "l" 3)|)
    end

    test "from-index beyond string length returns nil" do
      {:ok, %{return: nil}} = Lisp.run(~S|(index-of "hello" "l" 10)|)
    end

    test "unicode string" do
      {:ok, %{return: 2}} = Lisp.run(~S|(index-of "héllo" "l")|)
    end

    test "namespace resolution clojure.string/index-of" do
      {:ok, %{return: 2}} = Lisp.run(~S|(clojure.string/index-of "hello" "ll")|)
    end

    test "namespace resolution str/index-of" do
      {:ok, %{return: 2}} = Lisp.run(~S|(str/index-of "hello" "ll")|)
    end

    test "nil result is usable in conditionals" do
      {:ok, %{return: "not found"}} =
        Lisp.run(~S|(if (nil? (index-of "hello" "x")) "not found" "found")|)
    end
  end

  describe "last-index-of" do
    test "basic last occurrence" do
      {:ok, %{return: 3}} = Lisp.run(~S|(last-index-of "hello" "l")|)
    end

    test "returns nil when not found" do
      {:ok, %{return: nil}} = Lisp.run(~S|(last-index-of "hello" "x")|)
    end

    test "empty substring returns string length" do
      {:ok, %{return: 5}} = Lisp.run(~S|(last-index-of "hello" "")|)
    end

    test "with from-index" do
      {:ok, %{return: 2}} = Lisp.run(~S|(last-index-of "hello" "l" 2)|)
    end

    test "namespace resolution clojure.string/last-index-of" do
      {:ok, %{return: 3}} = Lisp.run(~S|(clojure.string/last-index-of "hello" "l")|)
    end

    test "namespace resolution str/last-index-of" do
      {:ok, %{return: 3}} = Lisp.run(~S|(str/last-index-of "hello" "l")|)
    end

    test "overlapping matches" do
      {:ok, %{return: 1}} = Lisp.run(~S|(last-index-of "aaa" "aa")|)
      {:ok, %{return: 2}} = Lisp.run(~S|(last-index-of "aaaa" "aa")|)
    end
  end
end
