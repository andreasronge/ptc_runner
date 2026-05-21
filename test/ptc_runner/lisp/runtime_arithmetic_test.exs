defmodule PtcRunner.Lisp.RuntimeArithmeticTest do
  use ExUnit.Case

  # ============================================================
  # Rounding Functions
  # ============================================================
  # These tests verify the rounding functions added as PTC-Lisp extensions.
  # Note: These are NOT standard Clojure functions - do not use assert_clojure_equivalent.

  describe "floor - rounds toward negative infinity" do
    test "positive float" do
      assert_lisp("(floor 3.7)", 3)
    end

    test "negative float" do
      assert_lisp("(floor -3.7)", -4)
    end

    test "integer (no-op)" do
      assert_lisp("(floor 5)", 5)
    end

    test "positive float at boundary" do
      assert_lisp("(floor 3.0)", 3)
    end
  end

  describe "ceil - rounds toward positive infinity" do
    test "positive float" do
      assert_lisp("(ceil 3.2)", 4)
    end

    test "negative float" do
      assert_lisp("(ceil -3.2)", -3)
    end

    test "integer (no-op)" do
      assert_lisp("(ceil 5)", 5)
    end

    test "positive float at boundary" do
      assert_lisp("(ceil 3.0)", 3)
    end
  end

  describe "round - rounds to nearest integer" do
    test "positive float rounds up at 0.5" do
      assert_lisp("(round 3.5)", 4)
    end

    test "positive float rounds down below 0.5" do
      assert_lisp("(round 3.4)", 3)
    end

    test "negative float rounds away from zero at 0.5" do
      # Elixir rounds away from zero at 0.5
      assert_lisp("(round -3.5)", -4)
    end

    test "integer (no-op)" do
      assert_lisp("(round 5)", 5)
    end
  end

  describe "trunc - truncates toward zero" do
    test "positive float" do
      assert_lisp("(trunc 3.7)", 3)
    end

    test "negative float" do
      # Different from floor: trunc goes toward zero
      assert_lisp("(trunc -3.7)", -3)
    end

    test "integer (no-op)" do
      assert_lisp("(trunc 5)", 5)
    end
  end

  describe "sqrt - square root" do
    test "perfect square" do
      assert_lisp("(sqrt 16)", 4.0)
    end

    test "Math namespace shorthand" do
      assert_lisp("(Math/sqrt 25)", 5.0)
    end
  end

  describe "arbitrary precision Clojure aliases" do
    test "arithmetic prime forms reuse BEAM integer arithmetic" do
      assert_lisp("(+' 1 2 3)", 6)
      assert_lisp("(-' 10 3 2)", 5)
      assert_lisp("(*' 2 3 4)", 24)
    end

    test "-' without args returns a clean arity error" do
      {:error, step} = PtcRunner.Lisp.run("(-')")
      assert step.fail.reason == :arity_error
      assert step.fail.message == "arity error: -' requires at least 1 argument, got 0"
    end

    test "inc' and dec' alias inc and dec" do
      assert_lisp("(inc' 41)", 42)
      assert_lisp("(dec' 43)", 42)
    end
  end

  describe "pow - exponentiation" do
    test "square" do
      assert_lisp("(pow 2 3)", 8.0)
    end

    test "Math namespace shorthand" do
      assert_lisp("(Math/pow 3 2)", 9.0)
    end
  end

  describe "float - alias for double" do
    test "converts integer to float" do
      assert_lisp("(float 5)", 5.0)
    end

    test "float of float is identity" do
      assert_lisp("(float 3.14)", 3.14)
    end

    test "handles special values" do
      assert_lisp("(float Double/NaN)", :nan)
      assert_lisp("(float Double/POSITIVE_INFINITY)", :infinity)
      assert_lisp("(float Double/NEGATIVE_INFINITY)", :negative_infinity)
    end
  end

  # Clojure conformance: `(/ 1 0)` throws ArithmeticException on the JVM,
  # but `(/ 1.0 0.0)` returns ##Inf per IEEE 754. PTC-Lisp must match.
  describe "/ - division by zero (Clojure conformance)" do
    test "integer / integer raises division by zero" do
      assert {:error, %{fail: %{message: message}}} = PtcRunner.Lisp.run("(/ 10 0)")
      assert message =~ "division by zero"
    end

    test "negative integer / 0 raises division by zero" do
      assert {:error, %{fail: %{message: message}}} = PtcRunner.Lisp.run("(/ -5 0)")
      assert message =~ "division by zero"
    end

    test "0 / 0 raises division by zero" do
      assert {:error, %{fail: %{message: message}}} = PtcRunner.Lisp.run("(/ 0 0)")
      assert message =~ "division by zero"
    end

    test "float / float keeps IEEE 754 ##Inf" do
      assert_lisp("(/ 1.0 0.0)", :infinity)
      assert_lisp("(/ -1.0 0.0)", :negative_infinity)
      assert_lisp("(/ 0.0 0.0)", :nan)
    end

    test "mixed-mode / 0 raises (any operand integer with integer 0 divisor)" do
      assert {:error, %{fail: %{message: message}}} = PtcRunner.Lisp.run("(/ 1.5 0)")
      assert message =~ "division by zero"
    end
  end

  describe "quot - integer division (truncates toward zero)" do
    test "positive integers" do
      assert_lisp("(quot 7 2)", 3)
    end

    test "negative dividend truncates toward zero" do
      assert_lisp("(quot -7 2)", -3)
    end

    test "negative divisor truncates toward zero" do
      assert_lisp("(quot 7 -2)", -3)
    end

    test "both negative truncates toward zero" do
      assert_lisp("(quot -7 -2)", 3)
    end

    test "handles floats" do
      assert_lisp("(quot 7.5 2)", 3)
    end

    test "division by zero raises ArithmeticError" do
      assert {:error, %{fail: %{message: message}}} = PtcRunner.Lisp.run("(quot 7 0)")
      assert message =~ "division by zero"
    end

    test "special values return NaN" do
      assert_lisp("(quot Double/NaN 2)", :nan)
      assert_lisp("(quot 7 Double/NaN)", :nan)
      assert_lisp("(quot Double/POSITIVE_INFINITY 2)", :nan)
    end

    test "practical use case: splitting collections" do
      assert_lisp("(take (quot 5 2) [1 2 3 4 5])", [1, 2])
    end
  end

  describe "equality" do
    test "= is variadic with one or more arguments" do
      assert_lisp("(= 1)", true)
      assert_lisp("(= 1 1 1)", true)
      assert_lisp("(= 1 2 1)", false)
      assert_lisp("(apply = [1 1 1])", true)
    end

    test "== is variadic with one or more arguments" do
      assert_lisp("(== 1)", true)
      assert_lisp("(== 1 1 1)", true)
      assert_lisp("(== 1 2 1)", false)
    end

    test "not= is variadic complement of = with one or more arguments" do
      assert_lisp("(not= 1)", false)
      assert_lisp("(not= 1 2 1)", true)
      assert_lisp("(not= 1 1 1)", false)
    end

    test "zero-arity equality forms are arity errors" do
      assert_lisp_error("(=)", :arity_error, "= requires at least 1 argument")
      assert_lisp_error("(==)", :arity_error, "== requires at least 1 argument")
      assert_lisp_error("(not=)", :arity_error, "not= requires at least 1 argument")
      assert_lisp_error("(apply = [])", :arity_error, "= requires at least 1 argument")
    end
  end

  describe "ordered comparisons" do
    test "ordered comparisons are variadic with one or more arguments" do
      assert_lisp("(< 1)", true)
      assert_lisp("(< 1 2 3)", true)
      assert_lisp("(< 1 3 2)", false)
      assert_lisp("(<= 1 1 2)", true)
      assert_lisp("(<= 1 2 1)", false)
      assert_lisp("(> 3 2 1)", true)
      assert_lisp("(> 3 1 2)", false)
      assert_lisp("(>= 3 3 2)", true)
      assert_lisp("(>= 3 2 3)", false)
    end

    test "apply with ordered comparisons" do
      assert_lisp("(apply <= [1 5 10])", true)
      assert_lisp("(apply > [3 2 1])", true)
      assert_lisp("(apply < [1 3 2])", false)
    end

    test "ordered comparisons are recoverable for nil and mixed scalar values" do
      assert_lisp("(< 1 nil)", true)
      assert_lisp("(> 1 nil)", false)
      assert_lisp(~S[(< 1 "2")], true)
      assert_lisp(~S[(> "b" "a")], true)
      assert_lisp("(<= nil nil)", true)
      assert_lisp("(< :a :b)", true)
    end

    test "NaN ordered comparisons return false" do
      assert_lisp("(< Double/NaN 0)", false)
      assert_lisp("(> 0 Double/NaN)", false)
      assert_lisp("(< 0 Double/NaN 1)", false)
    end

    test "zero-arity ordered comparison forms are arity errors" do
      assert_lisp_error("(<)", :arity_error, "< requires at least 1 argument")
      assert_lisp_error("(>)", :arity_error, "> requires at least 1 argument")
      assert_lisp_error("(<=)", :arity_error, "<= requires at least 1 argument")
      assert_lisp_error("(>=)", :arity_error, ">= requires at least 1 argument")
      assert_lisp_error("(apply < [])", :arity_error, "< requires at least 1 argument")
    end
  end

  defp assert_lisp(source, expected) do
    {:ok, %{return: result}} = PtcRunner.Lisp.run(source)
    assert result == expected
  end

  defp assert_lisp_error(source, reason, message) do
    assert {:error, %{fail: %{reason: ^reason, message: actual}}} = PtcRunner.Lisp.run(source)
    assert actual =~ message
  end
end
