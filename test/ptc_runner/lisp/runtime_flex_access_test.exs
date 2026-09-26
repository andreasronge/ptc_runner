defmodule PtcRunner.Lisp.RuntimeFlexAccessTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Runtime
  alias PtcRunner.Lisp.Runtime.FlexAccess

  test "source-level flexible key lookup covers every collection operation" do
    rows = [
      {:string_fallback, [%{"value" => 30}, %{"value" => 10}, %{"value" => 20}], ":value"},
      {:atom_precedence,
       [%{"value" => 999, value: 30}, %{"value" => 999, value: 10}, %{"value" => 999, value: 20}],
       ":value"},
      {:mixed_maps, [%{value: 30}, %{"value" => 10}, %{"value" => 999, value: 20}], ":value"}
    ]

    for {case_name, items, key} <- rows do
      context = [context: %{items: items}]

      assert {:ok, %{return: [10, 20, 30]}} =
               Lisp.run_native(
                 "(map (fn [item] (get item #{key})) (sort-by #{key} data/items))",
                 context
               ),
             inspect(case_name)

      assert {:ok, %{return: 60}} = Lisp.run_native("(sum-by #{key} data/items)", context)
      assert {:ok, %{return: 20.0}} = Lisp.run_native("(avg-by #{key} data/items)", context)

      assert {:ok, %{return: 10}} =
               Lisp.run_native("(get (min-by #{key} data/items) #{key})", context)

      assert {:ok, %{return: 30}} =
               Lisp.run_native("(get (max-by #{key} data/items) #{key})", context)

      assert {:ok, %{return: 1}} =
               Lisp.run_native("(count (get (group-by #{key} data/items) 10))", context)

      assert {:ok, %{return: 30}} = Lisp.run_native("(get (first data/items) #{key})", context)

      assert {:ok, %{return: true}} =
               Lisp.run_native("(contains? (first data/items) #{key})", context)
    end
  end

  test "source-level lookup filters nil values and handles empty collections" do
    items = [%{value: 10}, %{value: nil}, %{value: 20}]
    context = [context: %{items: items}]

    for {source, expected} <- [
          {"(sum-by :value data/items)", 30},
          {"(avg-by :value data/items)", 15.0},
          {"(get (min-by :value data/items) :value)", 10},
          {"(get (max-by :value data/items) :value)", 20},
          {"(count (get (group-by :value data/items) nil))", 1},
          {"(get (first data/items) :value)", 10},
          {"(contains? (first data/items) :value)", true}
        ] do
      assert {:ok, %{return: ^expected}} = Lisp.run_native(source, context), source
    end

    for {source, expected} <- [
          {"(sort-by :value [])", []},
          {"(sum-by :value [])", 0},
          {"(avg-by :value [])", nil},
          {"(min-by :value [])", nil},
          {"(max-by :value [])", nil},
          {"(group-by :value [])", %{}},
          {"(get {} :value 0)", 0},
          {"(contains? {} :value)", false}
        ] do
      assert {:ok, %{return: ^expected}} = Lisp.run_native(source), source
    end
  end

  describe "sort_by - function key support" do
    test "sort_by with function key on vectors" do
      pairs = [["b", 2], ["a", 1], ["c", 3]]
      result = Runtime.sort_by(&List.first/1, pairs)
      assert result == [["a", 1], ["b", 2], ["c", 3]]
    end

    test "sort_by with function key and comparator" do
      pairs = [["a", 1], ["b", 3], ["c", 2]]
      result = Runtime.sort_by(&Enum.at(&1, 1), &>=/2, pairs)
      assert result == [["b", 3], ["c", 2], ["a", 1]]
    end

    test "sort_by with anonymous function" do
      data = [
        %{price: 100},
        %{price: 50},
        %{price: 75}
      ]

      result = Runtime.sort_by(fn item -> item.price end, data)
      assert Enum.map(result, & &1.price) == [50, 75, 100]
    end
  end

  describe "sum_by - function key support" do
    test "sum_by with function key on vectors" do
      pairs = [["a", 10], ["b", 20], ["c", 30]]
      result = Runtime.sum_by(&Enum.at(&1, 1), pairs)
      assert result == 60
    end

    test "sum_by with anonymous function" do
      data = [
        %{price: 100},
        %{price: 50},
        %{price: 75}
      ]

      result = Runtime.sum_by(fn item -> item.price end, data)
      assert result == 225
    end

    test "sum_by with function key ignores nil values" do
      pairs = [["a", 10], ["b", nil], ["c", 30]]
      result = Runtime.sum_by(&Enum.at(&1, 1), pairs)
      assert result == 40
    end
  end

  describe "avg_by - function key support" do
    test "avg_by with function key on vectors" do
      pairs = [["a", 10], ["b", 20], ["c", 30]]
      result = Runtime.avg_by(&Enum.at(&1, 1), pairs)
      assert result == 20.0
    end

    test "avg_by with anonymous function" do
      data = [
        %{price: 100},
        %{price: 50},
        %{price: 75}
      ]

      result = Runtime.avg_by(fn item -> item.price end, data)
      assert result == 75.0
    end

    test "avg_by with function key ignores nil values" do
      pairs = [["a", 10], ["b", nil], ["c", 30]]
      result = Runtime.avg_by(&Enum.at(&1, 1), pairs)
      assert result == 20.0
    end
  end

  describe "min_by - function key support" do
    test "min_by with function key on vectors" do
      pairs = [["a", 10], ["b", 5], ["c", 30]]
      result = Runtime.min_by(&Enum.at(&1, 1), pairs)
      assert result == ["b", 5]
    end

    test "min_by with anonymous function" do
      data = [
        %{price: 100},
        %{price: 50},
        %{price: 75}
      ]

      result = Runtime.min_by(fn item -> item.price end, data)
      assert result.price == 50
    end

    test "min_by with function key returns nil for empty collection" do
      result = Runtime.min_by(&Enum.at(&1, 1), [])
      assert result == nil
    end
  end

  describe "max_by - function key support" do
    test "max_by with function key on vectors" do
      pairs = [["a", 10], ["b", 5], ["c", 30]]
      result = Runtime.max_by(&Enum.at(&1, 1), pairs)
      assert result == ["c", 30]
    end

    test "max_by with anonymous function" do
      data = [
        %{price: 100},
        %{price: 50},
        %{price: 75}
      ]

      result = Runtime.max_by(fn item -> item.price end, data)
      assert result.price == 100
    end

    test "max_by with function key returns nil for empty collection" do
      result = Runtime.max_by(&Enum.at(&1, 1), [])
      assert result == nil
    end
  end

  describe "group_by - function key support" do
    test "group_by with function key on vectors" do
      pairs = [[1, "a"], [2, "a"], [1, "b"]]
      result = Runtime.group_by(&List.first/1, pairs)
      assert result == %{1 => [[1, "a"], [1, "b"]], 2 => [[2, "a"]]}
    end

    test "group_by with anonymous function" do
      data = [
        %{category: "books", title: "Book 1"},
        %{category: "electronics", title: "Phone"},
        %{category: "books", title: "Book 2"}
      ]

      result = Runtime.group_by(fn item -> item.category end, data)
      assert length(result["books"]) == 2
      assert length(result["electronics"]) == 1
    end

    test "group_by with function key on complex data" do
      pairs = [["a", 1], ["b", 1], ["c", 2]]
      result = Runtime.group_by(&Enum.at(&1, 1), pairs)
      assert result == %{1 => [["a", 1], ["b", 1]], 2 => [["c", 2]]}
    end
  end

  describe "flex_fetch - flexible key fetching" do
    test "flex_fetch with atom key finds value in atom-keyed map" do
      map = %{name: "Alice"}
      assert FlexAccess.flex_fetch(map, :name) == {:ok, "Alice"}
    end

    test "flex_fetch with atom key finds value in string-keyed map" do
      map = %{"name" => "Alice"}
      assert FlexAccess.flex_fetch(map, :name) == {:ok, "Alice"}
    end

    test "flex_fetch with string key finds value in string-keyed map" do
      map = %{"name" => "Alice"}
      assert FlexAccess.flex_fetch(map, "name") == {:ok, "Alice"}
    end

    test "flex_fetch with string key finds value in atom-keyed map" do
      map = %{name: "Alice"}
      assert FlexAccess.flex_fetch(map, "name") == {:ok, "Alice"}
    end

    test "flex_fetch with atom key returns :error for missing key" do
      map = %{name: "Alice"}
      assert FlexAccess.flex_fetch(map, :age) == :error
    end

    test "flex_fetch with string key returns :error for missing key" do
      map = %{"name" => "Alice"}
      assert FlexAccess.flex_fetch(map, "age") == :error
    end

    test "flex_fetch preserves nil values" do
      map = %{status: nil}
      assert FlexAccess.flex_fetch(map, :status) == {:ok, nil}
    end

    test "flex_fetch preserves nil values in string-keyed map" do
      map = %{"status" => nil}
      assert FlexAccess.flex_fetch(map, "status") == {:ok, nil}
    end

    test "flex_fetch with MapSet returns :error" do
      set = MapSet.new([1, 2, 3])
      assert FlexAccess.flex_fetch(set, :key) == :error
    end

    test "flex_fetch with nil returns :error" do
      assert FlexAccess.flex_fetch(nil, :key) == :error
      assert FlexAccess.flex_fetch(nil, "key") == :error
    end

    test "flex_fetch prefers atom key when both exist" do
      map = %{"name" => "Bob", name: "Alice"}
      assert FlexAccess.flex_fetch(map, :name) == {:ok, "Alice"}
    end

    test "flex_fetch with non-atom/string key uses Map.fetch directly" do
      map = %{1 => "value"}
      assert FlexAccess.flex_fetch(map, 1) == {:ok, "value"}
    end
  end
end
