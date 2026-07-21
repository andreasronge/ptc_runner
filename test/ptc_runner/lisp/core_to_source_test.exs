defmodule PtcRunner.Lisp.CoreToSourceTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.{Analyze, CoreToSource, Result}
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Parser

  doctest PtcRunner.Lisp.CoreToSource

  describe "format/1 literals" do
    test "nil, booleans, numbers" do
      assert CoreToSource.format(nil) == "nil"
      assert CoreToSource.format(true) == "true"
      assert CoreToSource.format(false) == "false"
      assert CoreToSource.format(42) == "42"
      assert CoreToSource.format(3.14) == "3.14"
    end

    test "special float values" do
      assert CoreToSource.format(:infinity) == "##Inf"
      assert CoreToSource.format(:negative_infinity) == "##-Inf"
      assert CoreToSource.format(:nan) == "##NaN"
    end

    test "strings with escaping" do
      assert CoreToSource.format({:string, "hello"}) == ~S("hello")
      assert CoreToSource.format({:string, ~S[say "hi"]}) == ~S["say \"hi\""]
      assert CoreToSource.format({:string, "line\nnew"}) == ~S("line\nnew")
    end

    test "keywords" do
      assert CoreToSource.format({:keyword, :foo}) == ":foo"
    end
  end

  describe "format/1 variables and data" do
    test "var" do
      assert CoreToSource.format({:var, :x}) == "x"
      assert CoreToSource.format({:var, :my_var}) == "my_var"
    end

    test "symbolic ref" do
      assert CoreToSource.format({:symbol_ref, "github/search_repos"}) == "'github/search_repos"
    end

    test "data access" do
      assert CoreToSource.format({:data, :task}) == "data/task"
      assert CoreToSource.format({:data, :success}) == "data/success"
    end
  end

  describe "format/1 collections" do
    test "vector" do
      assert CoreToSource.format({:vector, [1, 2, 3]}) == "[1 2 3]"
      assert CoreToSource.format({:vector, []}) == "[]"
    end

    test "map" do
      result = CoreToSource.format({:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]})
      assert result == "{:a 1 :b 2}"
    end

    test "set" do
      assert CoreToSource.format({:set, [1, 2, 3]}) == "\#{1 2 3}"
    end
  end

  describe "format/1 special forms" do
    test "let" do
      ast = {:let, [{:binding, {:var, :x}, 1}], {:var, :x}}
      assert CoreToSource.format(ast) == "(let [x 1] x)"
    end

    test "fn" do
      ast = {:fn, [{:var, :x}], {:call, {:var, :+}, [{:var, :x}, 1]}}
      assert CoreToSource.format(ast) == "(fn [x] (+ x 1))"
    end

    test "fn with variadic params" do
      ast = {:fn, {:variadic, [{:var, :x}], {:var, :rest}}, {:var, :rest}}
      assert CoreToSource.format(ast) == "(fn [x & rest] rest)"
    end

    test "loop and recur" do
      ast =
        {:loop, [{:binding, {:var, :i}, 0}],
         {:if, {:call, {:var, :<}, [{:var, :i}, 10]},
          {:recur, [{:call, {:var, :inc}, [{:var, :i}]}]}, {:var, :i}}}

      result = CoreToSource.format(ast)
      assert result == "(loop [i 0] (if (< i 10) (recur (inc i)) i))"
    end

    test "def" do
      ast = {:def, :x, 42, %{}}
      assert CoreToSource.format(ast) == "(def x 42)"
    end

    test "if" do
      ast = {:if, true, 1, 2}
      assert CoreToSource.format(ast) == "(if true 1 2)"
    end

    test "do" do
      ast = {:do, [1, 2, 3]}
      assert CoreToSource.format(ast) == "(do 1 2 3)"
    end

    test "and/or" do
      assert CoreToSource.format({:and, [true, false]}) == "(and true false)"
      assert CoreToSource.format({:or, [{:var, :a}, {:var, :b}]}) == "(or a b)"
    end

    test "return and fail" do
      assert CoreToSource.format({:return, 42}) == "(return 42)"
      assert CoreToSource.format({:fail, {:string, "oops"}}) == "(fail \"oops\")"
    end
  end

  describe "format/1 calls" do
    test "function call with var target" do
      ast = {:call, {:var, :+}, [1, 2]}
      assert CoreToSource.format(ast) == "(+ 1 2)"
    end

    test "tool call" do
      ast = {:tool_call, :search, [{:map, [{{:keyword, :query}, {:string, "test"}}]}]}
      assert CoreToSource.format(ast) == ~S[(tool/search {:query "test"})]
    end
  end

  describe "format/1 runtime state" do
    test "turn-history" do
      assert CoreToSource.format({:turn_history, 3}) == "(turn-history 3)"
    end
  end

  describe "format/1 parallel operations" do
    test "pmap" do
      ast = {:pmap, {:var, :inc}, [{:var, :items}]}
      assert CoreToSource.format(ast) == "(pmap inc items)"
    end

    test "pmap with multiple collections" do
      ast = {:pmap, {:var, :+}, [{:var, :xs}, {:var, :ys}]}
      assert CoreToSource.format(ast) == "(pmap + xs ys)"
    end

    test "pcalls" do
      ast = {:pcalls, [{:var, :f}, {:var, :g}]}
      assert CoreToSource.format(ast) == "(pcalls f g)"
    end

    test "juxt" do
      ast = {:juxt, [{:var, :first}, {:var, :count}]}
      assert CoreToSource.format(ast) == "(juxt first count)"
    end
  end

  describe "roundtrip: source -> parse -> analyze -> format -> parse -> analyze" do
    # Parse source, analyze to Core AST, format back, re-parse, re-analyze, compare
    defp roundtrip(source) do
      {:ok, raw_ast} = Parser.parse(source)
      {:ok, core_ast} = Analyze.analyze(raw_ast)
      reformatted = CoreToSource.format(core_ast)
      {:ok, raw_ast2} = Parser.parse(reformatted)
      {:ok, core_ast2} = Analyze.analyze(raw_ast2)
      {core_ast, core_ast2, reformatted}
    end

    test "simple arithmetic" do
      {ast1, ast2, _} = roundtrip("(+ 1 2)")
      assert ast1 == ast2
    end

    test "let binding" do
      {ast1, ast2, _} = roundtrip("(let [x 1] (+ x 2))")
      assert ast1 == ast2
    end

    test "nested function call" do
      {ast1, ast2, _} = roundtrip("(map inc [1 2 3])")
      assert ast1 == ast2
    end

    test "if expression" do
      {ast1, ast2, _} = roundtrip("(if true 1 0)")
      assert ast1 == ast2
    end

    test "def with expression" do
      {ast1, ast2, _} = roundtrip("(def x (+ 1 2))")
      assert ast1 == ast2
    end

    test "do block" do
      {ast1, ast2, _} = roundtrip("(do (def x 1) (+ x 2))")
      assert ast1 == ast2
    end

    test "fn expression" do
      {ast1, ast2, _} = roundtrip("(fn [x] (+ x 1))")
      assert ast1 == ast2
    end

    test "or with default pattern" do
      {ast1, ast2, _} = roundtrip("(or x [])")
      assert ast1 == ast2
    end

    test "map literal" do
      {ast1, ast2, _} = roundtrip(~S({"a" 1 "b" 2}))
      assert ast1 == ast2
    end

    test "data access" do
      {ast1, ast2, _} = roundtrip("(get data/task \"key\")")
      assert ast1 == ast2
    end

    test "typical ALMA update_code" do
      source =
        ~S|(def episodes (take 10 (conj (or episodes []) {"task" data/task "success" data/success})))|

      {ast1, ast2, _} = roundtrip(source)
      assert ast1 == ast2
    end

    test "vector with nested maps" do
      {ast1, ast2, _} = roundtrip(~S|[{"a" 1} {"b" 2}]|)
      assert ast1 == ast2
    end
  end

  describe "serialize_closure/1" do
    test "serializes a simple closure" do
      closure = {:closure, [{:var, :x}], {:call, {:var, :+}, [{:var, :x}, 1]}, %{}, [], %{}}
      assert CoreToSource.serialize_closure(closure) == "(fn [x] (+ x 1))"
    end

    test "drops environment from closure" do
      env = %{captured_var: 42}
      closure = {:closure, [{:var, :x}], {:var, :x}, env, [], %{}}
      # Env is dropped — only params + body matter
      assert CoreToSource.serialize_closure(closure) == "(fn [x] x)"
    end

    test "serializes closure from native Lisp result" do
      {:ok, step} = PtcRunner.Lisp.run_native("(fn [x] (+ x 1))")
      source = CoreToSource.serialize_closure(step.return)
      assert source == "(fn [x] (+ x 1))"
    end
  end

  describe "serialize_namespace/1" do
    test "serializes closures and skips non-closures" do
      {:ok, step} =
        PtcRunner.Lisp.run("(do (def f (fn [x] x)) (def g (fn [y] (+ y 1))) (def total 5))")

      result = CoreToSource.serialize_namespace(step.memory)

      assert Map.has_key?(result, "f")
      assert Map.has_key?(result, "g")
      refute Map.has_key?(result, "total")

      assert result["f"] == "(fn [x] x)"
      assert result["g"] == "(fn [y] (+ y 1))"
    end

    test "returns empty map for no closures" do
      assert CoreToSource.serialize_namespace(%{a: 1, b: "hello"}) == %{}
    end
  end

  describe "export_namespace/1" do
    test "exports entire namespace as a (do ...) block of (def ...) forms" do
      # Use a constant that closures reference via their captured env,
      # plus helper functions that call each other
      {:ok, step} =
        PtcRunner.Lisp.run("""
        (do
          (def threshold 0.5)
          (defn helper [x] (+ x 1))
          (defn recall [] (str "threshold=" threshold)))
        """)

      assert {:ok, source} = CoreToSource.export_namespace(step.memory)

      # Should contain defs for all three: the constant AND the functions
      assert source =~ "def threshold"
      assert source =~ "def helper"
      assert source =~ "def recall"

      # Round-trip: running the exported source should reconstruct the namespace
      {:ok, step2} = PtcRunner.Lisp.run(source)
      assert is_tuple(step2.memory["helper"])
      assert is_tuple(step2.memory["recall"])
      assert step2.memory["threshold"] == 0.5
    end

    test "handles raw runtime values in memory (empty maps, lists, strings)" do
      # When LLM code does (def room-graph {}), memory contains a raw %{},
      # not a {:map, []} AST node. export_namespace must handle this.
      {:ok, step} =
        PtcRunner.Lisp.run(~S"""
        (do
          (def visited [])
          (def stats {})
          (def label "hello")
          (defn mem-update []
            (def visited (conj visited (get data/task "location")))))
        """)

      assert {:ok, source} = CoreToSource.export_namespace(step.memory)
      assert source =~ "def visited"
      assert source =~ "def stats"
      assert source =~ "def label"

      {:ok, step2} = PtcRunner.Lisp.run(source)
      assert step2.memory["visited"] == []
      assert step2.memory["stats"] == %{}
      assert step2.memory["label"] == "hello"
    end

    test "exports underscore-prefixed memory names" do
      {:ok, step} =
        PtcRunner.Lisp.run(~S"""
        (do
          (def _scratch 42)
          (defn _helper [] _scratch))
        """)

      assert {:ok, source} = CoreToSource.export_namespace(step.memory)

      assert source =~ "def _scratch"
      assert source =~ "def _helper"

      {:ok, step2} = PtcRunner.Lisp.run(source)
      assert step2.memory["_scratch"] == 42
      assert is_tuple(step2.memory["_helper"])
    end

    test "exported namespace round-trips: helpers remain callable" do
      {:ok, step} =
        PtcRunner.Lisp.run("""
        (do
          (defn twice [x] (* x 2))
          (defn compute [] (twice 21)))
        """)

      assert {:ok, source} = CoreToSource.export_namespace(step.memory)
      {:ok, step2} = PtcRunner.Lisp.run(source)

      # After hydrating, compute should still be able to call twice
      {:ok, result} =
        PtcRunner.Lisp.run("(compute)", memory: step2.memory, filter_context: false)

      assert result.return == 42
    end

    test "round-trips closures containing Java syntax and rejects stored Java authority" do
      assert {:ok, step} =
               PtcRunner.Lisp.run_native(
                 ~S|(do (defn parse-bool [s] (Boolean/parseBoolean s)) (def parser Boolean/parseBoolean))|
               )

      assert {:error,
              {:non_exportable_java_value, [{:binding, "parser"}], :boolean_parse_boolean}} =
               CoreToSource.export_namespace(step.memory)

      memory = Map.delete(step.memory, "parser")
      assert {:ok, source} = CoreToSource.export_namespace(memory)
      assert source =~ "Boolean/parseBoolean"

      assert {:ok, hydrated} = PtcRunner.Lisp.run(source)
      assert {:ok, result} = PtcRunner.Lisp.run(~S|(parse-bool "true")|, memory: hydrated.memory)
      assert result.return == true
    end

    test "rejects Java authority nested in struct fields" do
      assert {:ok, callable} = JavaCallable.new(:boolean_parse_boolean)

      assert {:error,
              {:non_exportable_java_value, [{:binding, "result"}, {:struct_field, :return}],
               :boolean_parse_boolean}} =
               CoreToSource.export_namespace(%{"result" => %Result{return: callable}})
    end

    test "rejects malformed Java struct-shaped maps without destructuring them" do
      malformed_callable = %{__struct__: JavaCallable}
      malformed_primitive = %{__struct__: PtcRunner.Lisp.Java.Primitive, kind: :int}

      assert {:error, {:non_exportable_java_value, [{:binding, "parser"}], nil}} =
               CoreToSource.export_namespace(%{"parser" => malformed_callable})

      assert {:error, {:non_exportable_java_value, [{:binding, "value"}], :int}} =
               CoreToSource.export_namespace(%{"value" => malformed_primitive})
    end
  end

  test "formats closed Java instance and direct-dot nodes with Java source spelling" do
    assert CoreToSource.format(
             {:java_instance, :string_contains, {:var, :text}, [{:string, "x"}]}
           ) == ~S|(.contains text "x")|

    assert CoreToSource.format({:java_dot, :is_before, {:var, :value}, [{:var, :other}]}) ==
             ~S|(.isBefore value other)|
  end
end
