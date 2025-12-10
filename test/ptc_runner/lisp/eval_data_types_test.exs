defmodule PtcRunner.Lisp.EvalDataTypesTest do
  use ExUnit.Case, async: true

  import PtcRunner.TestSupport.TestHelpers

  alias PtcRunner.Lisp.Eval

  describe "literal evaluation" do
    test "nil" do
      assert {:ok, nil, %{}} = Eval.eval(nil, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "booleans" do
      assert {:ok, true, %{}} = Eval.eval(true, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, false, %{}} = Eval.eval(false, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "integers" do
      assert {:ok, 42, %{}} = Eval.eval(42, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, -10, %{}} = Eval.eval(-10, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "floats" do
      assert {:ok, 3.14, %{}} = Eval.eval(3.14, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, -2.5, %{}} = Eval.eval(-2.5, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "strings" do
      assert {:ok, "hello", %{}} = Eval.eval({:string, "hello"}, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, "", %{}} = Eval.eval({:string, ""}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "keywords" do
      assert {:ok, :name, %{}} = Eval.eval({:keyword, :name}, %{}, %{}, %{}, &dummy_tool/2)
      assert {:ok, :status, %{}} = Eval.eval({:keyword, :status}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "vector evaluation" do
    test "empty vector" do
      assert {:ok, [], %{}} = Eval.eval({:vector, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "vector with literals" do
      assert {:ok, [1, 2, 3], %{}} = Eval.eval({:vector, [1, 2, 3]}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "vector with mixed types" do
      assert {:ok, [1, "test", :foo], %{}} =
               Eval.eval(
                 {:vector, [1, {:string, "test"}, {:keyword, :foo}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )
    end

    test "nested vectors" do
      inner = {:vector, [1, 2]}

      assert {:ok, [[1, 2], [3, 4]], %{}} =
               Eval.eval({:vector, [inner, {:vector, [3, 4]}]}, %{}, %{}, %{}, &dummy_tool/2)
    end
  end

  describe "map evaluation" do
    test "empty map" do
      assert {:ok, %{}, %{}} = Eval.eval({:map, []}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "map with literal keys and values" do
      assert {:ok, %{name: "test"}, %{}} =
               Eval.eval(
                 {:map, [{{:keyword, :name}, {:string, "test"}}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )
    end

    test "map with multiple pairs" do
      assert {:ok, %{a: 1, b: 2}, %{}} =
               Eval.eval(
                 {:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )
    end

    test "nested maps" do
      inner = {:map, [{{:keyword, :x}, 1}]}

      assert {:ok, %{outer: %{x: 1}}, %{}} =
               Eval.eval({:map, [{{:keyword, :outer}, inner}]}, %{}, %{}, %{}, &dummy_tool/2)
    end

    test "map with string keys" do
      assert {:ok, %{"key" => "value"}, %{}} =
               Eval.eval(
                 {:map, [{{:string, "key"}, {:string, "value"}}]},
                 %{},
                 %{},
                 %{},
                 &dummy_tool/2
               )
    end
  end

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
