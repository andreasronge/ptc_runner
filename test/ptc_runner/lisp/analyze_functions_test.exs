defmodule PtcRunner.Lisp.AnalyzeFunctionsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "fn anonymous functions" do
    test "single parameter" do
      raw = {:list, [{:symbol, :fn}, {:vector, [{:symbol, :x}]}, {:symbol, :x}]}
      assert {:ok, {:fn, [{:var, :x}], {:var, :x}}} = Analyze.analyze(raw)
    end

    test "multiple parameters" do
      raw =
        {:list,
         [
           {:symbol, :fn},
           {:vector, [{:symbol, :x}, {:symbol, :y}]},
           {:list, [{:symbol, :+}, {:symbol, :x}, {:symbol, :y}]}
         ]}

      assert {:ok, {:fn, [{:var, :x}, {:var, :y}], {:call, {:var, :+}, [{:var, :x}, {:var, :y}]}}} =
               Analyze.analyze(raw)
    end

    test "error case: non-vector params" do
      raw = {:list, [{:symbol, :fn}, 42, 100]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "vector"
    end

    test "map destructuring pattern in params" do
      raw =
        {:list,
         [
           {:symbol, :fn},
           {:vector, [{:map, [{{:keyword, :keys}, {:vector, [{:symbol, :a}]}}]}]},
           100
         ]}

      assert {:ok, {:fn, [pattern], 100}} = Analyze.analyze(raw)
      assert {:destructure, {:keys, [:a], []}} = pattern
    end

    test "vector destructuring pattern in params" do
      raw =
        {:list,
         [
           {:symbol, :fn},
           {:vector, [{:vector, [{:symbol, :a}, {:symbol, :b}]}]},
           {:symbol, :a}
         ]}

      assert {:ok, {:fn, [pattern], {:var, :a}}} = Analyze.analyze(raw)
      assert {:destructure, {:seq, [{:var, :a}, {:var, :b}]}} = pattern
    end

    test "nested vector pattern" do
      # (fn [[[a b] c]] ...)
      raw =
        {:list,
         [
           {:symbol, :fn},
           {:vector, [{:vector, [{:vector, [{:symbol, :a}, {:symbol, :b}]}, {:symbol, :c}]}]},
           {:symbol, :a}
         ]}

      assert {:ok, {:fn, [pattern], {:var, :a}}} = Analyze.analyze(raw)

      assert {:destructure,
              {:seq, [{:destructure, {:seq, [{:var, :a}, {:var, :b}]}}, {:var, :c}]}} =
               pattern
    end

    test "vector with nested map pattern" do
      # (fn [[k {:keys [v]}]] ...)
      raw =
        {:list,
         [
           {:symbol, :fn},
           {:vector,
            [
              {:vector,
               [
                 {:symbol, :k},
                 {:map, [{{:keyword, :keys}, {:vector, [{:symbol, :v}]}}]}
               ]}
            ]},
           {:symbol, :v}
         ]}

      assert {:ok, {:fn, [pattern], {:var, :v}}} = Analyze.analyze(raw)
      assert {:destructure, {:seq, [{:var, :k}, {:destructure, {:keys, [:v], []}}]}} = pattern
    end

    test "mixed simple and destructuring params" do
      # (fn [x [a b]] ...)
      raw =
        {:list,
         [
           {:symbol, :fn},
           {:vector, [{:symbol, :x}, {:vector, [{:symbol, :a}, {:symbol, :b}]}]},
           {:symbol, :x}
         ]}

      assert {:ok, {:fn, [param1, param2], {:var, :x}}} = Analyze.analyze(raw)
      assert {:var, :x} = param1
      assert {:destructure, {:seq, [{:var, :a}, {:var, :b}]}} = param2
    end

    test "error on invalid pattern type (number)" do
      raw = {:list, [{:symbol, :fn}, {:vector, [42]}, 100]}
      assert {:error, {:unsupported_pattern, 42}} = Analyze.analyze(raw)
    end

    test "empty vector pattern" do
      raw =
        {:list,
         [
           {:symbol, :fn},
           {:vector, [{:vector, []}]},
           100
         ]}

      assert {:ok, {:fn, [pattern], 100}} = Analyze.analyze(raw)
      assert {:destructure, {:seq, []}} = pattern
    end
  end

  describe "short function syntax #()" do
    test "simple identity function #(%)" do
      raw = {:short_fn, [{:symbol, :%}]}
      assert {:ok, {:fn, [{:var, :p1}], {:var, :p1}}} = Analyze.analyze(raw)
    end

    test "#(+ % 1) desugars to fn with arithmetic" do
      raw = {:short_fn, [{:symbol, :+}, {:symbol, :%}, 1]}

      assert {:ok, {:fn, [{:var, :p1}], {:call, {:var, :+}, [{:var, :p1}, 1]}}} =
               Analyze.analyze(raw)
    end

    test "#(+ %1 %2) creates binary function" do
      raw = {:short_fn, [{:symbol, :+}, {:symbol, :"%1"}, {:symbol, :"%2"}]}

      assert {:ok,
              {:fn, [{:var, :p1}, {:var, :p2}], {:call, {:var, :+}, [{:var, :p1}, {:var, :p2}]}}} =
               Analyze.analyze(raw)
    end

    test "#(* % %) uses same param twice" do
      raw = {:short_fn, [{:symbol, :*}, {:symbol, :%}, {:symbol, :%}]}

      assert {:ok, {:fn, [{:var, :p1}], {:call, {:var, :*}, [{:var, :p1}, {:var, :p1}]}}} =
               Analyze.analyze(raw)
    end

    test "#(+ %3 %1) creates arity 3 with unused %2" do
      raw = {:short_fn, [{:symbol, :+}, {:symbol, :"%3"}, {:symbol, :"%1"}]}

      assert {:ok,
              {:fn, [{:var, :p1}, {:var, :p2}, {:var, :p3}],
               {:call, {:var, :+}, [{:var, :p3}, {:var, :p1}]}}} =
               Analyze.analyze(raw)
    end

    test "#(42) creates zero-arity thunk" do
      raw = {:short_fn, [42]}
      assert {:ok, {:fn, [], 42}} = Analyze.analyze(raw)
    end

    test "#(%) is identity function" do
      raw = {:short_fn, [{:symbol, :%}]}
      assert {:ok, {:fn, [{:var, :p1}], {:var, :p1}}} = Analyze.analyze(raw)
    end

    test "#(str \"id-\" %) with multiple args" do
      raw = {:short_fn, [{:symbol, :str}, {:string, "id-"}, {:symbol, :%}]}

      assert {:ok, {:fn, [{:var, :p1}], {:call, {:var, :str}, [{:string, "id-"}, {:var, :p1}]}}} =
               Analyze.analyze(raw)
    end

    test "nested #() raises error" do
      raw = {:short_fn, [{:short_fn, [{:symbol, :%}]}]}
      assert {:error, _} = Analyze.analyze(raw)
    end

    test "% outside #() returns error" do
      raw = {:symbol, :%}
      assert {:error, {:invalid_placeholder, :%}} = Analyze.analyze(raw)
    end

    test "%1 outside #() returns error" do
      raw = {:symbol, :"%1"}
      assert {:error, {:invalid_placeholder, :"%1"}} = Analyze.analyze(raw)
    end

    test "% in expression returns error" do
      raw = {:list, [{:symbol, :+}, {:symbol, :%}, 1]}
      assert {:error, {:invalid_placeholder, :%}} = Analyze.analyze(raw)
    end
  end
end
