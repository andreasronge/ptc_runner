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

  describe "pow - exponentiation" do
    test "square" do
      assert_lisp("(pow 2 3)", 8.0)
    end

    test "Math namespace shorthand" do
      assert_lisp("(Math/pow 3 2)", 9.0)
    end
  end

  defp assert_lisp(source, expected) do
    {:ok, %{return: result}} = PtcRunner.Lisp.run(source)
    assert result == expected
  end
end
