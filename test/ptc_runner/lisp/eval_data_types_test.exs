defmodule PtcRunner.Lisp.EvalDataTypesTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.Eval

  describe "set evaluation" do
    test "empty set" do
      assert {:ok, result, %{}} = Eval.eval({:set, []}, %{}, %{}, %{}, &dummy_tool/2)
      assert MapSet.equal?(result, MapSet.new([]))
    end

    test "set with literals" do
      assert {:ok, result, %{}} =
               Eval.eval({:set, [1, 2, 3]}, %{}, %{}, %{}, &dummy_tool/2)

      assert MapSet.equal?(result, MapSet.new([1, 2, 3]))
    end

    test "set deduplicates elements" do
      assert {:ok, result, %{}} =
               Eval.eval({:set, [1, 1, 2, 2, 3]}, %{}, %{}, %{}, &dummy_tool/2)

      assert MapSet.equal?(result, MapSet.new([1, 2, 3]))
      assert MapSet.size(result) == 3
    end

    test "set with mixed types" do
      assert {:ok, result, %{}} =
               Eval.eval(
                 {:set, [1, {:string, "test"}, {:keyword, :foo}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )

      assert MapSet.equal?(result, MapSet.new([1, "test", :foo]))
    end

    test "nested sets" do
      inner = {:set, [1, 2]}

      assert {:ok, result, %{}} =
               Eval.eval({:set, [inner, {:set, [3, 4]}]}, %{}, %{}, %{}, &dummy_tool/2)

      # Extract the inner MapSets to compare
      inner_sets = MapSet.to_list(result)
      assert length(inner_sets) == 2
      assert Enum.any?(inner_sets, &MapSet.equal?(&1, MapSet.new([1, 2])))
      assert Enum.any?(inner_sets, &MapSet.equal?(&1, MapSet.new([3, 4])))
    end

    test "set with error in element propagates error" do
      assert {:error, {:unbound_var, :x}} =
               Eval.eval({:set, [1, {:var, :x}]}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "set with nil element" do
      assert {:ok, result, %{}} =
               Eval.eval({:set, [nil, 1, 2]}, %{}, %{}, %{}, &dummy_tool/2)

      assert MapSet.equal?(result, MapSet.new([nil, 1, 2]))
    end

    test "set preserves memory across evaluation" do
      memory = %{count: 5}

      assert {:ok, result, ^memory} =
               Eval.eval({:set, [1, 2, 3]}, %{}, memory, %{}, &dummy_tool/2)

      assert MapSet.equal?(result, MapSet.new([1, 2, 3]))
    end
  end
end
