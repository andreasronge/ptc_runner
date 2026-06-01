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

  describe "Clojure arithmetic/range conformance quick wins" do
    test "zero-arity minus is an arity error" do
      assert_lisp_error("(-)", :arity_error, "- requires at least 1 argument")
    end

    test "unary division returns reciprocal and rejects nonnumeric inputs" do
      assert_lisp("(/ 2)", 0.5)
      assert_lisp_error("(/ :a)", :type_error, "invalid argument types")
    end

    test "unary addition and multiplication reject nonnumeric inputs" do
      assert_lisp_error("(+ [1 2])", :type_error, "expected number")
      assert_lisp_error("(* :a)", :type_error, "expected number")
    end

    test "unary addition preserves signed zero while validating input" do
      assert_lisp("(str (+ -0.0))", "-0.0")
      assert_lisp("(first (map str (map + [-0.0])))", "-0.0")
    end

    test "higher-order unary arithmetic rejects nonnumeric inputs as type errors" do
      assert_lisp_error("(map + [[1 2]])", :type_error, "invalid argument types")
      assert_lisp_error("(filter + [nil])", :type_error, "invalid argument types")
    end

    test "parse-long rejects values outside Java long range" do
      assert_lisp(~S|(parse-long "9223372036854775808")|, nil)
      assert_lisp(~S|(parse-long "+9223372036854775808")|, nil)
      assert_lisp(~S|(parse-long "-9223372036854775809")|, nil)
    end

    test "int follows Java int coercion boundaries" do
      assert_lisp("(int ##NaN)", 0)
      assert_lisp(~S|(int \A)|, 65)
      assert_lisp_error("(int 2147483648)", :arithmetic_error, "integer overflow")
      assert_lisp_error("(int -2147483649)", :arithmetic_error, "integer overflow")
    end

    test "bounded take over zero-step range repeats the start value" do
      assert_lisp("(take 3 (range 1 5 0))", [1, 1, 1])
      assert_lisp("(take 2 (range 1 5 (identity 0)))", [1, 1])
    end

    test "bounded zero-step range shortcut preserves left-to-right argument evaluation" do
      assert_lisp(
        """
        (do
          (def my-range (fn [a b c] [:shadowed]))
          (take (do (def range my-range) 3)
                (range 1 5 0)))
        """,
        ["shadowed"]
      )
    end

    test "zero-step range does not leak an internal marker" do
      assert_lisp_error(
        "(range 1 5 0)",
        :type_error,
        "zero-step range must be consumed by bounded take"
      )

      assert_lisp_error(
        "(first (range 1 5 0))",
        :type_error,
        "zero-step range must be consumed by bounded take"
      )
    end

    test "range rejects nil and nonnumeric bounds" do
      assert_lisp_error("(range nil)", :type_error, "range expects numeric bounds")
      assert_lisp_error(~S|(range "1" 3)|, :type_error, "range expects numeric bounds")
    end
  end

  describe "pow - exponentiation" do
    test "square" do
      assert_lisp("(pow 2 3)", 8.0)
    end

    test "Math namespace shorthand" do
      assert_lisp("(Math/pow 3 2)", 9.0)
    end

    # GAP-J13: IEEE 754 special cases return recoverable signal values
    # (java.lang.Math.pow semantics) instead of raising.
    test "negative base with fractional exponent is NaN" do
      assert_lisp("(str (Math/pow -1 0.5))", "NaN")
    end

    test "zero base with negative exponent is positive infinity" do
      assert_lisp("(str (Math/pow 0 -1))", "Infinity")
    end

    test "negative zero base with negative odd exponent is negative infinity" do
      assert_lisp("(str (Math/pow -0.0 -3))", "-Infinity")
    end

    test "one to NaN/infinite exponent is NaN" do
      assert_lisp("(str (Math/pow 1 ##NaN))", "NaN")
      assert_lisp("(str (Math/pow 1 ##Inf))", "NaN")
      assert_lisp("(str (Math/pow -1 ##Inf))", "NaN")
    end

    test "zero exponent wins over any base" do
      assert_lisp("(Math/pow ##NaN 0)", 1.0)
      assert_lisp("(Math/pow ##Inf 0)", 1.0)
    end

    test "negative base with integer exponent stays real" do
      assert_lisp("(Math/pow -2 3)", -8.0)
      assert_lisp("(Math/pow -2 2)", 4.0)
    end

    test "infinite base and infinite exponent together" do
      assert_lisp("(str (Math/pow ##Inf ##Inf))", "Infinity")
      assert_lisp("(str (Math/pow ##-Inf ##Inf))", "Infinity")
      assert_lisp("(Math/pow ##Inf ##-Inf)", 0.0)
      assert_lisp("(Math/pow ##-Inf ##-Inf)", 0.0)
    end

    test "finite overflow becomes signed infinity (not an error)" do
      assert_lisp("(str (Math/pow 2 1024))", "Infinity")
      assert_lisp("(str (Math/pow -2 1025))", "-Infinity")
      assert_lisp("(str (Math/pow -2 1024))", "Infinity")
      # underflow still rounds to zero
      assert_lisp("(Math/pow 2 -2000)", 0.0)
    end

    test "negative-infinity base preserves odd-exponent sign" do
      assert_lisp("(str (Math/pow ##-Inf 3))", "-Infinity")
      assert_lisp("(str (Math/pow ##-Inf 3.0))", "-Infinity")
      assert_lisp("(str (Math/pow ##-Inf 2))", "Infinity")
      assert_lisp("(str (Math/pow ##-Inf 2.5))", "Infinity")
      assert_lisp("(str (Math/pow ##-Inf -3))", "-0.0")
      assert_lisp("(str (Math/pow ##-Inf -2))", "0.0")
    end

    test "exponent parity follows double coercion beyond 2^53" do
      # 9223372036854775807 (Long/MAX) rounds to an EVEN double, so the
      # odd-integer special case does not apply (matches java.lang.Math.pow).
      assert_lisp("(str (Math/pow -0.0 -9223372036854775807))", "Infinity")
      assert_lisp("(str (Math/pow -0.0 9223372036854775807))", "0.0")
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

    test "floating zero divisors keep Clojure primitive double results" do
      assert_lisp("(/ 1.0 0.0)", :infinity)
      assert_lisp("(/ 1 0.0)", :infinity)
      assert_lisp("(/ -1.0 0.0)", :negative_infinity)
      assert_lisp("(/ 0.0 0.0)", :nan)
    end

    test "mixed-mode with integer zero divisor raises" do
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
