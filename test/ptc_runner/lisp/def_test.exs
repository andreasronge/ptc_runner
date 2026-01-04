defmodule PtcRunner.Lisp.DefTest do
  @moduledoc """
  Tests for the `def` special form for user namespace bindings.

  The `def` form binds values in the user namespace, persisting across turns.
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

  describe "analyzer: def" do
    test "(def name value) analyzes to {:def, name, analyzed_value}" do
      raw = {:list, [{:symbol, :def}, {:symbol, :x}, 42]}
      assert {:ok, {:def, :x, 42}} = Analyze.analyze(raw)
    end

    test "(def name docstring value) ignores docstring" do
      raw = {:list, [{:symbol, :def}, {:symbol, :x}, {:string, "doc"}, 42]}
      assert {:ok, {:def, :x, 42}} = Analyze.analyze(raw)
    end

    test "def analyzes the value expression" do
      raw = {:list, [{:symbol, :def}, {:symbol, :result}, {:symbol, :x}]}
      assert {:ok, {:def, :result, {:var, :x}}} = Analyze.analyze(raw)
    end

    test "def requires a symbol for name" do
      raw = {:list, [{:symbol, :def}, {:string, "not-a-symbol"}, 42]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "def name must be a symbol"
    end

    test "(def name) without value returns error" do
      raw = {:list, [{:symbol, :def}, {:symbol, :x}]}
      assert {:error, {:invalid_arity, :def, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (def name value)"
      assert msg =~ "without value"
    end

    test "def with too many args returns error" do
      # (def 42 "doc" 100 200) - first arg is not a symbol
      raw = {:list, [{:symbol, :def}, 42, {:string, "doc"}, 100, 200]}
      assert {:error, {:invalid_form, msg}} = Analyze.analyze(raw)
      assert msg =~ "def name must be a symbol"
    end

    test "def with 4 args (name, doc, value, extra) returns error" do
      # Pattern matching catches the docstring case before arity check
      # With more than 3 args after def, we fall through to catch-all
      raw = {:list, [{:symbol, :def}, {:symbol, :x}, {:string, "doc"}, 42, 100]}
      assert {:error, {:invalid_arity, :def, msg}} = Analyze.analyze(raw)
      assert msg =~ "expected (def name value)"
    end

    test "empty def returns error" do
      raw = {:list, [{:symbol, :def}]}
      assert {:error, {:invalid_arity, :def, _msg}} = Analyze.analyze(raw)
    end
  end

  # ============================================================
  # Evaluator tests
  # ============================================================

  describe "evaluator: def" do
    test "(def x 42) returns var and stores in user_ns" do
      ast = {:def, :x, 42}
      {:ok, result, user_ns} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)

      assert result == %Var{name: :x}
      assert user_ns == %{x: 42}
    end

    test "def evaluates value expression before storing" do
      # (def result (+ 5 3))
      ast = {:def, :result, {:call, {:var, :+}, [5, 3]}}
      env = %{+: {:variadic, &+/2, 0}}
      {:ok, result, user_ns} = Eval.eval(ast, %{}, %{}, env, &dummy_tool/2)

      assert result == %Var{name: :result}
      assert user_ns == %{result: 8}
    end

    test "def overwrites existing binding" do
      ast = {:def, :x, 100}
      {:ok, _result, user_ns} = Eval.eval(ast, %{}, %{x: 42}, %{}, &dummy_tool/2)

      assert user_ns == %{x: 100}
    end

    test "def cannot shadow builtins" do
      ast = {:def, :map, {:map, []}}
      {:error, {:cannot_shadow_builtin, :map}} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "def cannot shadow filter builtin" do
      ast = {:def, :filter, 42}
      {:error, {:cannot_shadow_builtin, :filter}} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "nested def returns inner var" do
      # (def x (def y 1)) - y is defined, x gets the var #'y
      inner = {:def, :y, 1}
      outer = {:def, :x, inner}
      {:ok, result, user_ns} = Eval.eval(outer, %{}, %{}, %{}, &dummy_tool/2)

      assert result == %Var{name: :x}
      assert user_ns[:y] == 1
      assert user_ns[:x] == %Var{name: :y}
    end
  end

  # ============================================================
  # Variable resolution tests
  # ============================================================

  describe "variable resolution with def bindings" do
    test "bare symbol resolves to def binding" do
      # Simulate having defined x = 42 via def
      ast = {:var, :x}
      user_ns = %{x: 42}
      {:ok, value, _} = Eval.eval(ast, %{}, user_ns, %{}, &dummy_tool/2)

      assert value == 42
    end

    test "let binding shadows def binding" do
      # (let [x 10] x) where x is also defined in user_ns
      let_ast = {:let, [{:binding, {:var, :x}, 10}], {:var, :x}}
      user_ns = %{x: 42}
      {:ok, value, _} = Eval.eval(let_ast, %{}, user_ns, %{}, &dummy_tool/2)

      assert value == 10
    end

    test "def binding shadows builtins" do
      # Define count as 999 in user_ns
      ast = {:var, :count}
      user_ns = %{count: 999}
      {:ok, value, _} = Eval.eval(ast, %{}, user_ns, %{}, &dummy_tool/2)

      # The builtin count function is shadowed by the user binding
      # But wait - def cannot shadow builtins, so this shouldn't happen
      # This test is actually checking that user_ns takes precedence when reading
      # However, def will error when trying to create the binding
      # So this scenario can only happen if user_ns is populated externally
      assert value == 999
    end

    test "builtin resolves when not shadowed" do
      ast = {:var, :count}
      {:ok, value, _} = Eval.eval(ast, %{}, %{}, %{}, &dummy_tool/2)

      # count should be a builtin
      assert is_tuple(value)
      assert elem(value, 0) == :normal
    end

    test "resolution order: env > user_ns > builtins" do
      ast = {:var, :x}
      env = %{x: :from_env}
      user_ns = %{x: :from_user_ns}
      {:ok, value, _} = Eval.eval(ast, %{}, user_ns, env, &dummy_tool/2)

      assert value == :from_env
    end
  end

  # ============================================================
  # Integration tests (parse → analyze → eval)
  # ============================================================

  describe "def integration" do
    test "(def x 42) stores and evaluates correctly" do
      source = "(def x 42)"
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source)

      assert result == %Var{name: :x}
      assert user_ns == %{x: 42}
    end

    test "(def x \"docstring\" 42) ignores docstring" do
      source = ~S|(def x "the value is 42" 42)|
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source)

      assert result == %Var{name: :x}
      assert user_ns == %{x: 42}
    end

    test "def with expression value" do
      source = "(def result (+ 1 2 3))"
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source)

      assert result == %Var{name: :result}
      assert user_ns == %{result: 6}
    end

    test "def binding is accessible in subsequent expressions" do
      source = "(do (def x 10) x)"
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source)

      assert result == 10
      assert user_ns == %{x: 10}
    end

    test "def can be redefined" do
      source = "(do (def x 1) (def x 2) x)"
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source)

      assert result == 2
      assert user_ns == %{x: 2}
    end

    test "def can reference previous def in same do block" do
      source = "(do (def a 1) (def b (+ a 1)) b)"
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source)

      assert result == 2
      assert user_ns == %{a: 1, b: 2}
    end

    test "def persists across turns (via memory param)" do
      # Turn 1: define x
      source1 = "(def x 42)"
      {:ok, %{memory: user_ns1}} = Lisp.run(source1)

      # Turn 2: use x (passed via memory param)
      source2 = "x"
      {:ok, %{return: result}} = Lisp.run(source2, memory: user_ns1)

      assert result == 42
    end

    test "def with tool call result" do
      source = "(def results (call \"search\" {:query \"test\"}))"
      tools = %{"search" => fn _args -> [%{id: 1}, %{id: 2}] end}
      {:ok, %{return: result, memory: user_ns}} = Lisp.run(source, tools: tools)

      assert result == %Var{name: :results}
      assert user_ns == %{results: [%{id: 1}, %{id: 2}]}
    end

    test "def cannot shadow builtin map" do
      source = "(def map {})"
      {:error, step} = Lisp.run(source)

      assert step.fail.reason == :cannot_shadow_builtin
      assert step.fail.message =~ "map"
    end

    test "def cannot shadow builtin filter" do
      source = "(def filter [])"
      {:error, step} = Lisp.run(source)

      assert step.fail.reason == :cannot_shadow_builtin
      assert step.fail.message =~ "filter"
    end

    test "def can shadow ctx names but ctx/ prefix still works" do
      source = "(do (def expenses []) [expenses ctx/expenses])"
      ctx = %{expenses: [%{id: 1}]}
      {:ok, %{return: result}} = Lisp.run(source, context: ctx)

      assert result == [[], [%{id: 1}]]
    end
  end

  # ============================================================
  # Var formatting tests
  # ============================================================

  describe "var formatting" do
    test "Var struct inspects as #'name" do
      var = %Var{name: :x}
      assert inspect(var) == "#'x"
    end

    test "Var with hyphenated name inspects correctly" do
      var = %Var{name: :"my-var"}
      assert inspect(var) == "#'my-var"
    end
  end
end
