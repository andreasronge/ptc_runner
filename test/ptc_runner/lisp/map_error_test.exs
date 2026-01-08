defmodule PtcRunner.Lisp.MapErrorTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  describe "map with keyword and single map" do
    test "provides clear error message" do
      {:error, %Step{fail: fail}} = Lisp.run("(map :key {:key 1})")

      assert fail.message ==
               "type_error: map: keyword accessor requires a list of maps, got a single map"
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
    test "provides clear error message" do
      {:error, %Step{fail: fail}} = Lisp.run("(mapv :key {:key 1})")

      assert fail.message ==
               "type_error: mapv: keyword accessor requires a list of maps, got a single map"
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
