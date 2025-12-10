defmodule PtcRunner.Lisp.EvalFunctionsTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.{Env, Eval}

  describe "function definition: fn" do
    test "fn creates closure" do
      params = [{:var, :x}]
      body = {:var, :x}

      {:ok, closure, %{}} = Eval.eval({:fn, params, body}, %{}, %{}, %{}, &dummy_tool/2)

      assert match?({:closure, ^params, ^body, _env}, closure)
    end

    test "closure captures environment" do
      env = %{y: 10}
      params = [{:var, :x}]
      body = {:var, :y}

      {:ok, {:closure, _, _, captured_env}, %{}} =
        Eval.eval({:fn, params, body}, %{}, %{}, env, &dummy_tool/2)

      assert captured_env == env
    end
  end

  describe "function calls with keyword as function" do
    test "keyword access on map with single arg" do
      map = %{name: "Alice"}

      assert {:ok, "Alice", %{}} =
               Eval.eval(
                 {:call, {:keyword, :name}, [{:var, :m}]},
                 %{},
                 %{},
                 %{m: map},
                 &dummy_tool/2
               )
    end

    test "keyword access with default when key missing" do
      map = %{}

      {:ok, nil, %{}} =
        Eval.eval({:call, {:keyword, :missing}, [{:var, :m}]}, %{}, %{}, %{m: map}, &dummy_tool/2)
    end

    test "keyword access on nil returns nil" do
      {:ok, nil, %{}} =
        Eval.eval({:call, {:keyword, :key}, [{:var, :x}]}, %{}, %{}, %{x: nil}, &dummy_tool/2)
    end
  end

  describe "closure with destructuring patterns" do
    test "vector destructuring: extracts first element" do
      # (fn [[a b]] a) called with [1 2]
      params = [{:destructure, {:seq, [{:var, :a}, {:var, :b}]}}]
      body = {:var, :a}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :extract_first}, closure_def}]
      call_ast = {:call, {:var, :extract_first}, [{:vector, [1, 2]}]}

      assert {:ok, 1, %{}} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "vector destructuring: extracts second element" do
      # (fn [[a b]] b) called with [1 2]
      params = [{:destructure, {:seq, [{:var, :a}, {:var, :b}]}}]
      body = {:var, :b}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :extract_second}, closure_def}]
      call_ast = {:call, {:var, :extract_second}, [{:vector, [1, 2]}]}

      assert {:ok, 2, %{}} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "vector destructuring: ignores extra elements" do
      # (fn [[a]] a) called with [1 2 3]
      params = [{:destructure, {:seq, [{:var, :a}]}}]
      body = {:var, :a}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :take_first}, closure_def}]
      call_ast = {:call, {:var, :take_first}, [{:vector, [1, 2, 3]}]}

      assert {:ok, 1, %{}} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "vector destructuring: error on insufficient elements" do
      # (fn [[a b c]] a) called with [1 2]
      params = [{:destructure, {:seq, [{:var, :a}, {:var, :b}, {:var, :c}]}}]
      body = {:var, :a}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :bad_extract}, closure_def}]
      call_ast = {:call, {:var, :bad_extract}, [{:vector, [1, 2]}]}

      assert {:error, _} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "vector destructuring: error on non-list argument" do
      # (fn [[a b]] a) called with 42 (not a list)
      params = [{:destructure, {:seq, [{:var, :a}, {:var, :b}]}}]
      body = {:var, :a}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :expect_list}, closure_def}]
      call_ast = {:call, {:var, :expect_list}, [42]}

      assert {:error, _} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "map destructuring: extracts specified keys" do
      # (fn [{:keys [x]}] x) called with {:x 10}
      params = [{:destructure, {:keys, [:x], []}}]
      body = {:var, :x}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :extract_x}, closure_def}]
      call_ast = {:call, {:var, :extract_x}, [{:map, [{{:keyword, :x}, 10}]}]}

      assert {:ok, 10, %{}} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "map destructuring: multiple keys" do
      # (fn [{:keys [x y]}] [x y]) called with {:x 10 :y 20}
      params = [{:destructure, {:keys, [:x, :y], []}}]
      body = {:vector, [{:var, :x}, {:var, :y}]}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :extract_xy}, closure_def}]

      call_ast =
        {:call, {:var, :extract_xy}, [{:map, [{{:keyword, :x}, 10}, {{:keyword, :y}, 20}]}]}

      assert {:ok, [10, 20], %{}} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "map destructuring: with default value" do
      # (fn [{:keys [x] :or {x 0}}] x) called with {:y 20}
      params = [{:destructure, {:keys, [:x], [x: 0]}}]
      body = {:var, :x}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :with_default}, closure_def}]
      call_ast = {:call, {:var, :with_default}, [{:map, [{{:keyword, :y}, 20}]}]}

      assert {:ok, 0, %{}} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "map destructuring: error on non-map argument" do
      # (fn [{:keys [x]}] x) called with [1 2 3] (not a map)
      params = [{:destructure, {:keys, [:x], []}}]
      body = {:var, :x}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :expect_map}, closure_def}]
      call_ast = {:call, {:var, :expect_map}, [{:vector, [1, 2, 3]}]}

      assert {:error, _} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "vector destructuring with nested patterns: vector in vector" do
      # (fn [[[a b] c]] a) called with [[1 2] 3]
      params = [
        {:destructure, {:seq, [{:destructure, {:seq, [{:var, :a}, {:var, :b}]}}, {:var, :c}]}}
      ]

      body = {:var, :a}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :nested_vec}, closure_def}]
      call_ast = {:call, {:var, :nested_vec}, [{:vector, [{:vector, [1, 2]}, 3]}]}

      assert {:ok, 1, %{}} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "vector destructuring: error on map argument" do
      # (fn [[a b]] a) called with {:x 1} (not a list)
      params = [{:destructure, {:seq, [{:var, :a}, {:var, :b}]}}]
      body = {:var, :a}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :expect_list_not_map}, closure_def}]
      call_ast = {:call, {:var, :expect_list_not_map}, [{:map, [{{:keyword, :x}, 1}]}]}

      assert {:error, _} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end

    test "vector destructuring with nested patterns: vector containing map" do
      # (fn [[k {:keys [v]}]] v) called with [["key" {:v 42}]]
      params = [
        {:destructure, {:seq, [{:var, :k}, {:destructure, {:keys, [:v], []}}]}}
      ]

      body = {:var, :v}
      closure_def = {:fn, params, body}

      bindings = [{:binding, {:var, :nested_vec_map}, closure_def}]

      call_ast =
        {:call, {:var, :nested_vec_map},
         [{:vector, [{:string, "key"}, {:map, [{{:keyword, :v}, 42}]}]}]}

      assert {:ok, 42, %{}} =
               Eval.eval({:let, bindings, call_ast}, %{}, %{}, Env.initial(), &dummy_tool/2)
    end
  end

  describe "multi-arity builtins" do
    test "sort-by with 2 arguments (key, coll) sorts ascending" do
      env = Env.initial()
      data = [%{price: 30}, %{price: 10}, %{price: 20}]

      call_ast = {:call, {:var, :"sort-by"}, [{:keyword, :price}, {:var, :data}]}

      assert {:ok, result, %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)

      assert result == [%{price: 10}, %{price: 20}, %{price: 30}]
    end

    test "sort-by with 3 arguments (key, comparator, coll) sorts descending" do
      env = Env.initial()
      data = [%{price: 10}, %{price: 30}, %{price: 20}]

      # (sort-by :price > data) - sorts by price descending
      call_ast = {:call, {:var, :"sort-by"}, [{:keyword, :price}, {:var, :>}, {:var, :data}]}

      assert {:ok, result, %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)

      assert result == [%{price: 30}, %{price: 20}, %{price: 10}]
    end

    test "sort-by with 3 arguments using < comparator" do
      env = Env.initial()
      data = [%{name: "Bob"}, %{name: "Alice"}, %{name: "Charlie"}]

      call_ast = {:call, {:var, :"sort-by"}, [{:keyword, :name}, {:var, :<}, {:var, :data}]}

      assert {:ok, result, %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)

      assert result == [%{name: "Alice"}, %{name: "Bob"}, %{name: "Charlie"}]
    end

    test "sort-by arity error with wrong argument count" do
      env = Env.initial()

      # sort-by only accepts 2 or 3 arguments
      call_ast = {:call, {:var, :"sort-by"}, [{:keyword, :price}]}

      assert {:error, {:arity_error, _}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "get with 2 arguments (map, key) returns value or nil" do
      env = Env.initial()
      data = %{name: "Alice", age: 30}

      # (get data :name)
      call_ast = {:call, {:var, :get}, [{:var, :data}, {:keyword, :name}]}

      assert {:ok, "Alice", %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)

      # (get data :missing)
      call_ast = {:call, {:var, :get}, [{:var, :data}, {:keyword, :missing}]}

      assert {:ok, nil, %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)
    end

    test "get with 3 arguments (map, key, default) returns value or default" do
      env = Env.initial()
      data = %{name: "Alice", age: 30}

      # (get data :name :default)
      call_ast = {:call, {:var, :get}, [{:var, :data}, {:keyword, :name}, {:string, "default"}]}

      assert {:ok, "Alice", %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)

      # (get data :missing :default)
      call_ast =
        {:call, {:var, :get}, [{:var, :data}, {:keyword, :missing}, {:string, "default"}]}

      assert {:ok, "default", %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)
    end

    test "get arity error with wrong argument count" do
      env = Env.initial()

      # get only accepts 2 or 3 arguments
      call_ast = {:call, {:var, :get}, [{:keyword, :name}]}

      assert {:error, {:arity_error, _}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "get with nil map returns nil or default" do
      env = Env.initial()

      # (get nil :key)
      call_ast = {:call, {:var, :get}, [nil, {:keyword, :key}]}

      assert {:ok, nil, %{}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)

      # (get nil :key "default")
      call_ast = {:call, {:var, :get}, [nil, {:keyword, :key}, {:string, "default"}]}

      assert {:ok, "default", %{}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "get-in with 2 arguments (map, path) returns nested value" do
      env = Env.initial()
      data = %{user: %{name: "Alice", address: %{city: "NYC"}}}

      # (get-in data [:user :name])
      call_ast =
        {:call, {:var, :"get-in"},
         [{:var, :data}, {:vector, [{:keyword, :user}, {:keyword, :name}]}]}

      assert {:ok, "Alice", %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)
    end

    test "get-in with 3 arguments (map, path, default) returns default when path not found" do
      env = Env.initial()
      data = %{user: %{name: "Alice"}}

      # (get-in data [:user :missing] :default)
      call_ast =
        {:call, {:var, :"get-in"},
         [
           {:var, :data},
           {:vector, [{:keyword, :user}, {:keyword, :missing}]},
           {:string, "default"}
         ]}

      assert {:ok, "default", %{}} =
               Eval.eval(call_ast, %{}, %{}, Map.merge(env, %{data: data}), &dummy_tool/2)
    end

    test "get-in arity error with wrong argument count" do
      env = Env.initial()

      # get-in only accepts 2 or 3 arguments
      call_ast = {:call, {:var, :"get-in"}, [{:keyword, :name}]}

      assert {:error, {:arity_error, _}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "builtin unwrapping for higher-order functions" do
    test "passing > as comparator to reduce" do
      env = Env.initial()

      # (reduce > 0 [1 5 3]) - should find max using > as comparison function
      # This tests that {:normal, &Kernel.>/2} gets unwrapped to &Kernel.>/2
      call_ast = {:call, {:var, :reduce}, [{:var, :>}, 0, {:vector, [1, 5, 3]}]}

      # > will act as reducer: (> (> (> 0 1) 5) 3) = (> (> false 5) 3) = (> false 3) = false
      assert {:ok, false, %{}} = Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "passing + as accumulator function to reduce" do
      env = Env.initial()

      # (reduce + 0 [1 2 3]) = 6
      call_ast = {:call, {:var, :reduce}, [{:var, :+}, 0, {:vector, [1, 2, 3]}]}

      assert {:ok, 6, %{}} = Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end
  end
end
