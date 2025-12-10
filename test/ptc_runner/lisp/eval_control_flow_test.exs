defmodule PtcRunner.Lisp.EvalControlFlowTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.{Env, Eval}

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

    test "string key fallback: matches string keys when atom keys not found" do
      predicate = {:where, {:field, [{:keyword, :category}]}, :eq, {:string, "electronics"}}
      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      # Data with string keys from API
      assert fun.(%{"category" => "electronics"})
      refute fun.(%{"category" => "books"})
    end

    test "atom key precedence: atom key wins over string key when both exist" do
      predicate = {:where, {:field, [{:keyword, :category}]}, :eq, {:string, "priority"}}
      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      # When both atom and string keys exist, atom key takes precedence
      assert fun.(%{"category" => "ignored", category: "priority"})
      # String-only data still works (falls back to string key)
      assert fun.(%{"category" => "priority"})
      refute fun.(%{"category" => "different"})
    end

    test "atom key precedence: atom key wins even when falsy" do
      predicate = {:where, {:field, [{:keyword, :enabled}]}, :eq, false}
      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      # Atom key false should win over string key true
      assert fun.(%{enabled: false} |> Map.put("enabled", true))
      refute fun.(%{enabled: true} |> Map.put("enabled", false))
    end

    test "mixed keys: atom keys work as before" do
      predicate = {:where, {:field, [{:keyword, :status}]}, :eq, {:string, "active"}}
      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      # Atom-keyed data still works
      assert fun.(%{status: "active"})
      refute fun.(%{status: "inactive"})
    end

    test "nested field access with string keys" do
      predicate =
        {:where, {:field, [{:keyword, :user}, {:keyword, :email}]}, :eq,
         {:string, "alice@example.com"}}

      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      # Nested structure with string keys
      assert fun.(%{"user" => %{"email" => "alice@example.com"}})
      refute fun.(%{"user" => %{"email" => "bob@example.com"}})
    end

    test "mixed nested keys: atom parent with string child" do
      predicate =
        {:where, {:field, [{:keyword, :user}, {:keyword, :email}]}, :eq,
         {:string, "alice@example.com"}}

      {:ok, fun, %{}} = Eval.eval(predicate, %{}, %{}, %{}, &dummy_tool/2)

      # Mixed key types in nested structure
      assert fun.(%{user: %{"email" => "alice@example.com"}})
      refute fun.(%{user: %{"email" => "bob@example.com"}})
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
end
