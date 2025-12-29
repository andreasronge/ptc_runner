defmodule PtcRunner.Lisp.AnalyzeSpecialFormsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "when desugars to if" do
    test "when becomes if with nil else" do
      raw = {:list, [{:symbol, :when}, true, 42]}
      assert {:ok, {:if, true, 42, nil}} = Analyze.analyze(raw)
    end

    test "when with symbol condition" do
      raw = {:list, [{:symbol, :when}, {:symbol, :check}, 100]}
      assert {:ok, {:if, {:var, :check}, 100, nil}} = Analyze.analyze(raw)
    end

    test "when with complex body" do
      raw = {:list, [{:symbol, :when}, true, {:list, [{:symbol, :+}, 1, 2]}]}
      assert {:ok, {:if, true, {:call, {:var, :+}, [1, 2]}, nil}} = Analyze.analyze(raw)
    end

    test "when with wrong arity fails" do
      raw = {:list, [{:symbol, :when}, true]}
      assert {:error, {:invalid_arity, :when, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end
  end

  describe "cond desugars to nested if" do
    test "simple cond" do
      raw =
        {:list,
         [
           {:symbol, :cond},
           {:symbol, :a},
           1,
           {:symbol, :b},
           2,
           {:keyword, :else},
           3
         ]}

      assert {:ok, {:if, {:var, :a}, 1, {:if, {:var, :b}, 2, 3}}} = Analyze.analyze(raw)
    end

    test "cond without else clause defaults to nil" do
      raw =
        {:list,
         [
           {:symbol, :cond},
           true,
           42,
           false,
           99
         ]}

      assert {:ok, {:if, true, 42, {:if, false, 99, nil}}} = Analyze.analyze(raw)
    end

    test "cond with single pair" do
      raw =
        {:list,
         [
           {:symbol, :cond},
           {:symbol, :x},
           100
         ]}

      assert {:ok, {:if, {:var, :x}, 100, nil}} = Analyze.analyze(raw)
    end

    test "cond empty fails" do
      raw = {:list, [{:symbol, :cond}]}
      assert {:error, {:invalid_cond_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "at least one"
    end

    test "cond with odd pairs fails" do
      raw =
        {:list,
         [
           {:symbol, :cond},
           true,
           1,
           false
         ]}

      assert {:error, {:invalid_cond_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "even number"
    end
  end

  describe "if special form" do
    test "basic if-then-else" do
      raw = {:list, [{:symbol, :if}, true, 1, 2]}
      assert {:ok, {:if, true, 1, 2}} = Analyze.analyze(raw)
    end

    test "if with expression condition" do
      raw =
        {:list,
         [
           {:symbol, :if},
           {:list, [{:symbol, :<}, {:symbol, :x}, 10]},
           {:string, "small"},
           {:string, "large"}
         ]}

      assert {:ok,
              {:if, {:call, {:var, :<}, [{:var, :x}, 10]}, {:string, "small"}, {:string, "large"}}} =
               Analyze.analyze(raw)
    end

    test "error case: wrong arity - too few arguments" do
      raw = {:list, [{:symbol, :if}, true]}
      assert {:error, {:invalid_arity, :if, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error case: wrong arity - too many arguments" do
      raw = {:list, [{:symbol, :if}, true, 1, 2, 3]}
      assert {:error, {:invalid_arity, :if, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end
  end

  describe "if-let special form" do
    test "if-let desugars to let wrapping if" do
      raw = {:list, [{:symbol, :"if-let"}, {:vector, [{:symbol, :x}, 42]}, {:symbol, :x}, 0]}

      assert {:ok, {:let, [{:binding, {:var, :x}, 42}], {:if, {:var, :x}, {:var, :x}, 0}}} =
               Analyze.analyze(raw)
    end

    test "if-let with expression condition" do
      raw =
        {:list,
         [
           {:symbol, :"if-let"},
           {:vector, [{:symbol, :user}, {:list, [{:symbol, :call}, {:string, "find"}]}]},
           {:symbol, :user},
           {:string, "not found"}
         ]}

      assert {:ok,
              {:let, [{:binding, {:var, :user}, {:call_tool, "find", {:map, []}}}],
               {:if, {:var, :user}, {:var, :user}, {:string, "not found"}}}} =
               Analyze.analyze(raw)
    end

    test "if-let without else defaults to nil" do
      raw = {:list, [{:symbol, :"if-let"}, {:vector, [{:symbol, :x}, 1]}, {:symbol, :x}]}
      assert {:ok, _} = Analyze.analyze(raw)
    end

    test "error: if-let with wrong binding count" do
      raw =
        {:list,
         [{:symbol, :"if-let"}, {:vector, [{:symbol, :x}, 1, {:symbol, :y}, 2]}, :ok, :err]}

      assert {:error, {:invalid_arity, :"if-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "if-let supports destructuring pattern" do
      raw =
        {:list,
         [
           {:symbol, :"if-let"},
           {:vector, [{:map, [{{:keyword, :keys}, {:vector, [{:symbol, :a}]}}]}, {:map, []}]},
           {:keyword, :ok},
           {:keyword, :err}
         ]}

      assert {:ok, _} = Analyze.analyze(raw)
    end

    test "error: if-let with non-vector binding" do
      raw = {:list, [{:symbol, :"if-let"}, {:symbol, :x}, {:symbol, :x}, 0]}
      assert {:error, {:invalid_arity, :"if-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error: if-let with empty vector" do
      raw = {:list, [{:symbol, :"if-let"}, {:vector, []}, {:symbol, :x}, 0]}
      assert {:error, {:invalid_arity, :"if-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end
  end

  describe "when-let special form" do
    test "when-let desugars to let wrapping if with nil else" do
      raw = {:list, [{:symbol, :"when-let"}, {:vector, [{:symbol, :x}, 42]}, {:symbol, :x}]}

      assert {:ok, {:let, [{:binding, {:var, :x}, 42}], {:if, {:var, :x}, {:var, :x}, nil}}} =
               Analyze.analyze(raw)
    end

    test "when-let with expression condition" do
      raw =
        {:list,
         [
           {:symbol, :"when-let"},
           {:vector, [{:symbol, :user}, {:list, [{:symbol, :call}, {:string, "find"}]}]},
           {:list, [{:symbol, :upper}, {:symbol, :user}]}
         ]}

      assert {:ok,
              {:let, [{:binding, {:var, :user}, {:call_tool, "find", {:map, []}}}],
               {:if, {:var, :user}, {:call, {:var, :upper}, [{:var, :user}]}, nil}}} =
               Analyze.analyze(raw)
    end

    test "error: when-let with wrong arity (missing body)" do
      raw = {:list, [{:symbol, :"when-let"}, {:vector, [{:symbol, :x}, 1]}]}
      assert {:error, {:invalid_arity, :"when-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error: when-let with wrong binding count" do
      raw =
        {:list, [{:symbol, :"when-let"}, {:vector, [{:symbol, :x}, 1, {:symbol, :y}, 2]}, :ok]}

      assert {:error, {:invalid_arity, :"when-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "when-let supports destructuring pattern" do
      raw =
        {:list,
         [
           {:symbol, :"when-let"},
           {:vector, [{:vector, [{:symbol, :a}]}, {:vector, []}]},
           {:keyword, :ok}
         ]}

      assert {:ok, _} = Analyze.analyze(raw)
    end

    test "error: when-let with non-vector binding" do
      raw = {:list, [{:symbol, :"when-let"}, {:symbol, :x}, {:symbol, :x}]}
      assert {:error, {:invalid_arity, :"when-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error: when-let with empty vector" do
      raw = {:list, [{:symbol, :"when-let"}, {:vector, []}, {:symbol, :x}]}
      assert {:error, {:invalid_arity, :"when-let", msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end
  end

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

    test "% outside #() is treated as regular symbol" do
      raw = {:symbol, :%}
      assert {:ok, {:var, :%}} = Analyze.analyze(raw)
    end
  end
end
