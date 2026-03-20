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
      assert {:ok, "alice", %{}} = Eval.eval({:data, :user}, ctx, %{}, %{}, &dummy_tool/2)
    end

    test "context access returns nil if key missing" do
      assert {:ok, nil, %{}} = Eval.eval({:data, :missing}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "short-circuit logic: and" do
    test "empty and returns true" do
      assert {:ok, true, %{}} = Eval.eval({:and, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "all truthy returns last value" do
      exprs = [true, true, 0]
      assert {:ok, 0, %{}} = Eval.eval({:and, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "single truthy returns the value" do
      assert {:ok, 1, %{}} = Eval.eval({:and, [1]}, %{}, %{}, %{}, &dummy_tool/2)
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

    test "all falsy returns last falsy value" do
      exprs = [false, nil]
      assert {:ok, nil, %{}} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "all falsy with different last value" do
      exprs = [nil, false]
      assert {:ok, false, %{}} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "unbound memory variable falls through to default" do
      # The canonical memory pattern: (or my-counter 0)
      # When the variable has never been def'd, it should behave like nil
      # and return the default — not crash with :unbound_var.
      exprs = [{:var, :my_counter}, 0]
      # ctx=%{}, memory=%{} (empty — variable never defined), env=%{}
      assert {:ok, 0, _} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "truthy memory variable is returned without hitting default" do
      exprs = [{:var, :my_counter}, 0]
      # ctx=%{}, memory=%{my_counter: 42}, env=%{}
      assert {:ok, 42, _} =
               Eval.eval({:or, exprs}, %{}, %{my_counter: 42}, %{}, &dummy_tool/2)
    end

    test "unbound variable in non-first position falls through" do
      # (or nil unbound-b) should return nil, not crash
      exprs = [nil, {:var, :unbound_b}]
      assert {:ok, nil, _} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "multiple unbound variables all fall through to nil" do
      # (or unbound-a unbound-b) should return nil, not crash
      exprs = [{:var, :unbound_a}, {:var, :unbound_b}]
      assert {:ok, nil, _} = Eval.eval({:or, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "non-unbound errors still propagate" do
      # Only :unbound_var is suppressed; other errors (e.g. type errors) surface.
      # Test via Lisp.run where error handling is clean.
      assert {:error, _step} = PtcRunner.Lisp.run("(or (+ 1 \"bad\") 99)")
    end
  end

  describe "sequential evaluation: do" do
    test "empty do returns nil" do
      assert {:ok, nil, %{}} = Eval.eval({:do, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "single expression returns its value" do
      assert {:ok, 42, %{}} = Eval.eval({:do, [42]}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "multiple expressions evaluates all and returns last value" do
      exprs = [1, 2, 3]
      assert {:ok, 3, %{}} = Eval.eval({:do, exprs}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "do evaluates all expressions without short-circuiting" do
      env = Env.initial()

      exprs = [
        {:call, {:var, :+}, [1, 1]},
        {:call, {:var, :+}, [2, 2]},
        {:call, {:var, :+}, [3, 3]}
      ]

      assert {:ok, 6, %{}} = Eval.eval({:do, exprs}, %{}, %{}, env, &dummy_tool/2)
    end

    test "nested do works" do
      inner_do = {:do, [1, 2]}
      outer_do = {:do, [inner_do, 3]}
      assert {:ok, 3, %{}} = Eval.eval(outer_do, %{}, %{}, %{}, &dummy_tool/2)
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

  describe "case — value dispatch" do
    alias PtcRunner.Lisp

    test "keyword matching" do
      assert {:ok, %{return: 1}} = Lisp.run("(case :a :a 1 :b 2)")
    end

    test "string matching" do
      assert {:ok, %{return: 1}} = Lisp.run(~s|(case "x" "x" 1 "y" 2)|)
    end

    test "number matching" do
      assert {:ok, %{return: "forty-two"}} = Lisp.run(~s|(case 42 1 "one" 42 "forty-two")|)
    end

    test "grouped match" do
      assert {:ok, %{return: 2}} = Lisp.run("(case :c (:a :b) 1 (:c :d) 2)")
    end

    test "default" do
      assert {:ok, %{return: "default"}} = Lisp.run(~s|(case :z :a 1 :b 2 "default")|)
    end

    test "no match, no default returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(case :z :a 1 :b 2)")
    end

    test "nil matching" do
      assert {:ok, %{return: "matched"}} = Lisp.run(~s|(case nil nil "matched" :a "nope")|)
    end

    test "boolean matching" do
      assert {:ok, %{return: "yes"}} = Lisp.run(~s|(case true true "yes" false "no")|)
    end

    test "expression evaluated once" do
      # Use def to track evaluation count
      code = """
      (do
        (def counter 0)
        (case (do (def counter (inc counter)) :a)
          :a "matched"
          :b "nope")
        counter)
      """

      assert {:ok, %{return: 1}} = Lisp.run(code)
    end

    test "expression only, no clauses returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(case :a)")
    end

    test "float test value" do
      assert {:ok, %{return: "pi"}} = Lisp.run(~s|(case 3.14 3.14 "pi" 2.71 "e")|)
    end
  end

  describe "condp — predicate dispatch" do
    alias PtcRunner.Lisp

    test "basic equality" do
      assert {:ok, %{return: 1}} = Lisp.run("(condp = :a :a 1 :b 2)")
    end

    test "comparison: (pred test expr) order" do
      # (condp > 5 10 "big" 3 "small")
      # calls (> 10 5) → true → "big"
      assert {:ok, %{return: "big"}} = Lisp.run(~s|(condp > 5 10 "big" 3 "small")|)
    end

    test "default" do
      assert {:ok, %{return: "default"}} = Lisp.run(~s|(condp = :z :a 1 "default")|)
    end

    test "no match, no default returns nil" do
      assert {:ok, %{return: nil}} = Lisp.run("(condp = :z :a 1 :b 2)")
    end

    test "pred invoked per clause" do
      code = """
      (do
        (def pred-count 0)
        (let [my-pred (fn [a b] (do (def pred-count (inc pred-count)) (= a b)))]
          (condp my-pred :b :a 1 :b 2))
        pred-count)
      """

      assert {:ok, %{return: 2}} = Lisp.run(code)
    end

    test "pred expression evaluated once" do
      code = """
      (do
        (def build-count 0)
        (condp (do (def build-count (inc build-count)) =) :b
          :a 1
          :b 2
          :c 3)
        build-count)
      """

      assert {:ok, %{return: 1}} = Lisp.run(code)
    end

    test "expr evaluated once" do
      code = """
      (do
        (def expr-count 0)
        (condp = (do (def expr-count (inc expr-count)) :a)
          :a "matched"
          :b "nope")
        expr-count)
      """

      assert {:ok, %{return: 1}} = Lisp.run(code)
    end

    test "condp with custom predicate" do
      code = """
      (condp = (+ 1 1)
        1 "one"
        2 "two"
        3 "three")
      """

      assert {:ok, %{return: "two"}} = Lisp.run(code)
    end
  end
end
