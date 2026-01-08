defmodule PtcRunner.Lisp.AnalyzeIfArityTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  describe "if arity" do
    test "2-arg if returns value when true" do
      {:ok, step} = Lisp.run("(if true :yes)")
      assert step.return == :yes
    end

    test "2-arg if returns nil when false" do
      {:ok, step} = Lisp.run("(if false :yes)")
      assert step.return == nil
    end

    test "3-arg if still works" do
      {:ok, step} = Lisp.run("(if true :yes :no)")
      assert step.return == :yes
      {:ok, step} = Lisp.run("(if false :yes :no)")
      assert step.return == :no
    end

    test "0-arg still raise arity error" do
      assert {:error, step} = Lisp.run("(if)")
      assert step.fail.message =~ "expected (if cond then else?)"
    end

    test "1-arg still raise arity error" do
      assert {:error, step} = Lisp.run("(if true)")
      assert step.fail.message =~ "expected (if cond then else?)"
    end

    test "4+ args still raise arity error" do
      assert {:error, step} = Lisp.run("(if true :a :b :c)")
      assert step.fail.message =~ "expected (if cond then else?)"
    end
  end

  describe "if-not arity" do
    test "2-arg if-not returns value when false" do
      {:ok, step} = Lisp.run("(if-not false :yes)")
      assert step.return == :yes
    end

    test "2-arg if-not returns nil when true" do
      {:ok, step} = Lisp.run("(if-not true :yes)")
      assert step.return == nil
    end

    test "3-arg if-not still works" do
      {:ok, step} = Lisp.run("(if-not false :yes :no)")
      assert step.return == :yes
      {:ok, step} = Lisp.run("(if-not true :yes :no)")
      assert step.return == :no
    end
  end

  describe "when regression" do
    test "when with single body expression" do
      {:ok, step} = Lisp.run("(when true :yes)")
      assert step.return == :yes
      {:ok, step} = Lisp.run("(when false :yes)")
      assert step.return == nil
    end

    test "when with multiple body expressions" do
      {:ok, step} = Lisp.run("(when true (def a 1) (+ a 1))")
      assert step.return == 2
    end
  end
end
