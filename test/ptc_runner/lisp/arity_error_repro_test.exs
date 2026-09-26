defmodule PtcRunner.Lisp.ArityErrorReproTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  test "multi-arity errors name each function and its accepted arities" do
    for {name, expected} <- [
          {"range", "1, 2, 3"},
          {"get", "2 or 3"},
          {"reduce", "2 or 3"},
          {"join", "1 or 2"},
          {"subs", "2 or 3"},
          {"sort-by", "2 or 3"},
          {"get-in", "2 or 3"}
        ] do
      {:error, step} = Lisp.run("(#{name})")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: #{name} expects #{expected} argument(s), got 0"
    end
  end

  test "variadic nonempty errors name the function and minimum arity" do
    {:error, step} = Lisp.run("(/)")
    assert step.fail.reason == :arity_error
    assert step.fail.message == "arity error: / requires at least 1 argument, got 0"
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
