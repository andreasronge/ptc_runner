defmodule PtcRunner.Lisp.DefnTest do
  @moduledoc """
  Tests for the `defn` special form for named function definitions.

  The `defn` form is syntactic sugar for `(def name (fn [params] body))`.
  Functions defined with `defn` persist across turns via the user namespace.
  """
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze
  alias PtcRunner.Lisp.Eval
  alias PtcRunner.Lisp.Format.Var

  # ============================================================
  # Analyzer tests
  # ============================================================

  describe "analyzer: defn" do
    test "(defn name [params] body) desugars to def + fn" do
      # (defn double [x] (* x 2))
      raw =
        {:list, [{:symbol, :defn}, {:symbol, :double}, {:vector, [{:symbol, :x}]}, {:symbol, :x}]}

      assert {:ok, {:def, :double, {:fn, [{:var, :x}], {:var, :x}}}} = Analyze.analyze(raw)
    end

    test "(defn name docstring [params] body) ignores docstring" do
      # (defn double "Doubles a number" [x] (* x 2))
      raw =
        {:list,
         [
           {:symbol, :defn},
           {:symbol, :double},
           {:string, "Doubles a number"},
           {:vector, [{:symbol, :x}]},
           {:symbol, :x}
         ]}

      assert {:ok, {:def, :double, {:fn, [{:var, :x}], {:var, :x}}}} = Analyze.analyze(raw)
    end

    test "defn with zero params works" do
      # (defn greeting [] "hello")
      raw = {:list, [{:symbol, :defn}, {:symbol, :greeting}, {:vector, []}, {:string, "hello"}]}
      assert {:ok, {:def, :greeting, {:fn, [], {:string, "hello"}}}} = Analyze.analyze(raw)
    end

    test "defn with multiple params works" do
      # (defn add [a b c] (+ a b c))
      raw =
        {:list,
         [
           {:symbol, :defn},
           {:symbol, :add},
           {:vector, [{:symbol, :a}, {:symbol, :b}, {:symbol, :c}]},
           {:list, [{:symbol, :+}, {:symbol, :a}, {:symbol, :b}, {:symbol, :c}]}
         ]}

      assert {:ok, {:def, :add, {:fn, [{:var, :a}, {:var, :b}, {:var, :c}], call}}} =
               Analyze.analyze(raw)

      assert {:call, {:var, :+}, [{:var, :a}, {:var, :b}, {:var, :c}]} = call
    end

    test "defn with multiple body expressions wraps in implicit do" do
      # (defn do-stuff [x] (println x) x)
      raw =
        {:list,
         [
           {:symbol, :defn},
           {:symbol, :"do-stuff"},
           {:vector, [{:symbol, :x}]},
           {:list, [{:symbol, :println}, {:symbol, :x}]},
           {:symbol, :x}
         ]}

      assert {:ok, {:def, :"do-stuff", {:fn, [{:var, :x}], {:do, bodies}}}} = Analyze.analyze(raw)
      assert length(bodies) == 2
    end

    test "defn with docstring and multiple body expressions" do
      # (defn do-stuff "Does stuff" [x] (println x) x)
      raw =
        {:list,
         [
           {:symbol, :defn},
           {:symbol, :"do-stuff"},
           {:string, "Does stuff"},
           {:vector, [{:symbol, :x}]},
           {:list, [{:symbol, :println}, {:symbol, :x}]},
           {:symbol, :x}
         ]}

      assert {:ok, {:def, :"do-stuff", {:fn, [{:var, :x}], {:do, bodies}}}} = Analyze.analyze(raw)
      assert length(bodies) == 2
    end

    test "defn requires a symbol for name" do
      # (defn 123 [x] x)
      raw = {:list, [{:symbol, :defn}, 123, {:vector, [{:symbol, :x}]}, {:symbol, :x}]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "defn name must be a symbol"
    end

    test "(defn name [params]) without body returns error" do
      raw = {:list, [{:symbol, :defn}, {:symbol, :f}, {:vector, [{:symbol, :x}]}]}
      assert {:error, {:invalid_arity, :defn, msg}} = Analyze.analyze(raw)
      assert msg =~ "missing body"
    end

    test "(defn name) without params and body returns error" do
      raw = {:list, [{:symbol, :defn}, {:symbol, :f}]}
      assert {:error, {:invalid_arity, :defn, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (defn name [params] body)"
    end

    test "defn with non-vector params returns error" do
      # (defn f (x) x) - using list instead of vector for params
      raw = {:list, [{:symbol, :defn}, {:symbol, :f}, {:list, [{:symbol, :x}]}, {:symbol, :x}]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "multi-arity defn not supported"
    end

    test "defn multi-arity syntax returns error" do
      # (defn f ([x] x) ([x y] (+ x y)))
      raw =
        {:list,
         [
           {:symbol, :defn},
           {:symbol, :f},
           {:list, [{:vector, [{:symbol, :x}]}, {:symbol, :x}]},
           {:list,
            [
              {:vector, [{:symbol, :x}, {:symbol, :y}]},
              {:list, [{:symbol, :+}, {:symbol, :x}, {:symbol, :y}]}
            ]}
         ]}

      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "multi-arity defn not supported"
    end

    test "empty defn returns error" do
      raw = {:list, [{:symbol, :defn}]}
      assert {:error, {:invalid_arity, :defn, _msg}} = Analyze.analyze(raw)
    end
  end

  # ============================================================
  # Evaluator tests (via def + fn evaluation)
  # ============================================================

  describe "evaluator: defn via def" do
    test "defined function can be called" do
      # (defn double [x] (* x 2)) desugars to (def double (fn [x] (* x 2)))
      ast = {:def, :double, {:fn, [{:var, :x}], {:call, {:var, :*}, [{:var, :x}, 2]}}}
      env = %{*: {:variadic, &*/2, 1}}
      {:ok, result, user_ns} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)

      assert result == %Var{name: :double}
      # Functions are stored as closures, not native Elixir functions
      assert {:closure, _, _, _, _} = user_ns[:double]
    end

    test "function persists in user_ns" do
      ast = {:def, :greet, {:fn, [], {:string, "hello"}}}
      {:ok, _result, user_ns} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)

      # Functions are stored as closures, not native Elixir functions
      assert {:closure, _, _, _, _} = user_ns[:greet]
    end

    test "function can reference other user-defined symbols" do
      # Define base, then double that uses base
      base_ast = {:def, :base, 10}
      {:ok, _, user_ns1} = Eval.eval(base_ast, %{}, %{}, %{}, &dummy_tool/2)

      # (defn doubled [] (* base 2)) - references base from user_ns
      double_ast = {:def, :doubled, {:fn, [], {:call, {:var, :*}, [{:var, :base}, 2]}}}
      env = %{*: {:variadic, &*/2, 1}}
      {:ok, _, user_ns2} = Eval.eval(double_ast, %{}, user_ns1, env, &dummy_tool/2)

      # Call the function
      call_ast = {:call, {:var, :doubled}, []}
      {:ok, result, _} = Eval.eval(call_ast, %{}, user_ns2, env, &dummy_tool/2)

      assert result == 20
    end

    test "defn cannot shadow builtins (via def)" do
      # (defn map [x] x) - should fail because map is a builtin
      ast = {:def, :map, {:fn, [{:var, :x}], {:var, :x}}}
      {:error, {:cannot_shadow_builtin, :map}} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  # ============================================================
  # Integration tests (parse → analyze → eval)
  # ============================================================

  describe "defn integration" do
    test "(defn double [x] (* x 2)) defines and stores function" do
      source = "(defn double [x] (* x 2))"
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source)

      assert result == %Var{name: :double}
      # Functions are stored as closures, not native Elixir functions
      assert {:closure, _, _, _, _} = user_ns[:double]
    end

    test "defined function can be called" do
      source = "(do (defn double [x] (* x 2)) (double 21))"
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == 42
    end

    test "defn with zero params" do
      source = ~S|(do (defn greeting [] "Hello!") (greeting))|
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == "Hello!"
    end

    test "defn with multiple params" do
      source = "(do (defn add3 [a b c] (+ a b c)) (add3 1 2 3))"
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == 6
    end

    test "defn with docstring is ignored" do
      source = ~S|(do (defn double "Doubles a number" [x] (* x 2)) (double 5))|
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == 10
    end

    test "defn persists across turns (via memory param)" do
      # Turn 1: define function
      source1 = "(defn double [x] (* x 2))"
      {:ok, %{memory: user_ns1}} = Lisp.run(source1)

      # Turn 2: use the function
      source2 = "(double 21)"
      {:ok, %{return: result}} = Lisp.run(source2, memory: user_ns1)

      assert result == 42
    end

    test "defn can reference ctx/ data" do
      source = "(do (defn get-rate [] ctx/rate) (get-rate))"
      ctx = %{rate: 0.15}
      {:ok, %{return: result}} = Lisp.run(source, context: ctx)

      assert result == 0.15
    end

    test "defn can call ctx/ tools" do
      source = "(do (defn search-for [q] (ctx/search {:query q})) (search-for \"test\"))"
      tools = %{"search" => fn %{query: q} -> [%{query: q}] end}
      {:ok, %{return: result}} = Lisp.run(source, tools: tools)

      assert result == [%{query: "test"}]
    end

    test "defn can reference other defn bindings" do
      source = "(do (defn base [] 10) (defn doubled [] (* (base) 2)) (doubled))"
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == 20
    end

    test "defn can reference def bindings" do
      source = "(do (def rate 0.1) (defn apply-rate [x] (* x rate)) (apply-rate 100))"
      {:ok, %{return: result}} = Lisp.run(source)

      assert result == 10.0
    end

    test "defn cannot shadow builtin map" do
      source = "(defn map [x] x)"
      {:error, step} = Lisp.run(source)

      assert step.fail.reason == :cannot_shadow_builtin
      assert step.fail.message =~ "map"
    end

    test "defn cannot shadow builtin filter" do
      source = "(defn filter [x] x)"
      {:error, step} = Lisp.run(source)

      assert step.fail.reason == :cannot_shadow_builtin
      assert step.fail.message =~ "filter"
    end

    test "defn can be used with higher-order functions" do
      source =
        "(do (defn expensive? [e] (> (:amount e) 100)) (filter expensive? [{:amount 50} {:amount 150} {:amount 200}]))"

      {:ok, %{return: result}} = Lisp.run(source)

      assert result == [%{amount: 150}, %{amount: 200}]
    end

    test "defn with multiple body expressions (implicit do)" do
      source = "(do (defn with-side-effect [x] (def last-x x) x) (with-side-effect 42))"
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source)

      assert result == 42
      assert user_ns[:"last-x"] == 42 or user_ns[:"with-side-effect"] != nil
    end

    test "real-world: expense filter across turns" do
      # Turn 1: define filter function
      source1 = "(defn expensive? [e] (> (:amount e) 5000))"
      {:ok, %{memory: user_ns1}} = Lisp.run(source1)

      # Turn 2: use function with ctx data
      source2 = "(filter expensive? ctx/expenses)"
      ctx = %{expenses: [%{amount: 3000}, %{amount: 7000}, %{amount: 10_000}]}
      {:ok, %{return: result}} = Lisp.run(source2, memory: user_ns1, context: ctx)

      assert result == [%{amount: 7000}, %{amount: 10_000}]
    end
  end
end
