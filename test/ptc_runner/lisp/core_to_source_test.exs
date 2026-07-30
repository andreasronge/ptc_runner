defmodule PtcRunner.Lisp.CoreToSourceTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.{Analyze, CoreToSource, Format, Keyword, Result}
  alias PtcRunner.Lisp.Java.Callable, as: JavaCallable
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Time.Instant, as: JavaInstant
  alias PtcRunner.Lisp.Java.Time.LocalDate, as: JavaLocalDate
  alias PtcRunner.Lisp.Parser
  alias PtcRunner.Lisp.Prelude.Compiler

  doctest PtcRunner.Lisp.CoreToSource

  describe "format/1 literals" do
    test "nil, booleans, numbers" do
      assert CoreToSource.format(nil) == "nil"
      assert CoreToSource.format(true) == "true"
      assert CoreToSource.format(false) == "false"
      assert CoreToSource.format(42) == "42"
      assert CoreToSource.format(3.14) == "3.14"
    end

    test "floats retain their exact value through namespace export" do
      values = [1.2345678901234567, 0.10000000000000002, 2.2250738585072014e-308]
      memory = Map.new(Enum.with_index(values), fn {value, index} -> {"v#{index}", value} end)

      assert {:ok, source} = CoreToSource.export_namespace(memory)
      assert {:ok, hydrated} = Lisp.run_native(source)

      for {value, index} <- Enum.with_index(values) do
        assert hydrated.memory["v#{index}"] === value
      end

      literal = 0.10000000000000002
      closure = {:closure, [], {:literal, literal}, %{}, [], %{}}
      assert {:ok, source} = CoreToSource.export_namespace(%{"literal-value" => closure})
      assert {:ok, hydrated} = Lisp.run_native(source)
      assert {:ok, invoked} = Lisp.run_native("(literal-value)", memory: hydrated.memory)
      assert invoked.return === literal
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
      assert CoreToSource.format({:turn_history, 3}) == "*3"
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
      closure =
        {:closure, [{:var, "x"}], {:call, {:var, :+}, [{:var, "x"}, 1]}, %{}, [], %{}}

      assert CoreToSource.serialize_closure(closure) == {:ok, "(fn [x] (+ x 1))"}
    end

    test "preserves a directly stored named closure's self binding" do
      assert {:ok, first} =
               Lisp.run_native("(fn self [n] (if (<= n 1) 1 (* n (self (dec n)))))")

      assert {:ok, source} = CoreToSource.serialize_closure(first.return)
      assert source =~ "(fn self "
      assert {:ok, hydrated} = Lisp.run_native("(def factorial #{source})")

      assert {:ok, %{return: 120}} =
               Lisp.run_native("(factorial 5)", memory: hydrated.memory)
    end

    test "drops environment from closure" do
      {:ok, discarded_java_value} =
        Primitive.new(:int, 42)

      env = %{captured_var: discarded_java_value}

      closure =
        {:closure, [{:var, "x"}], {:var, "x"}, env, [discarded_java_value],
         %{diagnostic: discarded_java_value}}

      # Env is dropped — only params + body matter
      assert CoreToSource.serialize_closure(closure) == {:ok, "(fn [x] x)"}
      assert CoreToSource.serialize_namespace(%{"f" => closure}) == {:ok, %{"f" => "(fn [x] x)"}}
      assert {:ok, "(def f (fn [x] x))"} = CoreToSource.export_namespace(%{"f" => closure})
    end

    test "rejects closures whose emitted source would lose captured lexical state" do
      assert {:ok, first} = Lisp.run_native("(let [captured 41] (fn [x] (+ captured x)))")
      closure = first.return

      assert {:error, {:non_exportable_closure_capture, _path, ["captured"]}} =
               CoreToSource.serialize_closure(closure)

      assert {:error, {:non_exportable_closure_capture, _path, ["captured"]}} =
               CoreToSource.serialize_namespace(%{"f" => closure})

      assert {:error, {:non_exportable_closure_capture, _path, ["captured"]}} =
               CoreToSource.export_namespace(%{"f" => closure})
    end

    test "rejects binary keywords that reparse as atom-backed keywords" do
      keyword = {:keyword, "map"}
      closure = {:closure, [], keyword, %{}, [], %{}}

      assert {:error, {:non_exportable_source_value, _path, ^keyword}} =
               CoreToSource.serialize_closure(closure)

      assert {:error, {:non_exportable_source_value, _path, ^keyword}} =
               CoreToSource.serialize_namespace(%{"f" => closure})

      assert {:error, {:non_exportable_source_value, _path, ^keyword}} =
               CoreToSource.export_namespace(%{"f" => closure})
    end

    test "rejects atom and binary identifiers that collapse to the same source name" do
      closures = [
        {:closure, [{:var, :map}, {:var, "map"}], {:var, :map}, %{}, [], %{}},
        {:closure, [{:var, :map}], {:let, [{:binding, {:var, "map"}, 1}], {:var, "map"}}, %{}, [],
         %{}},
        {:closure, [{:var, :map}], {:var, "map"}, %{}, [], %{}}
      ]

      for closure <- closures do
        assert {:error, {:non_exportable_source_collision, _path, :identifier}} =
                 CoreToSource.serialize_closure(closure)

        assert {:error, {:non_exportable_source_collision, _path, :identifier}} =
                 CoreToSource.serialize_namespace(%{"f" => closure})

        assert {:error, {:non_exportable_source_collision, _path, :identifier}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end

    test "rejects namespace-visible identifiers whose reader identity changes" do
      noncanonical = "map"

      for body <- [{:def, noncanonical, 1, %{}}, {:var, noncanonical}] do
        closure = {:closure, [], body, %{}, [], %{}}

        assert {:error, {:non_exportable_source_value, _path, ^noncanonical}} =
                 CoreToSource.serialize_closure(closure)

        assert {:error, {:non_exportable_source_value, _path, ^noncanonical}} =
                 CoreToSource.serialize_namespace(%{"f" => closure})

        assert {:error, {:non_exportable_source_value, _path, ^noncanonical}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end

    test "rejects :keys selectors whose reader identity changes" do
      noncanonical = "map"
      pattern = {:destructure, {:keys, [noncanonical], []}}
      closure = {:closure, [pattern], {:var, noncanonical}, %{}, [], %{}}

      assert {:error, {:non_exportable_source_value, _path, ^noncanonical}} =
               CoreToSource.serialize_closure(closure)

      assert {:error, {:non_exportable_source_value, _path, ^noncanonical}} =
               CoreToSource.serialize_namespace(%{"f" => closure})

      assert {:error, {:non_exportable_source_value, _path, ^noncanonical}} =
               CoreToSource.export_namespace(%{"f" => closure})
    end

    test "round-trips analyzer-generated temporary identifiers" do
      assert {:ok, first} =
               Lisp.run_native("""
               (fn [x]
                 [(case x 1 :one :other)
                  (condp = x 1 :one :other)
                  (cond-> x true inc)
                  (some-> x inc)
                  (when-first [item [x]] item)])
               """)

      closure = first.return

      assert {:ok, closure_source} = CoreToSource.serialize_closure(closure)
      assert {:ok, namespace_sources} = CoreToSource.serialize_namespace(%{"f" => closure})
      assert namespace_sources == %{"f" => closure_source}
      assert {:ok, namespace_source} = CoreToSource.export_namespace(%{"f" => closure})

      for source <- ["(def f #{closure_source})", namespace_source] do
        assert {:ok, hydrated} = Lisp.run_native(source)

        assert {:ok, %{return: [one, one, 2, 2, 1]}} =
                 Lisp.run_native("(f 1)", memory: hydrated.memory)

        assert one == Keyword.new("one")
      end
    end

    test "rejects duplicate source forms in closure map and set literals" do
      for {collection, body} <- [
            {:map, {:map, [{{:keyword, :map}, 1}, {:map, 2}]}},
            {:set, {:set, [{:keyword, :map}, :map]}}
          ] do
        closure = {:closure, [], body, %{}, [], %{}}

        assert {:error, {:non_exportable_source_collision, _path, ^collection}} =
                 CoreToSource.serialize_closure(closure)

        assert {:error, {:non_exportable_source_collision, _path, ^collection}} =
                 CoreToSource.serialize_namespace(%{"f" => closure})

        assert {:error, {:non_exportable_source_collision, _path, ^collection}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end

    test "treats literal payloads as opaque and returns errors through every export API" do
      closures = [
        {:closure, [], {:literal, [1 | 2]}, %{}, [], %{}},
        {:closure, [], {:literal, {:var, :x}}, %{x: 1}, [], %{}},
        {:closure, [], {:literal, {:fn, [1 | 2], 1}}, %{}, [], %{}}
      ]

      for closure <- closures do
        assert {:error, {:non_exportable_source_value, _path, _value}} =
                 CoreToSource.serialize_closure(closure)

        assert {:error, {:non_exportable_source_value, _path, _value}} =
                 CoreToSource.serialize_namespace(%{"f" => closure})

        assert {:error, {:non_exportable_source_value, _path, _value}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end

    test "rejects semantic captured-locals metadata that source cannot preserve" do
      forged_map_set = Map.put(MapSet.new(), :map, :invalid)

      for captured_locals <- [MapSet.new(["x"]), ["x"], forged_map_set] do
        closure =
          {:closure, [], {:var, "x"}, %{}, [], %{captured_locals: captured_locals}}

        assert {:error, {:non_exportable_closure_metadata, _path, [:captured_locals]}} =
                 CoreToSource.serialize_closure(closure)
      end

      closure = {:closure, [], 1, %{}, [], %{captured_locals: MapSet.new()}}
      assert {:ok, "(fn [] 1)"} = CoreToSource.serialize_closure(closure)
    end

    test "returns an export error for malformed closure shapes" do
      for malformed <- [{}, {:closure}, :not_a_closure] do
        assert {:error, {:non_exportable_source_value, _path, ^malformed}} =
                 CoreToSource.serialize_closure(malformed)
      end
    end

    test "serializes closure from native Lisp result" do
      {:ok, step} = PtcRunner.Lisp.run_native("(fn [x] (+ x 1))")
      {:ok, source} = CoreToSource.serialize_closure(step.return)
      assert source == "(fn [x] (+ x 1))"
    end

    test "rejects a docstring that closure-only source cannot represent" do
      {:ok, step} = PtcRunner.Lisp.run(~S|(defn twice "Doubles a number" [x] (* x 2))|)

      assert {:error, {:non_exportable_closure_metadata, _path, [:docstring]}} =
               CoreToSource.serialize_closure(step.memory["twice"])
    end

    test "rejects malformed closure source instead of formatting it directly" do
      malicious_name = "x] (tool/evil {}) (fn [x"
      malformed_body = {:tool_call, "safe", 123}

      assert {:error, {:non_exportable_source_name, _path, :binding, ^malicious_name}} =
               CoreToSource.serialize_closure(
                 {:closure, [{:var, malicious_name}], 1, %{}, [], %{}}
               )

      assert {:error, {:non_exportable_source_value, _path, _value}} =
               CoreToSource.serialize_closure({:closure, [], malformed_body, %{}, [], %{}})
    end
  end

  describe "serialize_namespace/1" do
    test "serializes closures and skips non-closures" do
      {:ok, step} =
        PtcRunner.Lisp.run("(do (def f (fn [x] x)) (def g (fn [y] (+ y 1))) (def total 5))")

      assert {:ok, result} = CoreToSource.serialize_namespace(step.memory)

      assert Map.has_key?(result, "f")
      assert Map.has_key?(result, "g")
      refute Map.has_key?(result, "total")

      assert result["f"] == "(fn [x] x)"
      assert result["g"] == "(fn [y] (+ y 1))"
    end

    test "returns empty map for no closures" do
      assert CoreToSource.serialize_namespace(%{a: 1, b: "hello"}) == {:ok, %{}}
    end

    test "validates every serialized closure through the hardened exporter" do
      malicious_name = "safe) (tool/evil {}) ;"
      closure = {:closure, [], {:return, {:var, malicious_name}}, %{}, [], %{}}

      assert {:error, {:non_exportable_source_name, _path, :var, ^malicious_name}} =
               CoreToSource.serialize_namespace(%{"f" => closure})
    end

    test "rejects docstrings that its expression-only values cannot represent" do
      {:ok, step} = PtcRunner.Lisp.run(~S|(defn twice "Doubles a number" [x] (* x 2))|)

      assert {:error, {:non_exportable_closure_metadata, _path, [:docstring]}} =
               CoreToSource.serialize_namespace(step.memory)
    end

    test "rejects unsupported binding-key types before inspecting closure metadata" do
      closure = {:closure, [], 1, %{}, [], %{docstring: "Documented"}}

      assert {:error, {:non_exportable_source_name, [{:binding, 1}], :binding, 1}} =
               CoreToSource.serialize_namespace(%{1 => closure})
    end
  end

  describe "export_namespace/1" do
    test "rejects binding keys whose reader identity changes" do
      noncanonical = "map"

      assert {:error, {:non_exportable_source_value, [{:binding, ^noncanonical}], ^noncanonical}} =
               CoreToSource.export_namespace(%{noncanonical => 1})
    end

    test "round-trips escaped function docstrings" do
      docstring = "Quotes: \"hello\"\nPath: C:\\tmp"

      {:ok, step} =
        PtcRunner.Lisp.run(
          ~S|(defn greet "Quotes: \"hello\"\nPath: C:\\tmp" [name] (str "Hello " name))|
        )

      assert {:ok, source} = CoreToSource.export_namespace(step.memory)
      assert source =~ ~S|"Quotes: \"hello\"\nPath: C:\\tmp"|

      assert {:ok, hydrated} = PtcRunner.Lisp.run(source)
      {:closure, _, _, _, _, metadata} = hydrated.memory["greet"]
      assert metadata.docstring == docstring
    end

    test "round-trips docstrings on nested def and defonce forms" do
      for form <- ["def", "defonce"] do
        source = ~s|(defn outer [] (#{form} helper "Nested docs" (fn [] 42)))|

        assert {:ok, first} = Lisp.run(source)
        assert {:ok, exported} = CoreToSource.export_namespace(first.memory)
        assert exported =~ ~s|(#{form} helper "Nested docs" (fn [] 42))|

        assert {:ok, hydrated} = Lisp.run(exported)
        assert {:ok, invoked} = Lisp.run("(outer)", memory: hydrated.memory)
        {:closure, _, _, _, _, metadata} = invoked.memory["helper"]
        assert metadata.docstring == "Nested docs"
      end
    end

    test "preserves a direct prelude reference and rejects stripped stored authority" do
      assert {:ok, prelude} =
               Compiler.compile("""
               (ns crm "CRM helpers." {:visibility :prompt})
               (defn- secret-helper [] "PRIVATE")
               (defn pub [] (secret-helper))
               """)

      assert {:ok, direct} = Lisp.run_native("crm/pub", prelude: prelude)
      assert {:ok, "crm/pub"} = CoreToSource.serialize_closure(direct.return)

      assert {:ok, first} = Lisp.run_native("(def saved crm/pub)", prelude: prelude)

      assert {:error, {:non_exportable_closure_metadata, _path, [:prelude_ns]}} =
               CoreToSource.serialize_namespace(first.memory)

      assert {:error, {:non_exportable_closure_metadata, _path, [:prelude_ns]}} =
               CoreToSource.export_namespace(first.memory)
    end

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

    test "round-trips literal scalar values in direct and nested positions" do
      literals = [nil, true, false, :infinity, :negative_infinity, :nan]

      for literal <- literals do
        memory = %{"direct" => literal, "nested" => [literal, %{"value" => literal}]}

        assert {:ok, source} = CoreToSource.export_namespace(memory)
        assert {:ok, hydrated} = Lisp.run_native(source)
        assert hydrated.memory == memory
      end
    end

    test "rejects runtime data that is shaped like executable Core AST" do
      tool_result = {:tool_call, "write", []}

      assert {:error,
              {:non_exportable_source_value, [{:binding, "result"}, {:map_value, 0}],
               ^tool_result}} =
               CoreToSource.export_namespace(%{"result" => %{"tool-result" => tool_result}})
    end

    test "round-trips runtime sets, novel keywords, and public quoted-symbol wrappers" do
      assert {:ok, first} =
               Lisp.run(
                 ~S|(do (def tags #{:a :novel_keyword}) (def tag :novel_keyword) (def modifier :else))|
               )

      memory =
        Map.put(first.memory, "quoted", %Format.SymbolRef{name: "github/search_repos"})

      assert {:ok, source} = CoreToSource.export_namespace(memory)
      assert {:ok, hydrated} = Lisp.run(source)

      assert {:ok, %{return: [true, true, true, true]}} =
               Lisp.run(
                 ~S|[(contains? tags :a) (= tag :novel_keyword) (= modifier :else) (= quoted 'github/search_repos)]|,
                 memory: hydrated.memory
               )
    end

    test "rejects map and set members that collapse to duplicate source forms" do
      public = %Format.SymbolRef{name: "x"}
      native = {:symbol_ref, "x"}

      assert {:error, {:non_exportable_source_collision, [{:binding, "value"}], :map}} =
               CoreToSource.export_namespace(%{
                 "value" => %{public => "public", native => "native"}
               })

      assert {:error, {:non_exportable_source_collision, [{:binding, "value"}], :set}} =
               CoreToSource.export_namespace(%{"value" => MapSet.new([public, native])})
    end

    test "round-trips literal-valued map keys without converting them to keywords" do
      value = %{
        nil => "nil",
        true => "true",
        false => "false",
        Keyword.new("true") => "keyword-true",
        infinity: "infinity",
        negative_infinity: "negative-infinity",
        nan: "nan"
      }

      assert {:ok, source} = CoreToSource.export_namespace(%{"value" => value})
      assert source =~ "nil \"nil\""
      assert source =~ "true \"true\""
      assert source =~ "false \"false\""
      assert source =~ ":true \"keyword-true\""
      assert source =~ "##Inf \"infinity\""
      assert source =~ "##-Inf \"negative-infinity\""
      assert source =~ "##NaN \"nan\""

      assert {:ok, hydrated} = Lisp.run_native(source)
      assert hydrated.memory["value"] == value
    end

    test "rejects keyword wrappers whose source spelling rehydrates as a bounded atom" do
      keyword = Keyword.new("map")

      assert {:error, {:non_exportable_source_value, [{:binding, "value"}], ^keyword}} =
               CoreToSource.export_namespace(%{"value" => keyword})
    end

    test "rejects atom keywords whose source spelling rehydrates as a keyword wrapper" do
      keyword = :archive_custom_keyword

      assert {:error, {:non_exportable_source_value, [{:binding, "value"}], ^keyword}} =
               CoreToSource.export_namespace(%{"value" => keyword})

      assert {:error,
              {:non_exportable_source_value, [{:binding, "value"}, {:map_key, _index}], ^keyword}} =
               CoreToSource.export_namespace(%{"value" => %{keyword => "value"}})
    end

    test "rejects atom keywords in closure literal and map-key positions" do
      keyword = :archive_custom_keyword

      for body <- [
            {:keyword, keyword},
            keyword,
            {:map, [{{:keyword, keyword}, 1}]}
          ] do
        closure = {:closure, [], body, %{}, [], %{}}

        assert {:error, {:non_exportable_source_value, path, ^keyword}} =
                 CoreToSource.export_namespace(%{"value" => closure})

        assert [{:binding, "value"}, :closure_body | _rest] = path
      end
    end

    test "round-trips named functions and defonce forms nested in closures" do
      assert {:ok, first} =
               Lisp.run("""
               (do
                 (defn factorial []
                   (fn fact [n]
                     (if (<= n 1) 1 (* n (fact (dec n))))))
                 (defn initialize [] (defonce initialized 42)))
               """)

      assert {:ok, source} = CoreToSource.export_namespace(first.memory)
      assert {:ok, hydrated} = Lisp.run(source)

      assert {:ok, %{return: 120}} =
               Lisp.run("((factorial) 5)", memory: hydrated.memory)

      assert {:ok, initialized} = Lisp.run("(initialize)", memory: hydrated.memory)
      assert initialized.memory["initialized"] == 42
    end

    test "round-trips turn-history references inside exported closures" do
      assert {:ok, first} = Lisp.run("(defn previous [] *1)")
      assert {:ok, source} = CoreToSource.export_namespace(first.memory)
      assert source =~ "*1"
      assert {:ok, hydrated} = Lisp.run(source)

      assert {:ok, %{return: 42}} =
               Lisp.run("(previous)", memory: hydrated.memory, turn_history: [42])
    end

    test "round-trips attached-prelude references and calls inside exported closures" do
      assert {:ok, prelude} =
               Compiler.compile("""
               (ns crm "CRM helpers." {:visibility :prompt})
               (defn increment "Increment a number." [value] (inc value))
               """)

      assert {:ok, first} =
               Lisp.run(
                 """
                 (do
                   (defn call-increment [value] (crm/increment value))
                   (defn map-increment [value] (first (map crm/increment [value]))))
                 """,
                 prelude: prelude
               )

      assert {:ok, source} = CoreToSource.export_namespace(first.memory)
      assert {:ok, hydrated} = Lisp.run(source, prelude: prelude)

      assert {:ok, %{return: [42, 42]}} =
               Lisp.run("[(call-increment 41) (map-increment 41)]",
                 memory: hydrated.memory,
                 prelude: prelude
               )
    end

    test "rejects atom and string binding names that emit the same source symbol" do
      assert {:error, {:non_exportable_binding_collision, "map"}} =
               CoreToSource.export_namespace(%{:map => 1, "map" => 2})
    end

    test "rejects unsupported binding-key types before collision normalization" do
      assert {:error, {:non_exportable_source_name, [{:binding, 1}], :binding, 1}} =
               CoreToSource.export_namespace(%{1 => "value"})
    end

    test "rejects unsupported runtime values instead of raising while formatting" do
      assert {:error, {:non_exportable_source_value, [{:binding, "uri"}], %URI{}}} =
               CoreToSource.export_namespace(%{"uri" => %URI{}})
    end

    test "rejects struct-shaped namespace containers without raising" do
      for namespace <- [%URI{}, MapSet.new([1])] do
        module = namespace.__struct__

        assert {:error, {:non_exportable_namespace, ^module}} =
                 CoreToSource.serialize_namespace(namespace)

        assert {:error, {:non_exportable_namespace, ^module}} =
                 CoreToSource.export_namespace(namespace)
      end
    end

    test "rejects forged MapSet values before enumeration" do
      forged = Map.put(MapSet.new([1]), :map, :invalid)

      assert {:error, {:non_exportable_source_value, _path, ^forged}} =
               CoreToSource.export_namespace(%{"value" => forged})

      closure = {:closure, [], {:literal, forged}, %{}, [], %{}}

      assert {:error, {:non_exportable_source_value, _path, ^forged}} =
               CoreToSource.export_namespace(%{"set-fn" => closure})
    end

    test "rejects malformed closure CoreAST before dependency sorting" do
      malformed_bodies = [
        {:let, [:bad], 1},
        {:tool_call, "safe", 123},
        {:literal, {:tool_call, "safe", 123}}
      ]

      for body <- malformed_bodies do
        malformed = {:closure, [], body, %{}, [], %{}}

        assert {:error, {:non_exportable_source_value, _path, _value}} =
                 CoreToSource.export_namespace(%{"broken" => malformed})
      end
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

    test "orders a helper chain after shared non-closure dependencies" do
      assert {:ok, first} =
               Lisp.run("""
               (do
                 (def shared 2)
                 (defn helper [x] (+ shared x))
                 (defn caller [] (helper shared)))
               """)

      assert {:ok, source} = CoreToSource.export_namespace(first.memory)
      assert {:ok, hydrated} = Lisp.run(source)
      assert {:ok, %{return: 4}} = Lisp.run("(caller)", memory: hydrated.memory)
    end

    test "rejects cyclic closure dependencies that cannot be reloaded" do
      assert {:ok, first} = Lisp.run("(defn a [] 1)")
      assert {:ok, second} = Lisp.run("(defn b [] (a))", memory: first.memory)
      assert {:ok, third} = Lisp.run("(defn a [] (b))", memory: second.memory)

      assert {:error, {:non_exportable_dependency_cycle, ["a", "b"]}} =
               CoreToSource.export_namespace(third.memory)
    end

    test "does not reject reloadable references inside or as dependency cycles" do
      assert {:ok, first} = Lisp.run("(defn a [] (if (or b false) 1 0))")

      assert {:ok, second} =
               Lisp.run("(defn b [] (if (or a false) 2 0))", memory: first.memory)

      assert {:ok, source} = CoreToSource.export_namespace(second.memory)
      assert {:ok, hydrated} = Lisp.run(source)
      assert {:ok, %{return: 1}} = Lisp.run("(a)", memory: hydrated.memory)
    end

    test "does not treat a parameter matching a namespace binding as a dependency" do
      assert {:ok, first} =
               Lisp.run("""
               (do
                 (defn z-helper [a-caller] (+ a-caller 1))
                 (defn a-caller [] (z-helper 41)))
               """)

      assert {:ok, source} = CoreToSource.export_namespace(first.memory)
      assert {:ok, hydrated} = Lisp.run(source)
      assert {:ok, %{return: 42}} = Lisp.run("(a-caller)", memory: hydrated.memory)
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

    test "rejects native Java temporal values" do
      {:ok, local_date} =
        JavaLocalDate.parse(["2024-01-02"])

      {:ok, instant} =
        JavaInstant.parse(["2024-01-02T03:04:05Z"])

      assert {:error,
              {:non_exportable_java_value, [{:binding, "dates"}, {:index, 0}], :local_date}} =
               CoreToSource.export_namespace(%{"dates" => [local_date]})

      assert {:error, {:non_exportable_java_value, [{:binding, "instant"}], :instant}} =
               CoreToSource.export_namespace(%{"instant" => instant})
    end

    test "rejects malformed Java struct-shaped maps without destructuring them" do
      malformed_callable = %{__struct__: JavaCallable}
      malformed_primitive = %{__struct__: PtcRunner.Lisp.Java.Primitive, kind: :int}

      assert {:error, {:non_exportable_java_value, [{:binding, "parser"}], nil}} =
               CoreToSource.export_namespace(%{"parser" => malformed_callable})

      assert {:error, {:non_exportable_java_value, [{:binding, "value"}], :int}} =
               CoreToSource.export_namespace(%{"value" => malformed_primitive})
    end

    test "rejects forged keyword and symbol-reference wrappers without dropping fields" do
      forged_values = [
        %{__struct__: Format.SymbolRef, name: "x", extra: true},
        %{__struct__: PtcRunner.Lisp.Keyword, name: "novel", extra: true}
      ]

      for forged <- forged_values do
        assert {:error, {:non_exportable_source_value, [{:binding, "value"}], ^forged}} =
                 CoreToSource.export_namespace(%{"value" => forged})
      end
    end

    test "rejects binding names that cannot be emitted as one unqualified symbol" do
      name = "safe) (tool/evil {}) ;"

      assert {:error, {:non_exportable_source_name, [{:binding, ^name}], :binding, ^name}} =
               CoreToSource.export_namespace(%{name => 1})
    end

    test "rejects binding spellings that the reader treats as non-symbol values" do
      for name <- ["nil", "true", "false", "*1", "-1"] do
        assert {:error, {:non_exportable_source_name, [{:binding, ^name}], :binding, ^name}} =
                 CoreToSource.export_namespace(%{name => 1})

        closure = {:closure, [{:var, name}], {:return, 1}, %{}, [], %{}}

        assert {:error, {:non_exportable_source_name, _path, :binding, ^name}} =
                 CoreToSource.export_namespace(%{"f" => closure})

        closure = {:closure, [], {:return, {:var, name}}, %{}, [], %{}}

        assert {:error, {:non_exportable_source_name, _path, :var, ^name}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end

    test "rejects malformed symbol references nested in exported values and closures" do
      name = "safe) (tool/evil {}) ;"

      assert {:error,
              {:non_exportable_source_name, [{:binding, "value"}, {:map_value, 0}], :symbol_ref,
               ^name}} =
               CoreToSource.export_namespace(%{"value" => %{"ref" => {:symbol_ref, name}}})

      closure = {:closure, [], {:return, {:symbol_ref, name}}, %{}, [], %{}}

      assert {:error,
              {:non_exportable_source_name, [{:binding, "f"}, :closure_body, {:index, 1}],
               :symbol_ref, ^name}} =
               CoreToSource.export_namespace(%{"f" => closure})
    end

    test "rejects malformed reader symbols nested in literal AST values" do
      name = "safe) (tool/evil {}) ;"
      literal = {:literal, {:quoted_symbol, name}}

      assert {:error, {:non_exportable_source_value, [{:binding, "value"}], ^literal}} =
               CoreToSource.export_namespace(%{"value" => literal})
    end

    test "rejects parser symbols hidden in literal AST values" do
      for name <- ["x", "nil"] do
        literal = {:literal, {:symbol, name}}

        assert {:error, {:non_exportable_source_value, _path, ^literal}} =
                 CoreToSource.export_namespace(%{"value" => literal})
      end
    end

    test "rejects malformed turn-history references nested in literal AST values" do
      value = "1) (tool/evil {}) ;"
      literal = {:literal, {:turn_history, value}}

      assert {:error, {:non_exportable_source_value, [{:binding, "value"}], ^literal}} =
               CoreToSource.export_namespace(%{"value" => literal})
    end

    test "accepts quoted-symbol data keys emitted as a qualified reader symbol" do
      closure = {:closure, [], {:return, {:data, "'x"}}, %{}, [], %{}}

      assert {:ok, source} = CoreToSource.export_namespace(%{"read-ref" => closure})
      assert source == "(def read-ref (fn [] (return data/'x)))"
    end

    test "rejects data and tool names that do not round-trip as qualified symbols" do
      for {body, kind} <- [
            {{:data, ""}, :data},
            {{:tool_call, "", []}, :tool}
          ] do
        closure = {:closure, [], body, %{}, [], %{}}

        assert {:error, {:non_exportable_source_name, _path, ^kind, ""}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end

    test "accepts qualified runtime variables in exported closure bodies" do
      assert {:ok, first} = Lisp.run(~S|(defn parse-json [s] (json/parse-string s))|)
      assert {:ok, source} = CoreToSource.export_namespace(first.memory)
      assert source =~ "json/parse-string"
      assert {:ok, hydrated} = Lisp.run(source)

      assert {:ok, %{return: %{"ok" => true}}} =
               Lisp.run(~S|(parse-json "{\"ok\":true}")|, memory: hydrated.memory)
    end

    test "escapes quoted and backslashed string keys in destructuring patterns" do
      key = ~S|safe\") (tool/evil {}) ;|

      assert {:ok, first} =
               Lisp.run(~S|(defn read-key [{value "safe\\\") (tool/evil {}) ;"}] value)|)

      assert {:ok, source} = CoreToSource.export_namespace(first.memory)
      assert source =~ ~S|"safe\\\") (tool/evil {}) ;"|
      assert {:ok, hydrated} = Lisp.run(source)

      assert {:ok, %{return: 42}} =
               Lisp.run("(read-key data/input)",
                 memory: hydrated.memory,
                 context: %{"input" => %{key => 42}}
               )
    end

    test "rejects prelude refs that do not round-trip as exact namespaced symbols" do
      for body <- [
            {:prelude_ref, "nil"},
            {:prelude_ref, "crm"},
            {:prelude_ref, "crm/get/user"},
            {:prelude_ref, "-1/x"},
            {:prelude_call, "true", []}
          ] do
        closure = {:closure, [], body, %{}, [], %{}}

        assert {:error, {:non_exportable_source_name, _path, _kind, _value}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end

    test "prelude-reference exports ignore their discarded closure body for dependencies" do
      closure =
        {:closure, [], {:call, {:var, :helper}, :not_a_list}, %{}, [],
         %{prelude_ref: "crm/get-user"}}

      assert {:ok, "(def f crm/get-user)"} =
               CoreToSource.export_namespace(%{"f" => closure})
    end

    test "rejects runtime-callable nodes that do not round-trip with tool semantics" do
      for body <- [
            {:runtime_callable, :data, "x"},
            {:runtime_callable, "tool", "x"}
          ] do
        closure = {:closure, [], body, %{}, [], %{}}

        assert {:error, {:non_exportable_source_value, _path, _value}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end

    test "round-trips valid runtime-callable nodes with exact tool identity" do
      closure = {:closure, [], {:runtime_callable, :tool, "server/echo"}, %{}, [], %{}}

      assert {:ok, source} = CoreToSource.export_namespace(%{"f" => closure})
      assert source == "(def f (fn [] tool/server/echo))"

      assert {:ok, hydrated} =
               Lisp.run_native(source, tools: %{"server/echo" => fn args -> args end})

      assert {:closure, [], {:runtime_callable, :tool, "server/echo"}, _, _, _} =
               hydrated.memory["f"]
    end

    test "round-trips mixed keyword and string-key destructuring" do
      assert {:ok, first} =
               Lisp.run(~S|(defn read-mixed [{:keys [a] :strs [b]}] [a b])|)

      assert {:ok, source} = CoreToSource.export_namespace(first.memory)
      assert source =~ ":keys [a]"
      assert {:ok, hydrated} = Lisp.run(source)

      assert {:ok, %{return: [1, 2]}} =
               Lisp.run(~S|(read-mixed {:a 1 "b" 2})|, memory: hydrated.memory)
    end

    test "round-trips map :as destructuring with defaults" do
      source = ~S|(defn retain-all [{:keys [x] :or {x 1} :as m}] [x m])|

      assert {:ok, first} = Lisp.run(source)
      assert {:ok, exported} = CoreToSource.export_namespace(first.memory)
      assert exported =~ "{:keys [x] :or {x 1} :as m}"
      assert {:ok, hydrated} = Lisp.run(exported)

      assert {:ok, %{return: [1, %{"x" => 1}]}} =
               Lisp.run("(retain-all {:x 1})", memory: hydrated.memory)

      assert {:ok, %{return: [1, %{}]}} =
               Lisp.run("(retain-all {})", memory: hydrated.memory)
    end

    test "rejects malformed names in nested destructuring patterns" do
      name = "safe) (tool/evil {}) ;"

      patterns = [
        {:destructure, {:keys, [name], []}},
        {:destructure, {:keys, ["safe"], [{name, 1}]}},
        {:destructure, {:as, name, {:var, "safe"}}}
      ]

      for pattern <- patterns do
        closure = {:closure, [pattern], {:return, 1}, %{}, [], %{}}

        assert {:error, {:non_exportable_source_name, _path, :binding, ^name}} =
                 CoreToSource.export_namespace(%{"f" => closure})
      end
    end
  end

  test "formats closed Java instance and direct-dot nodes with Java source spelling" do
    assert CoreToSource.format(
             {:java_instance, :string_contains, {:var, :text}, [{:string, "x"}]}
           ) == ~S|(java.lang.String/contains text "x")|

    assert CoreToSource.format({:java_dot, :is_before, {:var, :value}, [{:var, :other}]}) ==
             ~S|(.isBefore value other)|
  end

  test "export and hydration preserve a fixed Java receiver class" do
    assert {:ok, first} =
             Lisp.run(~S|(def local-before (fn [left right] (LocalDate/isBefore left right)))|)

    assert {:ok, source} = CoreToSource.export_namespace(first.memory)
    assert source =~ "LocalDate/isBefore"

    assert {:ok, hydrated} = Lisp.run(source)

    assert {:error, %{fail: %{reason: :java_type_error}}} =
             Lisp.run(
               ~S|(local-before (Instant/parse "2024-01-01T00:00:00Z") (Instant/parse "2024-01-02T00:00:00Z"))|,
               memory: hydrated.memory
             )
  end

  test "export and hydration preserve the receiver class of a first-class Java instance method" do
    assert {:ok, first} =
             Lisp.run(~S|(def get-local-before (fn [] LocalDate/isBefore))|)

    assert {:ok, source} = CoreToSource.export_namespace(first.memory)
    assert source =~ "LocalDate/isBefore"

    assert {:ok, hydrated} = Lisp.run(source)

    assert {:ok, %{return: true}} =
             Lisp.run(
               ~S|(let [before (get-local-before)] (before (LocalDate/parse "2024-01-01") (LocalDate/parse "2024-01-02")))|,
               memory: hydrated.memory
             )
  end
end
