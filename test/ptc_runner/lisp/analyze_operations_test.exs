defmodule PtcRunner.Lisp.AnalyzeOperationsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

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

  describe "empty list fails" do
    test "empty list is invalid" do
      raw = {:list, []}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "Empty list"
    end
  end

  describe "juxt function combinator" do
    test "empty juxt" do
      raw = {:list, [{:symbol, :juxt}]}
      assert {:ok, {:juxt, []}} = Analyze.analyze(raw)
    end

    test "single function juxt" do
      raw = {:list, [{:symbol, :juxt}, {:keyword, :name}]}
      assert {:ok, {:juxt, [{:keyword, :name}]}} = Analyze.analyze(raw)
    end

    test "multiple functions juxt" do
      raw = {:list, [{:symbol, :juxt}, {:keyword, :name}, {:keyword, :age}]}
      assert {:ok, {:juxt, [{:keyword, :name}, {:keyword, :age}]}} = Analyze.analyze(raw)
    end

    test "juxt with closures" do
      raw =
        {:list,
         [
           {:symbol, :juxt},
           {:short_fn, [{:list, [{:symbol, :+}, {:symbol, :%}, 1]}]},
           {:short_fn, [{:list, [{:symbol, :*}, {:symbol, :%}, 2]}]}
         ]}

      assert {:ok, {:juxt, [fn1, fn2]}} = Analyze.analyze(raw)
      assert match?({:fn, _, _}, fn1)
      assert match?({:fn, _, _}, fn2)
    end

    test "juxt with mixed function types" do
      raw =
        {:list,
         [
           {:symbol, :juxt},
           {:keyword, :priority},
           {:symbol, :first}
         ]}

      assert {:ok, {:juxt, [{:keyword, :priority}, {:var, :first}]}} = Analyze.analyze(raw)
    end
  end
end
