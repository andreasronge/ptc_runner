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
      assert {:ok, true} = Analyze.analyze(raw)
    end

    test "and with expressions" do
      raw = {:list, [{:symbol, :and}, true, false, 42]}
      assert {:ok, {:and, [true, false, 42]}} = Analyze.analyze(raw)
    end

    test "empty or" do
      raw = {:list, [{:symbol, :or}]}
      assert {:ok, nil} = Analyze.analyze(raw)
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

  describe "comparison operators" do
    test "less than" do
      raw = {:list, [{:symbol, :<}, 1, 2]}
      assert {:ok, {:call, {:var, :<}, [1, 2]}} = Analyze.analyze(raw)
    end

    test "all comparison operators with 2 args" do
      for op <- [:=, :==, :"not=", :>, :<, :>=, :<=] do
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

    test "ordered zero arg comparison fails" do
      raw = {:list, [{:symbol, :<}]}
      assert {:error, {:invalid_arity, :<, msg}} = Analyze.analyze(raw)
      assert msg =~ "exactly 2 arguments"
      assert msg =~ "got 0"
    end

    test "equality operators are variadic" do
      raw = {:list, [{:symbol, :=}]}
      assert {:ok, {:call, {:var, :=}, []}} = Analyze.analyze(raw)

      raw = {:list, [{:symbol, :"not="}, 1, 2, 3]}
      assert {:ok, {:call, {:var, :"not="}, [1, 2, 3]}} = Analyze.analyze(raw)
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

  describe "tool/ invocation syntax" do
    test "tool/ with no args" do
      raw = {:list, [{:ns_symbol, :tool, :"get-users"}]}
      assert {:ok, {:tool_call, :"get-users", []}} = Analyze.analyze(raw)
    end

    test "tool/ with map arg" do
      raw =
        {:list, [{:ns_symbol, :tool, :search}, {:map, [{{:keyword, :query}, {:string, "test"}}]}]}

      assert {:ok, {:tool_call, :search, [{:map, [{{:keyword, :query}, {:string, "test"}}]}]}} =
               Analyze.analyze(raw)
    end

    test "tool/ with multiple args" do
      raw =
        {:list, [{:ns_symbol, :tool, :"fetch-user"}, 123, {:keyword, :include_details}]}

      assert {:ok, {:tool_call, :"fetch-user", [123, {:keyword, :include_details}]}} =
               Analyze.analyze(raw)
    end

    test "tool/ with nested expression args" do
      raw =
        {:list,
         [
           {:ns_symbol, :tool, :search},
           {:map, [{{:keyword, :query}, {:list, [{:symbol, :str}, {:string, "test"}]}}]}
         ]}

      assert {:ok,
              {:tool_call, :search,
               [{:map, [{{:keyword, :query}, {:call, {:var, :str}, [{:string, "test"}]}}]}]}} =
               Analyze.analyze(raw)
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
