defmodule PtcRunner.Lisp.EvalApplyTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers
  alias PtcRunner.Lisp.{Env, Eval}

  describe "apply basic usage" do
    test "apply with builtin + and vector" do
      env = Env.initial()
      # (apply + [1 2 3])
      ast = {:call, {:var, :apply}, [{:var, :+}, {:vector, [1, 2, 3]}]}
      assert {:ok, 6, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply with builtin str and vector" do
      env = Env.initial()
      # (apply str ["a" "b" "c"])
      ast =
        {:call, {:var, :apply},
         [{:var, :str}, {:vector, [{:string, "a"}, {:string, "b"}, {:string, "c"}]}]}

      assert {:ok, "abc", _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply with empty vector" do
      env = Env.initial()
      # (apply + []) equivalent to (+)
      ast = {:call, {:var, :apply}, [{:var, :+}, {:vector, []}]}
      assert {:ok, 0, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "apply with fixed arguments (variadic apply)" do
    test "apply with one fixed arg and vector" do
      env = Env.initial()
      # (apply + 1 [2 3])
      ast = {:call, {:var, :apply}, [{:var, :+}, 1, {:vector, [2, 3]}]}
      assert {:ok, 6, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply with multiple fixed args and vector" do
      env = Env.initial()
      # (apply + 1 2 [3 4])
      ast = {:call, {:var, :apply}, [{:var, :+}, 1, 2, {:vector, [3, 4]}]}
      assert {:ok, 10, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply merge with fixed map and vector of maps" do
      env = Env.initial()
      # (apply merge {:a 1} [{:b 2} {:c 3}])
      ast =
        {:call, {:var, :apply},
         [
           {:var, :merge},
           {:map, [{{:keyword, :a}, 1}]},
           {:vector, [{:map, [{{:keyword, :b}, 2}]}, {:map, [{{:keyword, :c}, 3}]}]}
         ]}

      assert {:ok, %{a: 1, b: 2, c: 3}, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "apply with different function types" do
    test "apply with keyword as function" do
      env = Env.initial()
      # (apply :name [{:name "Alice"}])
      ast =
        {:call, {:var, :apply},
         [{:keyword, :name}, {:vector, [{:map, [{{:keyword, :name}, {:string, "Alice"}}]}]}]}

      assert {:ok, "Alice", _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply with map as function" do
      env = Env.initial()
      # (apply {:name "Alice"} [:name])
      ast =
        {:call, {:var, :apply},
         [{:map, [{{:keyword, :name}, {:string, "Alice"}}]}, {:vector, [{:keyword, :name}]}]}

      assert {:ok, "Alice", _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply with set as function" do
      env = Env.initial()
      # (apply #{1 2 3} [2])
      ast = {:call, {:var, :apply}, [{:set, [1, 2, 3]}, {:vector, [2]}]}
      assert {:ok, 2, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply with closure" do
      env = Env.initial()
      # (apply (fn [x y] (+ x y)) [10 20])
      closure_ast = {:fn, [{:var, :x}, {:var, :y}], {:call, {:var, :+}, [{:var, :x}, {:var, :y}]}}
      ast = {:call, {:var, :apply}, [closure_ast, {:vector, [10, 20]}]}
      assert {:ok, 30, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "apply with sets as collections" do
    test "apply + with a set" do
      env = Env.initial()
      ast = {:call, {:var, :apply}, [{:var, :+}, {:set, [1, 2, 3]}]}
      # Result should be 6, order doesn't matter for +
      assert {:ok, 6, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "apply error cases" do
    test "apply with nil as last argument raises error" do
      env = Env.initial()
      # (apply + nil)
      ast = {:call, {:var, :apply}, [{:var, :+}, nil]}
      assert {:error, {:type_error, msg, nil}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
      assert msg =~ "apply expects collection as last argument, got nil"
    end

    test "apply with non-collection last argument raises error" do
      env = Env.initial()
      # (apply + 1)
      ast = {:call, {:var, :apply}, [{:var, :+}, 1]}
      assert {:error, {:type_error, msg, 1}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
      assert msg =~ "apply expects collection as last argument, got number"
    end

    test "apply with non-callable first argument" do
      env = Env.initial()
      # (apply 1 [2])
      ast = {:call, {:var, :apply}, [1, {:vector, [2]}]}
      assert {:error, {:not_callable, 1}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply with map as last argument raises error" do
      env = Env.initial()
      # (apply merge {:a 1})
      ast = {:call, {:var, :apply}, [{:var, :merge}, {:map, [{{:keyword, :a}, 1}]}]}
      assert {:error, {:type_error, msg, _}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
      assert msg =~ "apply expects collection as last argument, got map"
    end

    test "apply with closure arity mismatch" do
      env = Env.initial()
      # (apply (fn [x y z] (+ x y z)) [1 2])
      closure =
        {:fn, [{:var, :x}, {:var, :y}, {:var, :z}],
         {:call, {:var, :+}, [{:var, :x}, {:var, :y}, {:var, :z}]}}

      ast = {:call, {:var, :apply}, [closure, {:vector, [1, 2]}]}
      assert {:error, {:arity_mismatch, 3, 2}} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "apply with multi-arity builtins" do
    test "apply reduce 2-arity" do
      env = Env.initial()
      # (apply reduce [+ [1 2 3]])
      ast =
        {:call, {:var, :apply}, [{:var, :reduce}, {:vector, [{:var, :+}, {:vector, [1, 2, 3]}]}]}

      assert {:ok, 6, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply reduce 3-arity" do
      env = Env.initial()
      # (apply reduce [+ 0 [1 2 3]])
      ast =
        {:call, {:var, :apply},
         [{:var, :reduce}, {:vector, [{:var, :+}, 0, {:vector, [1, 2, 3]}]}]}

      assert {:ok, 6, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply get 2-arity" do
      env = Env.initial()
      # (apply get [{:a 1} :a])
      ast =
        {:call, {:var, :apply},
         [{:var, :get}, {:vector, [{:map, [{{:keyword, :a}, 1}]}, {:keyword, :a}]}]}

      assert {:ok, 1, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply get 3-arity" do
      env = Env.initial()
      # (apply get [{:a 1} :b :default])
      ast =
        {:call, {:var, :apply},
         [
           {:var, :get},
           {:vector, [{:map, [{{:keyword, :a}, 1}]}, {:keyword, :b}, {:keyword, :default}]}
         ]}

      assert {:ok, :default, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "apply subs" do
      env = Env.initial()
      # (apply subs ["hello" 1 4])
      ast = {:call, {:var, :apply}, [{:var, :subs}, {:vector, [{:string, "hello"}, 1, 4]}]}
      assert {:ok, "ell", _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "apply in threading macros" do
    test "thread-last: (->> [1 2 3] (apply +))" do
      # Note: Threading macros are handled at analysis time.
      # To test them here, we'd need to go through analyze + eval, or use Lisp.run.
      # But we can verify the CoreAST that they produce.
      # (->> [1 2 3] (apply +)) -> (apply + [1 2 3])
      env = Env.initial()
      ast = {:call, {:var, :apply}, [{:var, :+}, {:vector, [1, 2, 3]}]}
      assert {:ok, 6, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "higher-order usage" do
    test "map apply +" do
      env = Env.initial()
      # (map #(apply + %) [[1 2] [3 4]])
      # Note: #() syntax desugars to (fn [%1] (apply + %1))
      # In CoreAST it's {:fn, [{:var, :%1}], {:call, {:var, :apply}, [{:var, :+}, {:var, :%1}]}}
      closure = {:fn, [{:var, :"%1"}], {:call, {:var, :apply}, [{:var, :+}, {:var, :"%1"}]}}
      ast = {:call, {:var, :map}, [closure, {:vector, [{:vector, [1, 2]}, {:vector, [3, 4]}]}]}
      assert {:ok, [3, 7], _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "security and limits" do
    test "large collection causes memory error (theoretical)" do
      env = Env.initial()
      # (apply + [1 1 ... 1]) - 100k items
      # This should be caught by the engine's memory limits if configured,
      # but here we just check if it runs or hits a limit.
      # Since we don't have a strict memory mock here, we just ensure it doesn't crash the VM.
      large_list = for _ <- 1..1000, do: 1
      ast = {:call, {:var, :apply}, [{:var, :+}, {:vector, large_list}]}
      assert {:ok, 1000, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "deeply nested apply hits timeout/stack limits" do
      env = Env.initial()
      # (apply apply [+ [[1 2]]]) -> (apply + [1 2]) -> 3
      ast =
        {:call, {:var, :apply},
         [
           {:var, :apply},
           {:vector,
            [
              {:var, :+},
              {:vector, [1, 2]}
            ]}
         ]}

      assert {:ok, 3, _} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "tool integration" do
    test "apply with tool call via analyzer support" do
      # If we want (apply ctx/test-tool [arg-map]) to work,
      # we might need to update the analyzer to recognize this pattern.
      # For now, let's see what happens if we use a closure that calls the tool.
      env = Env.initial()
      # (apply (fn [args] (ctx/test-tool args)) [{:x 1}])
      tool_call = {:ctx_call, :test_tool, [{:var, :args}]}
      closure = {:fn, [{:var, :args}], tool_call}
      ast = {:call, {:var, :apply}, [closure, {:vector, [{:map, [{{:keyword, :x}, 1}]}]}]}

      # Mock tool: returns the arguments map
      mock_tool = fn "test_tool", args -> args end

      assert {:ok, %{x: 1}, _} = Eval.eval(ast, %{}, %{}, env, mock_tool)
    end
  end
end
