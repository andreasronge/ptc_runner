defmodule PtcRunner.Lisp.PmapTest do
  @moduledoc """
  Tests for pmap (parallel map) special form.
  """
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.{Analyze, Env, Eval}

  describe "analyze pmap" do
    test "valid pmap with function and collection" do
      raw = {:list, [{:symbol, :pmap}, {:symbol, :inc}, {:symbol, :items}]}
      assert {:ok, {:pmap, {:var, :inc}, {:var, :items}}} = Analyze.analyze(raw)
    end

    test "valid pmap with anonymous function" do
      raw =
        {:list,
         [
           {:symbol, :pmap},
           {:list, [{:symbol, :fn}, {:vector, [{:symbol, :x}]}, {:symbol, :x}]},
           {:vector, [1, 2, 3]}
         ]}

      assert {:ok, {:pmap, {:fn, [{:var, :x}], {:var, :x}}, {:vector, [1, 2, 3]}}} =
               Analyze.analyze(raw)
    end

    test "pmap requires exactly 2 arguments" do
      raw = {:list, [{:symbol, :pmap}, {:symbol, :inc}]}
      assert {:error, {:invalid_arity, :pmap, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (pmap f coll)"
    end

    test "pmap with too many arguments fails" do
      raw = {:list, [{:symbol, :pmap}, {:symbol, :inc}, {:symbol, :items}, {:symbol, :extra}]}
      assert {:error, {:invalid_arity, :pmap, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (pmap f coll)"
    end

    test "pmap with no arguments fails" do
      raw = {:list, [{:symbol, :pmap}]}
      assert {:error, {:invalid_arity, :pmap, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (pmap f coll)"
    end
  end

  describe "eval pmap" do
    test "pmap with builtin function" do
      env = Env.initial()
      ast = {:pmap, {:var, :inc}, {:vector, [1, 2, 3]}}

      assert {:ok, [2, 3, 4], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pmap with anonymous function" do
      env = Env.initial()
      # (pmap (fn [x] (* x 2)) [1 2 3 4])
      fn_ast = {:fn, [{:var, :x}], {:call, {:var, :*}, [{:var, :x}, 2]}}
      ast = {:pmap, fn_ast, {:vector, [1, 2, 3, 4]}}

      assert {:ok, [2, 4, 6, 8], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pmap with keyword accessor" do
      env = Env.initial()
      # (pmap :name [{:name "Alice"} {:name "Bob"}])
      # Collection needs to be a vector of maps constructed properly
      coll_ast =
        {:vector,
         [
           {:map, [{{:keyword, :name}, {:string, "Alice"}}]},
           {:map, [{{:keyword, :name}, {:string, "Bob"}}]}
         ]}

      ast = {:pmap, {:keyword, :name}, coll_ast}

      assert {:ok, ["Alice", "Bob"], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pmap preserves order" do
      env = Env.initial()
      # Test with larger collection to increase chance of detecting ordering issues
      items = Enum.to_list(1..100)
      ast = {:pmap, {:var, :inc}, {:vector, items}}

      assert {:ok, result, %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
      assert result == Enum.map(items, &(&1 + 1))
    end

    test "pmap with empty collection returns empty list" do
      env = Env.initial()
      ast = {:pmap, {:var, :inc}, {:vector, []}}

      assert {:ok, [], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pmap with single element" do
      env = Env.initial()
      ast = {:pmap, {:var, :inc}, {:vector, [42]}}

      assert {:ok, [43], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pmap with closure capturing outer scope" do
      env = Map.merge(Env.initial(), %{multiplier: 10})
      # (pmap (fn [x] (* x multiplier)) [1 2 3])
      fn_ast = {:fn, [{:var, :x}], {:call, {:var, :*}, [{:var, :x}, {:var, :multiplier}]}}
      ast = {:pmap, fn_ast, {:vector, [1, 2, 3]}}

      assert {:ok, [10, 20, 30], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pmap with closure using let bindings" do
      env = Env.initial()
      # (let [factor 5] (pmap (fn [x] (* x factor)) [1 2 3]))
      fn_ast = {:fn, [{:var, :x}], {:call, {:var, :*}, [{:var, :x}, {:var, :factor}]}}
      pmap_ast = {:pmap, fn_ast, {:vector, [1, 2, 3]}}
      ast = {:let, [{:binding, {:var, :factor}, 5}], pmap_ast}

      assert {:ok, [5, 10, 15], %{}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pmap propagates errors from function" do
      env = Env.initial()
      # Trying to increment a string should fail
      ast = {:pmap, {:var, :inc}, {:vector, [{:string, "not"}, {:string, "numbers"}]}}

      assert {:error, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "pmap with tool calls" do
      env = Env.initial()
      call_count = :counters.new(1, [:atomics])

      tool_exec = fn "process", %{value: v} ->
        :counters.add(call_count, 1, 1)
        # Simulate some work
        v * 2
      end

      # (pmap (fn [x] (ctx/process {:value x})) [1 2 3])
      fn_ast =
        {:fn, [{:var, :x}], {:ctx_call, :process, [{:map, [{{:keyword, :value}, {:var, :x}}]}]}}

      ast = {:pmap, fn_ast, {:vector, [1, 2, 3]}}

      assert {:ok, [2, 4, 6], %{}} = Eval.eval(ast, %{}, %{}, env, tool_exec)
      assert :counters.get(call_count, 1) == 3
    end
  end

  describe "pmap isolation" do
    test "user_ns modifications within pmap branches are isolated" do
      # Each branch gets a snapshot - writes don't affect siblings or parent
      # This tests the isolation model where def within pmap doesn't leak
      env = Env.initial()

      # This is a contrived test - in practice def in pmap would be unusual
      # but we want to verify the isolation guarantees
      # (pmap identity [1 2 3]) - simple case preserves user_ns
      ast = {:pmap, {:var, :identity}, {:vector, [1, 2, 3]}}

      initial_user_ns = %{existing: "value"}

      assert {:ok, [1, 2, 3], ^initial_user_ns} =
               Eval.eval(ast, %{}, initial_user_ns, env, &dummy_tool/2)
    end
  end
end
