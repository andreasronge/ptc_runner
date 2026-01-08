defmodule PtcRunner.Lisp.RestPatternTest do
  @moduledoc """
  Tests for rest pattern destructuring: [a b & rest]

  Allows binding leading elements individually and collecting
  remaining elements into a rest variable.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Analyze

  describe "analyzer: rest patterns" do
    test "[x & rest] produces seq_rest pattern" do
      raw = {:vector, [{:symbol, :x}, {:symbol, :&}, {:symbol, :rest}]}

      assert {:ok, {:destructure, {:seq_rest, [{:var, :x}], {:var, :rest}}}} =
               Analyze.Patterns.analyze_pattern(raw)
    end

    test "[a b & rest] with multiple leading patterns" do
      raw =
        {:vector, [{:symbol, :a}, {:symbol, :b}, {:symbol, :&}, {:symbol, :rest}]}

      assert {:ok, {:destructure, {:seq_rest, [{:var, :a}, {:var, :b}], {:var, :rest}}}} =
               Analyze.Patterns.analyze_pattern(raw)
    end

    test "[& rest] with no leading patterns" do
      raw = {:vector, [{:symbol, :&}, {:symbol, :all}]}

      assert {:ok, {:destructure, {:seq_rest, [], {:var, :all}}}} =
               Analyze.Patterns.analyze_pattern(raw)
    end

    test "& without following pattern is an error" do
      raw = {:vector, [{:symbol, :x}, {:symbol, :&}]}

      assert {:error, {:invalid_form, "& must be followed by a pattern"}} =
               Analyze.Patterns.analyze_pattern(raw)
    end

    test "& with extra patterns after rest is an error" do
      raw =
        {:vector, [{:symbol, :a}, {:symbol, :&}, {:symbol, :rest}, {:symbol, :extra}]}

      assert {:error, {:invalid_form, "& must be followed by exactly one pattern" <> _}} =
               Analyze.Patterns.analyze_pattern(raw)
    end
  end

  describe "let with rest patterns" do
    test "[x & rest] binds first and remaining" do
      code = "(let [[x & rest] [1 2 3 4]] [x rest])"
      assert {:ok, %{return: [1, [2, 3, 4]]}} = Lisp.run(code)
    end

    test "[a b & rest] binds multiple leading elements" do
      code = "(let [[a b & rest] [1 2 3 4 5]] [a b rest])"
      assert {:ok, %{return: [1, 2, [3, 4, 5]]}} = Lisp.run(code)
    end

    test "[& all] binds entire list to rest" do
      code = "(let [[& all] [1 2 3]] all)"
      assert {:ok, %{return: [1, 2, 3]}} = Lisp.run(code)
    end

    test "rest is empty list when no remaining elements" do
      code = "(let [[a b & rest] [1 2]] [a b rest])"
      assert {:ok, %{return: [1, 2, []]}} = Lisp.run(code)
    end

    test "leading patterns get nil when list is too short" do
      code = "(let [[a b & rest] [1]] [a b rest])"
      assert {:ok, %{return: [1, nil, []]}} = Lisp.run(code)
    end

    test "rest pattern works with empty list" do
      code = "(let [[& all] []] all)"
      assert {:ok, %{return: []}} = Lisp.run(code)
    end

    test "nested destructuring in rest pattern" do
      code = "(let [[[a b] & rest] [[1 2] [3 4] [5 6]]] [a b rest])"
      assert {:ok, %{return: [1, 2, [[3, 4], [5, 6]]]}} = Lisp.run(code)
    end

    test "rest pattern with nested destructure in rest position" do
      # [a b] in rest position only takes what it needs (2 elements)
      # Extra elements in the rest are dropped - matches Clojure behavior
      code = "(let [[x & [a b]] [1 2 3 4]] [x a b])"
      assert {:ok, %{return: [1, 2, 3]}} = Lisp.run(code)
    end
  end

  describe "loop with rest patterns" do
    test "process list elements with [head & tail] pattern" do
      code = """
      (loop [[head & tail] [1 2 3 4]
             acc 0]
        (if head
          (recur tail (+ acc head))
          acc))
      """

      assert {:ok, %{return: 10}} = Lisp.run(code)
    end

    test "reverse a list using rest pattern" do
      code = """
      (loop [[x & rest] [1 2 3]
             result []]
        (if x
          (recur rest (into [x] result))
          result))
      """

      assert {:ok, %{return: [3, 2, 1]}} = Lisp.run(code)
    end

    test "take first n elements using rest pattern" do
      code = """
      (loop [[x & rest] [1 2 3 4 5]
             n 3
             result []]
        (if (and x (> n 0))
          (recur rest (- n 1) (conj result x))
          result))
      """

      assert {:ok, %{return: [1, 2, 3]}} = Lisp.run(code)
    end

    test "recur passes updated list to rest pattern" do
      code = """
      (loop [[a b & rest] [1 2 3 4 5 6]
             sum 0]
        (if a
          (recur rest (+ sum a (or b 0)))
          sum))
      """

      # First iteration: a=1, b=2, rest=[3,4,5,6], sum=0+1+2=3
      # Second iteration: a=3, b=4, rest=[5,6], sum=3+3+4=10
      # Third iteration: a=5, b=6, rest=[], sum=10+5+6=21
      # Fourth iteration: a=nil, return sum=21
      assert {:ok, %{return: 21}} = Lisp.run(code)
    end
  end
end
