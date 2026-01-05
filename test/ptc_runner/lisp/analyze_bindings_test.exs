defmodule PtcRunner.Lisp.AnalyzeBindingsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  doctest PtcRunner.Lisp.Analyze.Patterns
  doctest PtcRunner.Lisp.Analyze.Predicates

  describe "let bindings" do
    test "simple bindings" do
      raw = {:list, [{:symbol, :let}, {:vector, [{:symbol, :x}, 1]}, {:symbol, :x}]}
      assert {:ok, {:let, [{:binding, {:var, :x}, 1}], {:var, :x}}} = Analyze.analyze(raw)
    end

    test "multiple bindings" do
      raw =
        {:list, [{:symbol, :let}, {:vector, [{:symbol, :x}, 1, {:symbol, :y}, 2]}, {:symbol, :y}]}

      assert {:ok, {:let, [{:binding, {:var, :x}, 1}, {:binding, {:var, :y}, 2}], {:var, :y}}} =
               Analyze.analyze(raw)
    end

    test "destructuring with :keys" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map, [{{:keyword, :keys}, {:vector, [{:symbol, :a}, {:symbol, :b}]}}]},
              {:symbol, :m}
            ]},
           {:symbol, :a}
         ]}

      assert {:ok,
              {:let,
               [
                 {:binding, {:destructure, {:keys, [:a, :b], []}}, {:var, :m}}
               ], {:var, :a}}} = Analyze.analyze(raw)
    end

    test "destructuring with :or defaults" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map,
               [
                 {{:keyword, :keys}, {:vector, [{:symbol, :a}]}},
                 {{:keyword, :or}, {:map, [{{:symbol, :a}, 10}]}}
               ]},
              {:symbol, :m}
            ]},
           {:symbol, :a}
         ]}

      assert {:ok,
              {:let,
               [
                 {:binding, {:destructure, {:keys, [:a], [a: 10]}}, {:var, :m}}
               ], {:var, :a}}} = Analyze.analyze(raw)
    end

    test "destructuring with :as alias" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map,
               [
                 {{:keyword, :keys}, {:vector, [{:symbol, :x}]}},
                 {{:keyword, :as}, {:symbol, :all}}
               ]},
              {:symbol, :m}
            ]},
           {:symbol, :all}
         ]}

      assert {:ok,
              {:let,
               [
                 {:binding, {:destructure, {:as, :all, {:destructure, {:keys, [:x], []}}}},
                  {:var, :m}}
               ], {:var, :all}}} = Analyze.analyze(raw)
    end

    test "error case: odd binding count" do
      raw = {:list, [{:symbol, :let}, {:vector, [{:symbol, :x}, 1, {:symbol, :y}]}, 100]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "even number"
    end

    test "error case: non-vector bindings" do
      raw = {:list, [{:symbol, :let}, 42, 100]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "vector"
    end

    test "error case: invalid key type in destructuring" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map, [{{:keyword, :keys}, {:vector, [123]}}]},
              {:symbol, :m}
            ]},
           {:symbol, :a}
         ]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "keyword or symbol"
    end

    test "error case: invalid default key type" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map,
               [
                 {{:keyword, :keys}, {:vector, [{:symbol, :x}]}},
                 {{:keyword, :or}, {:map, [{{:string, "x"}, 10}]}}
               ]},
              {:symbol, :m}
            ]},
           {:symbol, :x}
         ]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "default keys must be symbols"
    end

    test "destructuring with :or defaults using symbol keys" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map,
               [
                 {{:keyword, :keys}, {:vector, [{:symbol, :a}]}},
                 {{:keyword, :or}, {:map, [{{:symbol, :a}, 10}]}}
               ]},
              {:symbol, :m}
            ]},
           {:symbol, :a}
         ]}

      assert {:ok,
              {:let,
               [
                 {:binding, {:destructure, {:keys, [:a], [a: 10]}}, {:var, :m}}
               ], {:var, :a}}} = Analyze.analyze(raw)
    end

    test "destructuring with renaming bindings" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map,
               [
                 {{:keyword, :keys}, {:vector, [{:symbol, :id}]}},
                 {{:symbol, :the_name}, {:keyword, :name}}
               ]},
              {:symbol, :m}
            ]},
           {:symbol, :the_name}
         ]}

      assert {:ok,
              {:let,
               [
                 {:binding, {:destructure, {:map, [:id], [{:the_name, :name}], []}}, {:var, :m}}
               ], {:var, :the_name}}} = Analyze.analyze(raw)
    end

    test "destructuring with renaming and :or defaults" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map,
               [
                 {{:keyword, :keys}, {:vector, [{:symbol, :id}]}},
                 {{:symbol, :full_name}, {:keyword, :name}},
                 {{:keyword, :or}, {:map, [{{:symbol, :full_name}, "Unknown"}]}}
               ]},
              {:symbol, :m}
            ]},
           {:symbol, :full_name}
         ]}

      assert {:ok,
              {:let,
               [
                 {:binding,
                  {:destructure, {:map, [:id], [{:full_name, :name}], [full_name: "Unknown"]}},
                  {:var, :m}}
               ], {:var, :full_name}}} = Analyze.analyze(raw)
    end

    test "destructuring with renaming and :as alias" do
      raw =
        {:list,
         [
           {:symbol, :let},
           {:vector,
            [
              {:map,
               [
                 {{:keyword, :keys}, {:vector, [{:symbol, :id}]}},
                 {{:symbol, :the_name}, {:keyword, :name}},
                 {{:keyword, :as}, {:symbol, :m}}
               ]},
              {:symbol, :obj}
            ]},
           {:symbol, :the_name}
         ]}

      assert {:ok,
              {:let,
               [
                 {:binding,
                  {:destructure,
                   {:as, :m, {:destructure, {:map, [:id], [{:the_name, :name}], []}}}},
                  {:var, :obj}}
               ], {:var, :the_name}}} = Analyze.analyze(raw)
    end
  end

  describe "def scope validation" do
    alias PtcRunner.Lisp.Parser

    defp parse!(source) do
      {:ok, ast} = Parser.parse(source)
      ast
    end

    test "def inside let produces clear error" do
      assert {:error, {:invalid_form, msg}} =
               "(let [x 1] (def y x))" |> parse!() |> Analyze.analyze()

      assert msg =~ "def creates global"
      assert msg =~ "let for local"
    end

    test "def inside nested let produces clear error" do
      assert {:error, {:invalid_form, msg}} =
               "(let [a 1] (let [b 2] (def c 3)))" |> parse!() |> Analyze.analyze()

      assert msg =~ "def creates global"
    end

    test "def inside fn produces clear error" do
      assert {:error, {:invalid_form, msg}} =
               "(fn [] (def x 1))" |> parse!() |> Analyze.analyze()

      assert msg =~ "def creates global"
    end

    test "defn inside let produces clear error" do
      assert {:error, {:invalid_form, msg}} =
               "(let [x 1] (defn f [] x))" |> parse!() |> Analyze.analyze()

      assert msg =~ "defn creates global"
    end

    test "defn inside fn produces clear error" do
      assert {:error, {:invalid_form, msg}} =
               "(fn [] (defn f [] 1))" |> parse!() |> Analyze.analyze()

      assert msg =~ "defn creates global"
    end

    test "def at top level succeeds" do
      assert {:ok, _} = "(def x 1)" |> parse!() |> Analyze.analyze()
    end

    test "def at top level inside do succeeds" do
      assert {:ok, _} = "(do (def x 1) (def y 2))" |> parse!() |> Analyze.analyze()
    end

    test "def in let inside do at top level still errors (do preserves scope)" do
      assert {:error, {:invalid_form, msg}} =
               "(do (let [x 1] (def y x)))" |> parse!() |> Analyze.analyze()

      assert msg =~ "def creates global"
    end

    test "def inside if-let body produces error" do
      assert {:error, {:invalid_form, msg}} =
               "(if-let [x 1] (def y x) nil)" |> parse!() |> Analyze.analyze()

      assert msg =~ "def creates global"
    end

    test "def inside when-let body produces error" do
      assert {:error, {:invalid_form, msg}} =
               "(when-let [x 1] (def y x))" |> parse!() |> Analyze.analyze()

      assert msg =~ "def creates global"
    end

    test "def inside #() short function produces error" do
      # #(def x %) desugars to (fn [p1] (def x p1))
      raw = {:short_fn, [{:symbol, :def}, {:symbol, :x}, {:symbol, :%}]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "def creates global"
    end
  end
end
