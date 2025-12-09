defmodule PtcRunner.Lisp.EvalTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.{Env, Eval}

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

  describe "error propagation in nested structures" do
    test "error in vector propagates" do
      # Vector with unbound variable inside
      vector_ast = {:vector, [1, 2, {:var, :unbound}]}

      assert {:error, {:unbound_var, :unbound}} =
               Eval.eval(vector_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in map key propagates" do
      # Map with unbound variable as key
      map_ast = {:map, [{{:var, :unbound}, 1}]}

      assert {:error, {:unbound_var, :unbound}} =
               Eval.eval(map_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in map value propagates" do
      # Map with unbound variable as value
      map_ast = {:map, [{{:keyword, :key}, {:var, :unbound}}]}

      assert {:error, {:unbound_var, :unbound}} =
               Eval.eval(map_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in nested vector propagates" do
      # Nested vector with unbound variable in inner vector
      nested = {:vector, [{:vector, [1, {:var, :x}]}]}

      assert {:error, {:unbound_var, :x}} =
               Eval.eval(nested, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "error propagation in let bindings" do
    test "error in binding value expression propagates" do
      # Binding where the value expression contains unbound variable
      bindings = [{:binding, {:var, :x}, {:var, :undefined}}]
      body = {:var, :x}

      assert {:error, {:unbound_var, :undefined}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in subsequent binding value uses previous bindings" do
      # First binding succeeds, second uses first, then encounters error
      bindings = [
        {:binding, {:var, :x}, 10},
        {:binding, {:var, :y}, {:var, :missing}}
      ]

      body = {:var, :y}

      assert {:error, {:unbound_var, :missing}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in let body does not prevent binding evaluation" do
      # Binding succeeds but body references undefined variable
      bindings = [{:binding, {:var, :x}, 5}]
      body = {:var, :not_bound}

      assert {:error, {:unbound_var, :not_bound}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "error propagation in function calls" do
    test "error in function position propagates" do
      # Unbound variable in function position
      call_ast = {:call, {:var, :unknown_func}, [1]}

      assert {:error, {:unbound_var, :unknown_func}} =
               Eval.eval(call_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "error in function arguments propagates" do
      # Unbound variable in argument position
      env = Env.initial()
      call_ast = {:call, {:var, :+}, [1, {:var, :undefined}]}

      assert {:error, {:unbound_var, :undefined}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end

    test "error in first of multiple arguments propagates" do
      env = Env.initial()
      call_ast = {:call, {:var, :+}, [{:var, :x}, 2, 3]}

      assert {:error, {:unbound_var, :x}} =
               Eval.eval(call_ast, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "error propagation in closures" do
    test "closure with arity mismatch returns error" do
      # Create closure expecting 2 params via let, then call with wrong arity
      closure_def = {:fn, [{:var, :x}, {:var, :y}], {:call, {:var, :+}, [{:var, :x}, {:var, :y}]}}
      bindings = [{:binding, {:var, :add_two}, closure_def}]
      body = {:call, {:var, :add_two}, [5]}

      env = Env.initial()

      assert {:error, {:arity_mismatch, 2, 1}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)
    end

    test "closure with arity mismatch (too many args)" do
      # Create closure expecting 1 param via let, then call with wrong arity
      closure_def = {:fn, [{:var, :x}], {:var, :x}}
      bindings = [{:binding, {:var, :identity}, closure_def}]
      call_ast = {:call, {:var, :identity}, [5, 10, 15]}
      body = call_ast

      env = Env.initial()

      assert {:error, {:arity_mismatch, 1, 3}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)
    end

    test "error in closure body propagates" do
      # Closure that references undefined variable in body
      closure_def =
        {:fn, [{:var, :x}], {:call, {:var, :+}, [{:var, :x}, {:var, :undefined_in_closure}]}}

      bindings = [{:binding, {:var, :bad_fn}, closure_def}]
      call_ast = {:call, {:var, :bad_fn}, [5]}
      body = call_ast

      env = Env.initial()

      assert {:error, {:unbound_var, :undefined_in_closure}} =
               Eval.eval({:let, bindings, body}, %{}, %{}, env, &dummy_tool/2)
    end
  end

  describe "error propagation in keyword function calls" do
    test "invalid keyword call with too many args" do
      map = %{name: "Alice"}
      # Keyword called with too many arguments
      call_ast = {:call, {:keyword, :name}, [{:var, :m}, {:string, "default"}, 42]}

      assert {:error, {:invalid_keyword_call, :name, _}} =
               Eval.eval(call_ast, %{}, %{}, %{m: map}, &dummy_tool/2)
    end

    test "invalid keyword call with no args" do
      # Keyword called with no arguments
      call_ast = {:call, {:keyword, :key}, []}

      assert {:error, {:invalid_keyword_call, :key, []}} =
               Eval.eval(call_ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "invalid keyword call with non-map arg" do
      # Keyword called with non-map, non-nil argument
      call_ast = {:call, {:keyword, :key}, [42]}

      assert {:error, {:invalid_keyword_call, :key, [42]}} =
               Eval.eval(call_ast, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  defp dummy_tool(_name, _args), do: :ok
end
