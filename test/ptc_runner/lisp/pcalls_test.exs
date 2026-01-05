defmodule PtcRunner.Lisp.PcallsTest do
  @moduledoc """
  Tests for pcalls (parallel calls) special form.
  """
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.{Analyze, Env, Eval}

  describe "analyze pcalls" do
    test "pcalls with multiple thunks produces {:pcalls, [fn_cores]} AST" do
      # (pcalls #(+ 1 1) #(+ 2 2))
      raw =
        {:list,
         [
           {:symbol, :pcalls},
           {:short_fn, [{:list, [{:symbol, :+}, 1, 1]}]},
           {:short_fn, [{:list, [{:symbol, :+}, 2, 2]}]}
         ]}

      assert {:ok, {:pcalls, [fn1, fn2]}} = Analyze.analyze(raw)
      assert {:fn, [], _body1} = fn1
      assert {:fn, [], _body2} = fn2
    end

    test "pcalls with zero arguments produces {:pcalls, []}" do
      raw = {:list, [{:symbol, :pcalls}]}
      assert {:ok, {:pcalls, []}} = Analyze.analyze(raw)
    end

    test "pcalls with single argument is valid" do
      raw = {:list, [{:symbol, :pcalls}, {:short_fn, [1]}]}
      assert {:ok, {:pcalls, [_fn]}} = Analyze.analyze(raw)
    end

    test "pcalls with anonymous function syntax" do
      # (pcalls (fn [] 42))
      raw =
        {:list,
         [
           {:symbol, :pcalls},
           {:list, [{:symbol, :fn}, {:vector, []}, 42]}
         ]}

      assert {:ok, {:pcalls, [{:fn, [], 42}]}} = Analyze.analyze(raw)
    end
  end

  describe "eval pcalls" do
    test "pcalls with multiple pure thunks returns vector of results" do
      env = Env.initial()
      # (pcalls #(+ 1 1) #(* 2 3) #(- 10 5))
      ast =
        {:pcalls,
         [
           {:fn, [], {:call, {:var, :+}, [1, 1]}},
           {:fn, [], {:call, {:var, :*}, [2, 3]}},
           {:fn, [], {:call, {:var, :-}, [10, 5]}}
         ]}

      assert {:ok, [2, 6, 5], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pcalls with zero arguments returns empty vector" do
      env = Env.initial()
      ast = {:pcalls, []}

      assert {:ok, [], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pcalls with single thunk" do
      env = Env.initial()
      ast = {:pcalls, [{:fn, [], 42}]}

      assert {:ok, [42], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "results are in argument order (test with 10+ functions)" do
      env = Env.initial()
      # Create 15 thunks that return their index
      fn_asts = Enum.map(0..14, fn i -> {:fn, [], i} end)
      ast = {:pcalls, fn_asts}

      assert {:ok, result, %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
      assert result == Enum.to_list(0..14)
    end

    test "closures work - captures outer scope" do
      env = Map.merge(Env.initial(), %{x: 10, y: 20})
      # (pcalls #(+ x 1) #(+ y 2))
      ast =
        {:pcalls,
         [
           {:fn, [], {:call, {:var, :+}, [{:var, :x}, 1]}},
           {:fn, [], {:call, {:var, :+}, [{:var, :y}, 2]}}
         ]}

      assert {:ok, [11, 22], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "closures capture let bindings" do
      env = Env.initial()
      # (let [a 5 b 10] (pcalls #(+ a 1) #(* b 2)))
      pcalls_ast =
        {:pcalls,
         [
           {:fn, [], {:call, {:var, :+}, [{:var, :a}, 1]}},
           {:fn, [], {:call, {:var, :*}, [{:var, :b}, 2]}}
         ]}

      ast =
        {:let,
         [
           {:binding, {:var, :a}, 5},
           {:binding, {:var, :b}, 10}
         ], pcalls_ast}

      assert {:ok, [6, 20], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pcalls fails atomically when one function raises" do
      env = Env.initial()
      # One thunk will try to increment a string
      ast =
        {:pcalls,
         [
           {:fn, [], {:call, {:var, :+}, [1, 1]}},
           {:fn, [], {:call, {:var, :inc}, [{:string, "not a number"}]}},
           {:fn, [], {:call, {:var, :+}, [2, 2]}}
         ]}

      assert {:error, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "non-callable raises error" do
      env = Env.initial()
      # Passing a non-thunk (a number instead of a function)
      ast = {:pcalls, [42]}

      assert {:error, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "non-zero-arity function raises error" do
      env = Env.initial()
      # (pcalls (fn [x] x)) - has arity 1, not 0
      ast = {:pcalls, [{:fn, [{:var, :x}], {:var, :x}}]}

      assert {:error, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pcalls with tool calls" do
      env = Env.initial()
      call_count = :counters.new(1, [:atomics])

      tool_exec = fn
        "get-user", %{id: id} ->
          :counters.add(call_count, 1, 1)
          %{name: "User#{id}"}

        "get-stats", %{id: id} ->
          :counters.add(call_count, 1, 1)
          %{count: id * 10}

        "get-config", %{} ->
          :counters.add(call_count, 1, 1)
          %{theme: "dark"}
      end

      # (pcalls #(ctx/get-user {:id 1}) #(ctx/get-stats {:id 2}) #(ctx/get-config {}))
      ast =
        {:pcalls,
         [
           {:fn, [], {:ctx_call, :"get-user", [{:map, [{{:keyword, :id}, 1}]}]}},
           {:fn, [], {:ctx_call, :"get-stats", [{:map, [{{:keyword, :id}, 2}]}]}},
           {:fn, [], {:ctx_call, :"get-config", [{:map, []}]}}
         ]}

      assert {:ok, [%{name: "User1"}, %{count: 20}, %{theme: "dark"}], %{}} =
               Eval.eval(ast, %{}, %{}, env, tool_exec)

      assert :counters.get(call_count, 1) == 3
    end
  end

  describe "pcalls isolation" do
    test "user_ns is preserved after pcalls" do
      env = Env.initial()
      ast = {:pcalls, [{:fn, [], 1}, {:fn, [], 2}]}

      initial_user_ns = %{existing: "value"}

      assert {:ok, [1, 2], ^initial_user_ns} =
               Eval.eval(ast, %{}, initial_user_ns, env, &dummy_tool/2)
    end
  end
end
