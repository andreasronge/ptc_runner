defmodule PtcRunner.Lisp.ArityErrorReproTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  describe "arity error messages include function name" do
    test "range without args" do
      {:error, step} = Lisp.run("(range)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: range expects 1, 2, 3 argument(s), got 0"
    end

    test "get without args" do
      {:error, step} = Lisp.run("(get)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: get expects 2 or 3 argument(s), got 0"
    end

    test "reduce without args" do
      {:error, step} = Lisp.run("(reduce)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: reduce expects 2 or 3 argument(s), got 0"
    end

    test "join without args" do
      {:error, step} = Lisp.run("(join)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: join expects 1 or 2 argument(s), got 0"
    end

    test "subs without args" do
      {:error, step} = Lisp.run("(subs)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: subs expects 2 or 3 argument(s), got 0"
    end

    test "sort-by without args" do
      {:error, step} = Lisp.run("(sort-by)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: sort-by expects 2 or 3 argument(s), got 0"
    end

    test "get-in without args" do
      {:error, step} = Lisp.run("(get-in)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: get-in expects 2 or 3 argument(s), got 0"
    end

    test "/ without args (variadic_nonempty)" do
      {:error, step} = Lisp.run("(/)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: / requires at least 1 argument, got 0"
    end

    test "conj without args (variadic_nonempty)" do
      {:error, step} = Lisp.run("(conj)")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: conj requires at least 1 argument, got 0"
    end
  end

  describe "LLM-generated code error scenario" do
    test "complex expression with (range) fails with helpful message" do
      # This reproduces the LLM-generated code scenario where deepseek-coder
      # generates code using (range) without arguments (infinite range not supported)
      lisp = "(filter inc (range))"
      {:error, step} = Lisp.run(lisp)
      assert step.fail.reason == :arity_error
      assert step.fail.message =~ "range expects"
    end
  end
end
