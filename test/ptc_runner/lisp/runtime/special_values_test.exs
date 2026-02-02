defmodule PtcRunner.Lisp.Runtime.SpecialValuesTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp.Runtime.Math
  alias PtcRunner.Lisp.Runtime.Predicates
  alias PtcRunner.Lisp.Runtime.String, as: LispString

  describe "arithmetic with special values" do
    test "addition" do
      assert Math.add([:infinity, 1]) == :infinity
      assert Math.add([:negative_infinity, 1]) == :negative_infinity
      assert Math.add([:infinity, :negative_infinity]) == :nan
      assert Math.add([:nan, 1]) == :nan
    end

    test "subtraction" do
      assert Math.subtract([:infinity]) == :negative_infinity
      assert Math.subtract([:negative_infinity]) == :infinity
      assert Math.subtract([:infinity, 1]) == :infinity
      assert Math.subtract([1, :infinity]) == :negative_infinity
      assert Math.subtract([:infinity, :infinity]) == :nan
    end

    test "multiplication" do
      assert Math.multiply([:infinity, 2]) == :infinity
      assert Math.multiply([:infinity, -2]) == :negative_infinity
      assert Math.multiply([:infinity, 0]) == :nan
      assert Math.multiply([:nan, 2]) == :nan
    end

    test "division" do
      assert Math.divide(1, 0) == :infinity
      assert Math.divide(-1, 0) == :negative_infinity
      assert Math.divide(0, 0) == :nan
      assert Math.divide(:infinity, 2) == :infinity
      assert Math.divide(2, :infinity) == 0.0
      assert Math.divide(:infinity, :infinity) == :nan
    end
  end

  describe "predicates with special values" do
    test "number?" do
      assert Predicates.number?(:infinity)
      assert Predicates.number?(:negative_infinity)
      assert Predicates.number?(:nan)
      assert Predicates.number?(42)
    end

    test "pos? / neg? / zero?" do
      assert Predicates.pos?(:infinity)
      refute Predicates.pos?(:negative_infinity)
      refute Predicates.pos?(:nan)

      assert Predicates.neg?(:negative_infinity)
      refute Predicates.neg?(:infinity)
      refute Predicates.neg?(:nan)

      refute Predicates.zero?(:nan)
    end
  end

  describe "string conversion and parsing" do
    test "parse_double" do
      assert LispString.parse_double("Infinity") == :infinity
      assert LispString.parse_double("+Infinity") == :infinity
      assert LispString.parse_double("-Infinity") == :negative_infinity
      assert LispString.parse_double("NaN") == :nan
      assert LispString.parse_double("1.5") == 1.5
    end

    test "str (to_str)" do
      assert LispString.to_str(:infinity) == "Infinity"
      assert LispString.to_str(:negative_infinity) == "-Infinity"
      assert LispString.to_str(:nan) == "NaN"
    end
  end

  describe "comparisons" do
    test "equality" do
      refute Math.eq(:nan, :nan)
      assert Math.eq(:infinity, :infinity)
      assert Math.eq(:negative_infinity, :negative_infinity)
      refute Math.eq(:infinity, :negative_infinity)
    end

    test "comparison" do
      assert Math.compare(:infinity, 1000) == 1
      assert Math.compare(:negative_infinity, -1000) == -1
      assert Math.compare(:infinity, :negative_infinity) == 1

      assert_raise RuntimeError, ~r/unordered comparison with NaN/, fn ->
        Math.compare(:nan, 1)
      end
    end

    test "IEEE 754 comparisons (lt, gt, lte, gte)" do
      # NaN comparisons are always false
      refute Math.lt(:nan, 0)
      refute Math.gt(:nan, 0)
      refute Math.lte(:nan, 0)
      refute Math.gte(:nan, 0)
      refute Math.lt(:nan, :nan)

      # Infinity comparisons
      assert Math.gt(1000, :negative_infinity)
      assert Math.lt(:negative_infinity, -1000)
      assert Math.gt(:infinity, 1000)
      assert Math.lt(1000, :infinity)

      assert Math.lte(1000, :infinity)
      assert Math.gte(:infinity, 1000)
    end
  end

  describe "improved pow with negative infinity" do
    test "pow parity for negative infinity" do
      assert Math.pow(:negative_infinity, 3) == :negative_infinity
      assert Math.pow(:negative_infinity, 2) == :infinity
      assert Math.pow(:negative_infinity, -1) == 0.0
    end
  end
end
