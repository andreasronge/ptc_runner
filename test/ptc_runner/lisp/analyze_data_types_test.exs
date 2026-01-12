defmodule PtcRunner.Lisp.AnalyzeDataTypesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Analyze

  describe "literals pass through" do
    test "nil" do
      assert {:ok, nil} = Analyze.analyze(nil)
    end

    test "booleans" do
      assert {:ok, true} = Analyze.analyze(true)
      assert {:ok, false} = Analyze.analyze(false)
    end

    test "integers" do
      assert {:ok, 42} = Analyze.analyze(42)
      assert {:ok, -10} = Analyze.analyze(-10)
      assert {:ok, 0} = Analyze.analyze(0)
    end

    test "floats" do
      assert {:ok, 3.14} = Analyze.analyze(3.14)
      assert {:ok, -2.5} = Analyze.analyze(-2.5)
    end

    test "strings" do
      assert {:ok, {:string, "hello"}} = Analyze.analyze({:string, "hello"})
      assert {:ok, {:string, ""}} = Analyze.analyze({:string, ""})
    end

    test "keywords" do
      assert {:ok, {:keyword, :name}} = Analyze.analyze({:keyword, :name})
      assert {:ok, {:keyword, :status}} = Analyze.analyze({:keyword, :status})
    end
  end

  describe "vectors" do
    test "empty vector" do
      assert {:ok, {:vector, []}} = Analyze.analyze({:vector, []})
    end

    test "vector with literals" do
      assert {:ok, {:vector, [1, 2, 3]}} = Analyze.analyze({:vector, [1, 2, 3]})
    end

    test "vector with mixed types" do
      assert {:ok, {:vector, [1, {:string, "test"}, {:keyword, :foo}]}} =
               Analyze.analyze({:vector, [1, {:string, "test"}, {:keyword, :foo}]})
    end

    test "nested vectors" do
      assert {:ok, {:vector, [{:vector, [1, 2]}, {:vector, [3, 4]}]}} =
               Analyze.analyze({:vector, [{:vector, [1, 2]}, {:vector, [3, 4]}]})
    end
  end

  describe "maps" do
    test "empty map" do
      assert {:ok, {:map, []}} = Analyze.analyze({:map, []})
    end

    test "map with literal keys and values" do
      assert {:ok, {:map, [{{:keyword, :name}, {:string, "test"}}]}} =
               Analyze.analyze({:map, [{{:keyword, :name}, {:string, "test"}}]})
    end

    test "map with multiple pairs" do
      assert {:ok, {:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]}} =
               Analyze.analyze({:map, [{{:keyword, :a}, 1}, {{:keyword, :b}, 2}]})
    end

    test "nested maps" do
      inner = {:map, [{{:keyword, :x}, 1}]}

      assert {:ok, {:map, [{{:keyword, :outer}, ^inner}]}} =
               Analyze.analyze({:map, [{{:keyword, :outer}, inner}]})
    end
  end

  describe "sets" do
    test "empty set" do
      assert {:ok, {:set, []}} = Analyze.analyze({:set, []})
    end

    test "set with literals" do
      assert {:ok, {:set, [1, 2, 3]}} = Analyze.analyze({:set, [1, 2, 3]})
    end

    test "set with symbols analyzed to vars" do
      assert {:ok, {:set, [{:var, :x}, {:var, :y}]}} =
               Analyze.analyze({:set, [{:symbol, :x}, {:symbol, :y}]})
    end

    test "nested set" do
      assert {:ok, {:set, [{:set, [1, 2]}]}} =
               Analyze.analyze({:set, [{:set, [1, 2]}]})
    end

    test "set containing vector" do
      assert {:ok, {:set, [{:vector, [1, 2]}]}} =
               Analyze.analyze({:set, [{:vector, [1, 2]}]})
    end

    test "set with mixed types" do
      assert {:ok, {:set, [1, {:string, "test"}, {:keyword, :foo}]}} =
               Analyze.analyze({:set, [1, {:string, "test"}, {:keyword, :foo}]})
    end
  end

  describe "symbols become vars" do
    test "regular symbol becomes var" do
      assert {:ok, {:var, :filter}} = Analyze.analyze({:symbol, :filter})
    end

    test "multiple symbol examples" do
      assert {:ok, {:var, :x}} = Analyze.analyze({:symbol, :x})
      assert {:ok, {:var, :count}} = Analyze.analyze({:symbol, :count})
      assert {:ok, {:var, :is_valid?}} = Analyze.analyze({:symbol, :is_valid?})
    end

    test "data namespace symbol" do
      assert {:ok, {:data, :input}} = Analyze.analyze({:ns_symbol, :data, :input})
    end

    test "multiple data symbols" do
      assert {:ok, {:data, :data}} = Analyze.analyze({:ns_symbol, :data, :data})
      assert {:ok, {:data, :query}} = Analyze.analyze({:ns_symbol, :data, :query})
    end
  end
end
