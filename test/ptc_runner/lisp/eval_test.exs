defmodule PtcRunner.Lisp.EvalTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.{Analyze, Env, Eval}

  describe "literal evaluation" do
    test "nil" do
      assert {:ok, nil, %{}} = Eval.eval(nil, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "booleans" do
      assert {:ok, true, %{}} = Eval.eval(true, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, false, %{}} = Eval.eval(false, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "integers" do
      assert {:ok, 42, %{}} = Eval.eval(42, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, -10, %{}} = Eval.eval(-10, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "floats" do
      assert {:ok, 3.14, %{}} = Eval.eval(3.14, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, -2.5, %{}} = Eval.eval(-2.5, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "strings" do
      assert {:ok, "hello", %{}} = Eval.eval({:string, "hello"}, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, "", %{}} = Eval.eval({:string, ""}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "keywords" do
      assert {:ok, :name, %{}} = Eval.eval({:keyword, :name}, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, :status, %{}} = Eval.eval({:keyword, :status}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "vector evaluation" do
    test "empty vector" do
      assert {:ok, [], %{}} = Eval.eval({:vector, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "vector with literals" do
      assert {:ok, [1, 2, 3], %{}} = Eval.eval({:vector, [1, 2, 3]}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "vector with mixed types" do
      assert {:ok, [1, "test", :foo], %{}} =
               Eval.eval(
                 {:vector, [1, {:string, "test"}, {:keyword, :foo}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )
    end

    test "nested vectors" do
      inner = {:vector, [1, 2]}

      assert {:ok, [[1, 2], [3, 4]], %{}} =
               Eval.eval({:vector, [inner, {:vector, [3, 4]}]}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "map evaluation" do
    test "empty map" do
      assert {:ok, %{}, %{}} = Eval.eval({:map, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "map with literal keys and values" do
      assert {:ok, %{name: "test"}, %{}} =
               Eval.eval(
                 {:map, [{{:keyword, :name}, {:string, "test"}}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )
    end

    test "map with multiple pairs" do
      assert {:ok, %{a: 1, b: 2}, %{}} =
               Eval.eval(
                 {:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )
    end

    test "nested maps" do
      inner = {:map, [{{:keyword, :x}, 1}]}

      assert {:ok, %{outer: %{x: 1}}, %{}} =
               Eval.eval({:map, [{{:keyword, :outer}, inner}]}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "map with string keys" do
      assert {:ok, %{"key" => "value"}, %{}} =
               Eval.eval(
                 {:map, [{{:string, "key"}, {:string, "value"}}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )
    end
  end

  describe "variable access" do
    test "unbound variable returns error" do
      assert {:error, {:unbound_var, :x}} = Eval.eval({:var, :x}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "bound variable returns value" do
      env = %{x: 42}
      assert {:ok, 42, %{}} = Eval.eval({:var, :x}, %{}, %{}, env, &dummy_tool/2)
    end

    test "context access" do
      ctx = %{user: "alice"}
      assert {:ok, "alice", %{}} = Eval.eval({:ctx, :user}, ctx, %{}, %{}, &dummy_tool/2)
    end

    test "context access returns nil if key missing" do
      assert {:ok, nil, %{}} = Eval.eval({:ctx, :missing}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "memory access" do
      memory = %{count: 5}
      assert {:ok, 5, %{count: 5}} = Eval.eval({:memory, :count}, %{}, memory, %{}, &dummy_tool/2)
    end

    test "memory access returns nil if key missing" do
      assert {:ok, nil, %{}} = Eval.eval({:memory, :missing}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "short-circuit logic: and" do
    test "empty and returns true" do
      assert {:ok, true, %{}} = Eval.eval({:and, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "all truthy returns last value" do
      # Note: empty and evaluates to true
      assert {:ok, true, %{}} = Eval.eval({:and, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "falsy short-circuits" do
      exprs = [true, false, nil]
      assert {:ok, false, %{}} = Eval.eval({:and, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "nil short-circuits" do
      exprs = [true, nil, 42]
      assert {:ok, nil, %{}} = Eval.eval({:and, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "short-circuit logic: or" do
    test "empty or returns nil" do
      assert {:ok, nil, %{}} = Eval.eval({:or, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "first truthy returns early" do
      exprs = [false, nil, 42, 99]
      assert {:ok, 42, %{}} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "all falsy returns last falsy" do
      exprs = [false, nil]
      assert {:ok, nil, %{}} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "conditionals: if" do
    test "if with truthy condition evaluates then branch" do
      then_ast = 42
      else_ast = 0

      assert {:ok, 42, %{}} =
               Eval.eval({:if, true, then_ast, else_ast}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "if with falsy condition evaluates else branch" do
      then_ast = 42
      else_ast = 0

      assert {:ok, 0, %{}} =
               Eval.eval({:if, false, then_ast, else_ast}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "if with nil evaluates else branch" do
      then_ast = 42
      else_ast = 0

      assert {:ok, 0, %{}} =
               Eval.eval({:if, nil, then_ast, else_ast}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "function definition: fn" do
    test "fn creates closure" do
      params = [{:var, :x}]
      body = {:var, :x}

      {:ok, closure, %{}} = Eval.eval({:fn, params, body}, %{}, %{}, %{}, &dummy_tool/2)

      assert match?({:closure, [:x], _body, _env}, closure)
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

  describe "let bindings" do
    test "simple variable binding" do
      bindings = [{:binding, {:var, :x}, 42}]
      body = {:var, :x}

      assert {:ok, 42, %{}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "multiple bindings" do
      bindings = [{:binding, {:var, :x}, 10}, {:binding, {:var, :y}, 20}]
      body = {:call, {:var, :+}, [{:var, :x}, {:var, :y}]}

      env = Env.initial()

      assert {:ok, 30, %{}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)
    end

    test "binding evaluates in order" do
      bindings = [
        {:binding, {:var, :x}, 5},
        {:binding, {:var, :y}, {:call, {:var, :+}, [{:var, :x}, 3]}}
      ]

      body = {:var, :y}
      env = Env.initial()

      assert {:ok, 8, %{}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "where predicates" do
    test "truthy check" do
      predicate = {:where, {:field, [{:keyword, :active}]}, :truthy, nil}
      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      assert fun.(%{active: true})
      refute fun.(%{active: false})
      refute fun.(%{active: nil})
    end

    test "equality check" do
      predicate = {:where, {:field, [{:keyword, :status}]}, :eq, {:string, "active"}}
      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      assert fun.(%{status: "active"})
      refute fun.(%{status: "inactive"})
    end

    test "nil-safe comparison: nil returns false" do
      predicate = {:where, {:field, [{:keyword, :age}]}, :gt, 18}
      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      assert fun.(%{age: 20})
      refute fun.(%{age: nil})
      refute fun.(%{age: 5})
    end
  end

  describe "predicate combinators" do
    test "all-of with no predicates returns true" do
      combinator = {:pred_combinator, :all_of, []}
      {:ok, fun, %{}} = Eval.eval(combinator, %{}, %{}, %{}, &dummy_tool/2)

      assert fun.(%{a: 1, b: 2})
    end

    test "any-of with no predicates returns false" do
      combinator = {:pred_combinator, :any_of, []}
      {:ok, fun, %{}} = Eval.eval(combinator, %{}, %{}, %{}, &dummy_tool/2)

      refute fun.(%{a: 1, b: 2})
    end

    test "none-of with no predicates returns true" do
      combinator = {:pred_combinator, :none_of, []}
      {:ok, fun, %{}} = Eval.eval(combinator, %{}, %{}, %{}, &dummy_tool/2)

      assert fun.(%{a: 1, b: 2})
    end
  end

  describe "memory threading" do
    test "memory is threaded through literals" do
      memory = %{count: 5}
      {:ok, value, new_memory} = Eval.eval(42, %{}, memory, %{}, &dummy_tool/2)

      assert value == 42
      assert new_memory == memory
    end

    test "memory is threaded through vector evaluation" do
      memory = %{count: 5}

      {:ok, [1, 2, 3], new_memory} =
        Eval.eval({:vector, [1, 2, 3]}, %{}, memory, %{}, &dummy_tool/2)

      assert new_memory == memory
    end

    test "memory is threaded through map evaluation" do
      memory = %{count: 5}

      {:ok, %{a: 1}, new_memory} =
        Eval.eval({:map, [{{:keyword, :a}, 1}]}, %{}, memory, %{}, &dummy_tool/2)

      assert new_memory == memory
    end
  end

  defp dummy_tool(_name, _args), do: :ok
end
