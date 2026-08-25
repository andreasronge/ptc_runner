defmodule PtcRunner.Lisp.AnalyzeRecurArityTest do
  @moduledoc """
  Compile-time recur arity (issue #1638).

  Wrong-arity `recur` must fail while analyzing the nearest `loop`/`fn`/`defn`
  recursion point, including dormant definitions that are never invoked.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.{Analyze, Env, Eval, Parser}

  defp analyze_source(source) do
    assert {:ok, raw} = Parser.parse(source)
    Analyze.analyze(raw)
  end

  defp assert_recur_arity_error(source, expected, actual) do
    assert {:error, {:invalid_arity, :recur, msg}} = analyze_source(source)
    assert msg =~ "recur"
    assert msg =~ "#{expected}"
    assert msg =~ "#{actual}"
    msg
  end

  describe "dormant defn (issue #1638 reproduction)" do
    test "wrong-arity recur is rejected while analyzing an uncalled defn" do
      source = "(defn bad [] (loop [x 1 y 2] (recur 1 2 3)))"

      assert_recur_arity_error(source, 2, 3)

      assert {:error, %{fail: %{reason: :invalid_arity, message: msg}}} = Lisp.run(source)
      assert msg =~ "recur"
      assert msg =~ "2"
      assert msg =~ "3"
    end
  end

  describe "immediate loop" do
    test "wrong-arity recur is rejected before loop execution" do
      source = "(loop [x 1 y 2] (recur 1 2 3))"
      assert_recur_arity_error(source, 2, 3)

      assert {:error, %{fail: %{reason: :invalid_arity}}} = Lisp.run(source)
    end

    test "matching recur arity analyzes successfully" do
      assert {:ok, {:loop, [_x, _y], {:recur, [_, _]}}} =
               analyze_source("(loop [x 1 y 2] (recur 1 2))")
    end
  end

  describe "fixed-arity fn and defn" do
    test "fn rejects a recur that does not match its parameter-slot count" do
      assert_recur_arity_error("(fn [x] (recur x 1))", 1, 2)
    end

    test "defn rejects a recur that does not match its parameter-slot count" do
      assert_recur_arity_error("(defn f [x y] (recur x))", 2, 1)
    end

    test "fixed-arity matching recur analyzes successfully" do
      assert {:ok, {:fn, [{:var, :x}], {:recur, [{:var, :x}]}}} =
               analyze_source("(fn [x] (recur x))")
    end
  end

  describe "variadic functions" do
    test "rejects a recur that omits the rest-parameter slot" do
      assert_recur_arity_error("(fn [x & xs] (recur 1))", 2, 1)
    end

    test "accepts leading-plus-rest recur arguments" do
      assert {:ok, {:fn, {:variadic, [{:var, :x}], {:var, :xs}}, {:recur, args}}} =
               analyze_source("(fn [x & xs] (recur 1 []))")

      assert length(args) == 2
    end

    test "ordinary variadic invocation is unchanged" do
      assert {:ok, %{return: [2, 3]}} = Lisp.run("((fn [x & xs] xs) 1 2 3)")
    end
  end

  describe "nearest recursion point" do
    test "loop inside a function validates against the loop, not the function" do
      assert {:ok, {:fn, [{:var, :a}, {:var, :b}], {:loop, [_], {:recur, [_]}}}} =
               analyze_source("(fn [a b] (loop [x 1] (recur 1)))")

      assert_recur_arity_error("(fn [a b] (loop [x 1] (recur 1 2)))", 1, 2)
    end

    test "function inside a loop validates against the function, then restores the loop" do
      assert_recur_arity_error("(loop [x 1 y 2] ((fn [a] (recur a a)) x))", 1, 2)

      assert {:ok, {:loop, [_x, _y], _body}} =
               analyze_source("""
               (loop [x 1 y 2]
                 ((fn [a] a) x)
                 (recur 1 2))
               """)

      assert_recur_arity_error(
        """
        (loop [x 1 y 2]
          ((fn [a] a) x)
          (recur 1))
        """,
        2,
        1
      )
    end
  end

  describe "destructured slots" do
    test "a destructured loop binding counts as one recur slot" do
      assert {:ok, {:loop, [_binding], {:recur, [_]}}} =
               analyze_source("(loop [[x y] [1 2]] (recur [3 4]))")

      assert_recur_arity_error("(loop [[x y] [1 2]] (recur 1 2))", 1, 2)
    end

    test "a destructured function parameter counts as one recur slot" do
      assert {:ok, {:fn, [_pattern], {:recur, [_]}}} =
               analyze_source("(fn [{:keys [a b]}] (recur {:a 1 :b 2}))")

      assert_recur_arity_error("(fn [{:keys [a b]}] (recur 1 2))", 1, 2)
    end
  end

  describe "threaded recur" do
    test "bare threaded recur with matching arity is accepted" do
      assert {:ok, _} = analyze_source("(loop [x 0] (if (< x 5) (-> x inc recur) x))")
      assert {:ok, %{return: 5}} = Lisp.run("(loop [x 0] (if (< x 5) (-> x inc recur) x))")
    end

    test "bare threaded recur with the wrong arity is rejected" do
      assert_recur_arity_error("(loop [x 0 y 1] (-> x recur))", 2, 1)
    end

    test "list-form threaded recur with the wrong arity is rejected" do
      assert_recur_arity_error("(loop [x 0] (-> x (recur 1)))", 1, 2)
    end
  end

  describe "non-tail position is unchanged" do
    test "non-tail recur is still invalid_form even when arity also mismatches" do
      assert {:error, {:invalid_form, msg}} = analyze_source("(loop [x 0 y 1] (+ 1 (recur)))")
      assert msg =~ "tail position"
    end
  end

  describe "generated iteration" do
    test "doseq-generated loop/recur still analyzes and runs" do
      assert {:ok, _} = analyze_source("(doseq [x [1 2 3]] x)")

      assert {:ok, %{return: nil, prints: ["1", "2", "3"]}} =
               Lisp.run("(doseq [x [1 2 3]] (println x))")
    end

    test "for-generated loop/recur still analyzes and runs" do
      assert {:ok, _} = analyze_source("(for [x [1 2 3]] (* x 2))")
      assert {:ok, %{return: [2, 4, 6]}} = Lisp.run("(for [x [1 2 3]] (* x 2))")
    end
  end

  describe "runtime arity_mismatch defense" do
    test "evaluator still rejects a wrong-arity recur CoreAST" do
      ast = {:loop, [{:binding, {:var, :x}, 0}], {:recur, []}}
      env = Env.initial()

      assert {:error, {:arity_mismatch, 1, 0}} =
               Eval.eval(ast, %{}, %{}, env, fn _, _ -> nil end)
    end
  end
end
