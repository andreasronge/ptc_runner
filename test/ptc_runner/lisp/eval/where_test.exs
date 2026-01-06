defmodule PtcRunner.Lisp.Eval.WhereTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Eval.Where

  doctest PtcRunner.Lisp.Eval.Where

  describe "MapSet support" do
    test ":in operator with MapSet" do
      set = MapSet.new(["a", "b", "c"])
      pred = Where.build_where_predicate(:in, fn row -> row.val end, set)

      assert pred.(%{val: "a"}) == true
      assert pred.(%{val: "d"}) == false
    end

    test ":in operator with MapSet normalizes keywords to strings" do
      set = MapSet.new(["a", "b", "c"])
      pred = Where.build_where_predicate(:in, fn row -> row.val end, set)

      assert pred.(%{val: :a}) == true
    end

    test ":includes operator with MapSet" do
      pred = Where.build_where_predicate(:includes, fn row -> row.val end, "a")

      assert pred.(%{val: MapSet.new(["a", "b", "c"])}) == true
      assert pred.(%{val: MapSet.new(["b"])}) == false
    end

    test ":includes operator with MapSet normalizes keywords to strings" do
      set = MapSet.new(["a", "b", "c"])
      pred = Where.build_where_predicate(:includes, fn row -> row.val end, :a)

      assert pred.(%{val: set}) == true
    end
  end
end
