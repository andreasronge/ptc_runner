defmodule PtcRunner.Lisp.MapErrorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  describe "map with keyword and single map" do
    test "keyword on map applies to [k,v] entry pairs" do
      {:ok, %Step{return: result}} = Lisp.run("(map :key {:key 1})")
      # keyword access on [k,v] vector returns nil (Clojure-consistent)
      assert result == [nil]
    end

    test "still works with list of maps" do
      {:ok, %Step{return: result}} = Lisp.run("(map :key [{:key 1} {:key 2}])")
      assert result == [1, 2]
    end

    test "still works with function and single map" do
      {:ok, %Step{return: result}} = Lisp.run("(map (fn [x] (first x)) {:a 1 :b 2})")
      assert Enum.sort(result) == [:a, :b]
    end
  end

  describe "mapv with keyword and single map" do
    test "keyword on map applies to [k,v] entry pairs" do
      {:ok, %Step{return: result}} = Lisp.run("(mapv :key {:key 1})")
      # keyword access on [k,v] vector returns nil (Clojure-consistent)
      assert result == [nil]
    end

    test "still works with list of maps" do
      {:ok, %Step{return: result}} = Lisp.run("(mapv :key [{:key 1} {:key 2}])")
      assert result == [1, 2]
    end

    test "still works with function and single map" do
      {:ok, %Step{return: result}} = Lisp.run("(mapv (fn [x] (first x)) {:a 1 :b 2})")
      assert Enum.sort(result) == [:a, :b]
    end
  end
end
