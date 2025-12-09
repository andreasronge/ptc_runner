defmodule PtcRunner.Lisp.AnalyzeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "literals pass through" do
    test "nil" do
      assert {:ok, nil} = Analyze.analyze(nil)
    end

    test "booleans" do
      assert {:ok, true} = Analyze.analyze(true)
      assert {:ok, false} = Analyze.analyze(false)
    end

    test "integers" do
      assert {:ok, 42} = Analyze.analyze(42)
      assert {:ok, -10} = Analyze.analyze(-10)
      assert {:ok, 0} = Analyze.analyze(0)
    end

    test "floats" do
      assert {:ok, 3.14} = Analyze.analyze(3.14)
      assert {:ok, -2.5} = Analyze.analyze(-2.5)
    end

    test "strings" do
      assert {:ok, {:string, "hello"}} = Analyze.analyze({:string, "hello"})
      assert {:ok, {:string, ""}} = Analyze.analyze({:string, ""})
    end

    test "keywords" do
      assert {:ok, {:keyword, :name}} = Analyze.analyze({:keyword, :name})
      assert {:ok, {:keyword, :status}} = Analyze.analyze({:keyword, :status})
    end
  end

  describe "vectors" do
    test "empty vector" do
      assert {:ok, {:vector, []}} = Analyze.analyze({:vector, []})
    end

    test "vector with literals" do
      assert {:ok, {:vector, [1, 2, 3]}} = Analyze.analyze({:vector, [1, 2, 3]})
    end

    test "vector with mixed types" do
      assert {:ok, {:vector, [1, {:string, "test"}, {:keyword, :foo}]}} =
               Analyze.analyze({:vector, [1, {:string, "test"}, {:keyword, :foo}]})
    end

    test "nested vectors" do
      assert {:ok, {:vector, [{:vector, [1, 2]}, {:vector, [3, 4]}]}} =
               Analyze.analyze({:vector, [{:vector, [1, 2]}, {:vector, [3, 4]}]})
    end
  end

  describe "maps" do
    test "empty map" do
      assert {:ok, {:map, []}} = Analyze.analyze({:map, []})
    end

    test "map with literal keys and values" do
      assert {:ok, {:map, [{{:keyword, :name}, {:string, "test"}}]}} =
               Analyze.analyze({:map, [{{:keyword, :name}, {:string, "test"}}]})
    end

    test "map with multiple pairs" do
      assert {:ok, {:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]}} =
               Analyze.analyze({:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]})
    end

    test "nested maps" do
      inner = {:map, [{{:keyword, :x}, 1}]}

      assert {:ok, {:map, [{{:keyword, :outer}, ^inner}]}} =
               Analyze.analyze({:map, [{{:keyword, :outer}, inner}]})
    end
  end

  describe "sets" do
    test "empty set" do
      assert {:ok, {:set, []}} = Analyze.analyze({:set, []})
    end

    test "set with literals" do
      assert {:ok, {:set, [1, 2, 3]}} = Analyze.analyze({:set, [1, 2, 3]})
    end

    test "set with symbols analyzed to vars" do
      assert {:ok, {:set, [{:var, :x}, {:var, :y}]}} =
               Analyze.analyze({:set, [{:symbol, :x}, {:symbol, :y}]})
    end

    test "nested set" do
      assert {:ok, {:set, [{:set, [1, 2]}]}} =
               Analyze.analyze({:set, [{:set, [1, 2]}]})
    end

    test "set containing vector" do
      assert {:ok, {:set, [{:vector, [1, 2]}]}} =
               Analyze.analyze({:set, [{:vector, [1, 2]}]})
    end

    test "set with mixed types" do
      assert {:ok, {:set, [1, {:string, "test"}, {:keyword, :foo}]}} =
               Analyze.analyze({:set, [1, {:string, "test"}, {:keyword, :foo}]})
    end
  end

  describe "symbols become vars" do
    test "regular symbol becomes var" do
      assert {:ok, {:var, :filter}} = Analyze.analyze({:symbol, :filter})
    end

    test "multiple symbol examples" do
      assert {:ok, {:var, :x}} = Analyze.analyze({:symbol, :x})
      assert {:ok, {:var, :count}} = Analyze.analyze({:symbol, :count})
      assert {:ok, {:var, :is_valid?}} = Analyze.analyze({:symbol, :is_valid?})
    end

    test "ctx namespace symbol" do
      assert {:ok, {:ctx, :input}} = Analyze.analyze({:ns_symbol, :ctx, :input})
    end

    test "multiple ctx symbols" do
      assert {:ok, {:ctx, :data}} = Analyze.analyze({:ns_symbol, :ctx, :data})
      assert {:ok, {:ctx, :query}} = Analyze.analyze({:ns_symbol, :ctx, :query})
    end

    test "memory namespace symbol" do
      assert {:ok, {:memory, :results}} = Analyze.analyze({:ns_symbol, :memory, :results})
    end

    test "multiple memory symbols" do
      assert {:ok, {:memory, :cache}} = Analyze.analyze({:ns_symbol, :memory, :cache})
      assert {:ok, {:memory, :counter}} = Analyze.analyze({:ns_symbol, :memory, :counter})
    end
  end

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

  describe "threading desugars to nested calls" do
    test "thread-first" do
      raw =
        {:list,
         [
           {:symbol, :->},
           {:symbol, :x},
           {:list, [{:symbol, :f}, {:symbol, :a}]}
         ]}

      assert {:ok,
              {:call, {:var, :f},
               [
                 {:var, :x},
                 {:var, :a}
               ]}} = Analyze.analyze(raw)
    end

    test "thread-last" do
      raw =
        {:list,
         [
           {:symbol, :"->>"},
           {:symbol, :x},
           {:list, [{:symbol, :f}, {:symbol, :a}]},
           {:list, [{:symbol, :g}, {:symbol, :b}]}
         ]}

      assert {:ok,
              {:call, {:var, :g},
               [
                 {:var, :b},
                 {:call, {:var, :f},
                  [
                    {:var, :a},
                    {:var, :x}
                  ]}
               ]}} = Analyze.analyze(raw)
    end

    test "thread with symbol step" do
      raw =
        {:list,
         [
           {:symbol, :->},
           {:symbol, :x},
           {:symbol, :f}
         ]}

      assert {:ok,
              {:call, {:var, :f},
               [
                 {:var, :x}
               ]}} = Analyze.analyze(raw)
    end

    test "thread with no expressions fails" do
      raw = {:list, [{:symbol, :->}]}
      assert {:error, {:invalid_thread_form, :->, msg}} = Analyze.analyze(raw)
      assert msg =~ "at least one"
    end
  end

  describe "where validation" do
    test "valid where with operator" do
      raw = {:list, [{:symbol, :where}, {:keyword, :status}, {:symbol, :=}, {:string, "active"}]}

      assert {:ok, {:where, {:field, [{:keyword, :status}]}, :eq, {:string, "active"}}} =
               Analyze.analyze(raw)
    end

    test "truthy check (single arg)" do
      raw = {:list, [{:symbol, :where}, {:keyword, :active}]}

      assert {:ok, {:where, {:field, [{:keyword, :active}]}, :truthy, nil}} =
               Analyze.analyze(raw)
    end

    test "where with various operators" do
      operators = [
        {:=, :eq},
        {:"not=", :not_eq},
        {:>, :gt},
        {:<, :lt},
        {:>=, :gte},
        {:<=, :lte},
        {:includes, :includes},
        {:in, :in}
      ]

      for {sym_op, core_op} <- operators do
        raw = {:list, [{:symbol, :where}, {:keyword, :field}, {:symbol, sym_op}, 42]}

        assert {:ok, {:where, {:field, [{:keyword, :field}]}, ^core_op, 42}} =
                 Analyze.analyze(raw)
      end
    end

    test "where with vector field path" do
      raw =
        {:list,
         [
           {:symbol, :where},
           {:vector, [{:keyword, :user}, {:keyword, :name}]},
           {:symbol, :=},
           {:string, "John"}
         ]}

      assert {:ok,
              {:where, {:field, [{:keyword, :user}, {:keyword, :name}]}, :eq, {:string, "John"}}} =
               Analyze.analyze(raw)
    end

    test "invalid operator fails" do
      raw = {:list, [{:symbol, :where}, {:keyword, :x}, {:symbol, :like}, {:string, "foo"}]}
      assert {:error, {:invalid_where_operator, :like}} = Analyze.analyze(raw)
    end

    test "invalid field type fails" do
      raw = {:list, [{:symbol, :where}, 42]}
      assert {:error, {:invalid_where_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "field"
    end

    test "wrong arity fails" do
      raw = {:list, [{:symbol, :where}]}
      assert {:error, {:invalid_where_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end

    test "error case: invalid field path element type" do
      raw = {:list, [{:symbol, :where}, {:vector, [123]}, {:symbol, :=}, 1]}
      assert {:error, {:invalid_where_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "keywords or strings"
    end
  end

  describe "predicate combinators" do
    test "empty all-of" do
      raw = {:list, [{:symbol, :"all-of"}]}
      assert {:ok, {:pred_combinator, :all_of, []}} = Analyze.analyze(raw)
    end

    test "empty any-of" do
      raw = {:list, [{:symbol, :"any-of"}]}
      assert {:ok, {:pred_combinator, :any_of, []}} = Analyze.analyze(raw)
    end

    test "empty none-of" do
      raw = {:list, [{:symbol, :"none-of"}]}
      assert {:ok, {:pred_combinator, :none_of, []}} = Analyze.analyze(raw)
    end

    test "all-of with predicates" do
      raw =
        {:list,
         [
           {:symbol, :"all-of"},
           {:list, [{:symbol, :where}, {:keyword, :x}]},
           {:list, [{:symbol, :where}, {:keyword, :y}]}
         ]}

      assert {:ok,
              {:pred_combinator, :all_of,
               [
                 {:where, {:field, [{:keyword, :x}]}, :truthy, nil},
                 {:where, {:field, [{:keyword, :y}]}, :truthy, nil}
               ]}} = Analyze.analyze(raw)
    end
  end

  describe "call tool invocation" do
    test "call with just tool name" do
      raw = {:list, [{:symbol, :call}, {:string, "get-users"}]}
      assert {:ok, {:call_tool, "get-users", {:map, []}}} = Analyze.analyze(raw)
    end

    test "call with args" do
      raw = {:list, [{:symbol, :call}, {:string, "filter-data"}, {:map, []}]}
      assert {:ok, {:call_tool, "filter-data", {:map, []}}} = Analyze.analyze(raw)
    end

    test "call with args containing data" do
      raw =
        {:list,
         [
           {:symbol, :call},
           {:string, "search"},
           {:map, [{{:keyword, :query}, {:string, "test"}}]}
         ]}

      assert {:ok, {:call_tool, "search", {:map, [{{:keyword, :query}, {:string, "test"}}]}}} =
               Analyze.analyze(raw)
    end

    test "call with non-string name fails" do
      raw = {:list, [{:symbol, :call}, {:symbol, :"get-users"}]}
      assert {:error, {:invalid_call_tool_name, msg}} = Analyze.analyze(raw)
      assert msg =~ "string literal"
    end

    test "call with non-map args fails" do
      raw = {:list, [{:symbol, :call}, {:string, "get"}, {:vector, [1, 2]}]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "map"
    end

    test "call with wrong arity fails" do
      raw = {:list, [{:symbol, :call}]}
      assert {:error, {:invalid_arity, :call, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected"
    end
  end

  describe "comparison operators (strict 2-arity)" do
    test "less than" do
      raw = {:list, [{:symbol, :<}, 1, 2]}
      assert {:ok, {:call, {:var, :<}, [1, 2]}} = Analyze.analyze(raw)
    end

    test "all comparison operators with 2 args" do
      for op <- [:=, :"not=", :>, :<, :>=, :<=] do
        raw = {:list, [{:symbol, op}, {:symbol, :a}, {:symbol, :b}]}
        assert {:ok, {:call, {:var, ^op}, [{:var, :a}, {:var, :b}]}} = Analyze.analyze(raw)
      end
    end

    test "comparison with literals" do
      raw = {:list, [{:symbol, :=}, {:string, "x"}, {:string, "y"}]}

      assert {:ok,
              {:call, {:var, :=},
               [
                 {:string, "x"},
                 {:string, "y"}
               ]}} = Analyze.analyze(raw)
    end

    test "chained comparison (3 args) fails" do
      raw = {:list, [{:symbol, :<}, 1, 2, 3]}
      assert {:error, {:invalid_arity, :<, msg}} = Analyze.analyze(raw)
      assert msg =~ "exactly 2 arguments"
      assert msg =~ "got 3"
    end

    test "single arg comparison fails" do
      raw = {:list, [{:symbol, :>}, 1]}
      assert {:error, {:invalid_arity, :>, msg}} = Analyze.analyze(raw)
      assert msg =~ "exactly 2 arguments"
      assert msg =~ "got 1"
    end

    test "zero arg comparison fails" do
      raw = {:list, [{:symbol, :=}]}
      assert {:error, {:invalid_arity, :=, msg}} = Analyze.analyze(raw)
      assert msg =~ "exactly 2 arguments"
      assert msg =~ "got 0"
    end
  end

  describe "generic function calls" do
    test "simple call with no args" do
      raw = {:list, [{:symbol, :f}]}
      assert {:ok, {:call, {:var, :f}, []}} = Analyze.analyze(raw)
    end

    test "call with literal args" do
      raw = {:list, [{:symbol, :+}, 1, 2]}
      assert {:ok, {:call, {:var, :+}, [1, 2]}} = Analyze.analyze(raw)
    end

    test "call with symbol args" do
      raw = {:list, [{:symbol, :f}, {:symbol, :x}, {:symbol, :y}]}

      assert {:ok,
              {:call, {:var, :f},
               [
                 {:var, :x},
                 {:var, :y}
               ]}} = Analyze.analyze(raw)
    end

    test "nested calls" do
      raw =
        {:list,
         [
           {:symbol, :f},
           {:list, [{:symbol, :g}, 1]}
         ]}

      assert {:ok,
              {:call, {:var, :f},
               [
                 {:call, {:var, :g}, [1]}
               ]}} = Analyze.analyze(raw)
    end

    test "function as keyword (map access)" do
      raw = {:list, [{:keyword, :name}, {:symbol, :user}]}

      assert {:ok,
              {:call, {:keyword, :name},
               [
                 {:var, :user}
               ]}} = Analyze.analyze(raw)
    end
  end

  describe "short-circuit logic" do
    test "empty and" do
      raw = {:list, [{:symbol, :and}]}
      assert {:ok, {:and, []}} = Analyze.analyze(raw)
    end

    test "and with expressions" do
      raw = {:list, [{:symbol, :and}, true, false, 42]}
      assert {:ok, {:and, [true, false, 42]}} = Analyze.analyze(raw)
    end

    test "empty or" do
      raw = {:list, [{:symbol, :or}]}
      assert {:ok, {:or, []}} = Analyze.analyze(raw)
    end

    test "or with expressions" do
      raw = {:list, [{:symbol, :or}, nil, false, 42]}
      assert {:ok, {:or, [nil, false, 42]}} = Analyze.analyze(raw)
    end

    test "and/or with nested calls" do
      raw =
        {:list,
         [
           {:symbol, :and},
           {:list, [{:symbol, :f}, {:symbol, :x}]},
           {:list, [{:symbol, :g}, {:symbol, :y}]}
         ]}

      assert {:ok,
              {:and,
               [
                 {:call, {:var, :f},
                  [
                    {:var, :x}
                  ]},
                 {:call, {:var, :g},
                  [
                    {:var, :y}
                  ]}
               ]}} = Analyze.analyze(raw)
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
                 {{:keyword, :or}, {:map, [{{:keyword, :a}, 10}]}}
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
      assert msg =~ "default keys must be keywords"
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

  describe "empty list fails" do
    test "empty list is invalid" do
      raw = {:list, []}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "Empty list"
    end
  end
end
