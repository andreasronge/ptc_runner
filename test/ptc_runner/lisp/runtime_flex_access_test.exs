defmodule PtcRunner.Lisp.RuntimeFlexAccessTest do
  use ExUnit.Case

  alias PtcRunner.Lisp.Runtime

  describe "pluck - flexible key access" do
    test "string key fallback: pluck with string keys in data" do
      data = [
        %{"name" => "Alice", "age" => 30},
        %{"name" => "Bob", "age" => 25}
      ]

      result = Runtime.pluck(:name, data)
      assert result == ["Alice", "Bob"]
    end

    test "atom key precedence: pluck prefers atom keys when both exist" do
      data = [
        %{"name" => "ignored", name: "Alice"},
        %{"name" => "ignored", name: "Bob"}
      ]

      result = Runtime.pluck(:name, data)
      assert result == ["Alice", "Bob"]
    end

    test "atom key precedence: pluck with falsy atom value wins" do
      data = [
        %{"active" => true, active: false},
        %{"active" => true, active: nil}
      ]

      result = Runtime.pluck(:active, data)
      assert result == [false, nil]
    end

    test "mixed collections: pluck with both atom and string keys" do
      data = [
        %{status: "active"},
        %{"status" => "inactive"},
        %{"status" => "ignored", status: "pending"}
      ]

      result = Runtime.pluck(:status, data)
      assert result == ["active", "inactive", "pending"]
    end
  end

  describe "sort_by - flexible key access" do
    test "string key fallback: sort_by with string keys in data" do
      data = [
        %{"age" => 25},
        %{"age" => 30},
        %{"age" => 20}
      ]

      result = Runtime.sort_by(:age, data)
      assert Enum.map(result, &Map.get(&1, "age")) == [20, 25, 30]
    end

    test "atom key precedence: sort_by prefers atom keys when both exist" do
      data = [
        %{"priority" => 3, priority: 1},
        %{"priority" => 1, priority: 3},
        %{"priority" => 2, priority: 2}
      ]

      result = Runtime.sort_by(:priority, data)
      assert Enum.map(result, &Map.get(&1, :priority)) == [1, 2, 3]
    end

    test "mixed collections: sort_by with both atom and string keys" do
      data = [
        %{score: 85},
        %{"score" => 90},
        %{"score" => 99, score: 75}
      ]

      result = Runtime.sort_by(:score, data)

      scores =
        Enum.map(result, fn item ->
          Map.get(item, :score) || Map.get(item, "score")
        end)

      assert scores == [75, 85, 90]
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

  describe "sum_by - flexible key access" do
    test "string key fallback: sum_by with string keys in data" do
      data = [
        %{"amount" => 10},
        %{"amount" => 20},
        %{"amount" => 30}
      ]

      result = Runtime.sum_by(:amount, data)
      assert result == 60
    end

    test "atom key precedence: sum_by prefers atom keys when both exist" do
      data = [
        %{"value" => 100, value: 10},
        %{"value" => 100, value: 20},
        %{"value" => 100, value: 30}
      ]

      result = Runtime.sum_by(:value, data)
      assert result == 60
    end

    test "mixed collections: sum_by with both atom and string keys" do
      data = [
        %{price: 10},
        %{"price" => 20},
        %{"price" => 999, price: 15}
      ]

      result = Runtime.sum_by(:price, data)
      assert result == 45
    end

    test "nil values filtered: sum_by ignores nil values" do
      data = [
        %{amount: 10},
        %{amount: nil},
        %{amount: 20}
      ]

      result = Runtime.sum_by(:amount, data)
      assert result == 30
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

  describe "avg_by - flexible key access" do
    test "string key fallback: avg_by with string keys in data" do
      data = [
        %{"score" => 10},
        %{"score" => 20},
        %{"score" => 30}
      ]

      result = Runtime.avg_by(:score, data)
      assert result == 20.0
    end

    test "atom key precedence: avg_by prefers atom keys when both exist" do
      data = [
        %{"value" => 100, value: 10},
        %{"value" => 100, value: 20},
        %{"value" => 100, value: 30}
      ]

      result = Runtime.avg_by(:value, data)
      assert result == 20.0
    end

    test "mixed collections: avg_by with both atom and string keys" do
      data = [
        %{score: 10},
        %{"score" => 30},
        %{"score" => 999, score: 20}
      ]

      result = Runtime.avg_by(:score, data)
      assert result == 20.0
    end

    test "nil values filtered: avg_by ignores nil values" do
      data = [
        %{score: 10},
        %{score: nil},
        %{score: 20}
      ]

      result = Runtime.avg_by(:score, data)
      assert result == 15.0
    end

    test "empty collection: avg_by returns nil" do
      result = Runtime.avg_by(:score, [])
      assert result == nil
    end

    test "all nil values: avg_by returns nil" do
      data = [
        %{score: nil},
        %{score: nil}
      ]

      result = Runtime.avg_by(:score, data)
      assert result == nil
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

  describe "min_by - flexible key access" do
    test "string key fallback: min_by with string keys in data" do
      data = [
        %{"score" => 30},
        %{"score" => 10},
        %{"score" => 20}
      ]

      result = Runtime.min_by(:score, data)
      assert result == %{"score" => 10}
    end

    test "atom key precedence: min_by prefers atom keys when both exist" do
      data = [
        %{"value" => 100, value: 30},
        %{"value" => 100, value: 10},
        %{"value" => 100, value: 20}
      ]

      result = Runtime.min_by(:value, data)
      assert result == %{"value" => 100, value: 10}
    end

    test "mixed collections: min_by with both atom and string keys" do
      data = [
        %{score: 30},
        %{"score" => 10},
        %{"score" => 999, score: 20}
      ]

      result = Runtime.min_by(:score, data)
      assert result == %{"score" => 10}
    end

    test "nil values filtered: min_by ignores nil values" do
      data = [
        %{score: nil},
        %{score: 10},
        %{score: 20}
      ]

      result = Runtime.min_by(:score, data)
      assert result == %{score: 10}
    end

    test "empty collection: min_by returns nil" do
      result = Runtime.min_by(:score, [])
      assert result == nil
    end

    test "all nil values: min_by returns nil" do
      data = [
        %{score: nil},
        %{score: nil}
      ]

      result = Runtime.min_by(:score, data)
      assert result == nil
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

  describe "max_by - flexible key access" do
    test "string key fallback: max_by with string keys in data" do
      data = [
        %{"score" => 30},
        %{"score" => 10},
        %{"score" => 20}
      ]

      result = Runtime.max_by(:score, data)
      assert result == %{"score" => 30}
    end

    test "atom key precedence: max_by prefers atom keys when both exist" do
      data = [
        %{"value" => 100, value: 30},
        %{"value" => 100, value: 10},
        %{"value" => 100, value: 20}
      ]

      result = Runtime.max_by(:value, data)
      assert result == %{"value" => 100, value: 30}
    end

    test "mixed collections: max_by with both atom and string keys" do
      data = [
        %{score: 30},
        %{"score" => 10},
        %{"score" => 999, score: 20}
      ]

      result = Runtime.max_by(:score, data)
      # The item with the highest atom value (30) is returned
      assert result == %{score: 30}
    end

    test "nil values filtered: max_by ignores nil values" do
      data = [
        %{score: nil},
        %{score: 10},
        %{score: 20}
      ]

      result = Runtime.max_by(:score, data)
      assert result == %{score: 20}
    end

    test "empty collection: max_by returns nil" do
      result = Runtime.max_by(:score, [])
      assert result == nil
    end

    test "all nil values: max_by returns nil" do
      data = [
        %{score: nil},
        %{score: nil}
      ]

      result = Runtime.max_by(:score, data)
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

  describe "group_by - flexible key access" do
    test "string key fallback: group_by with string keys in data" do
      data = [
        %{"category" => "books"},
        %{"category" => "electronics"},
        %{"category" => "books"}
      ]

      result = Runtime.group_by(:category, data)
      assert Map.keys(result) == ["books", "electronics"]
      assert length(result["books"]) == 2
      assert length(result["electronics"]) == 1
    end

    test "atom key precedence: group_by prefers atom keys when both exist" do
      data = [
        %{"type" => "ignored", type: "books"},
        %{"type" => "ignored", type: "electronics"},
        %{"type" => "ignored", type: "books"}
      ]

      result = Runtime.group_by(:type, data)
      # When both atom and string keys exist, atom value is used for grouping
      assert Map.keys(result) == ["books", "electronics"]
      assert length(result["books"]) == 2
      assert length(result["electronics"]) == 1
    end

    test "mixed collections: group_by with both atom and string keys" do
      data = [
        %{status: "active"},
        %{"status" => "inactive"},
        %{"status" => "ignored", status: "active"}
      ]

      result = Runtime.group_by(:status, data)
      assert Map.keys(result) == ["active", "inactive"]
      assert length(result["active"]) == 2
      assert length(result["inactive"]) == 1
    end

    test "nil key values: group_by handles nil keys" do
      data = [
        %{category: "books"},
        %{category: nil},
        %{category: "books"}
      ]

      result = Runtime.group_by(:category, data)
      assert length(result["books"]) == 2
      assert length(result[nil]) == 1
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
      assert Runtime.flex_fetch(map, :name) == {:ok, "Alice"}
    end

    test "flex_fetch with atom key finds value in string-keyed map" do
      map = %{"name" => "Alice"}
      assert Runtime.flex_fetch(map, :name) == {:ok, "Alice"}
    end

    test "flex_fetch with string key finds value in string-keyed map" do
      map = %{"name" => "Alice"}
      assert Runtime.flex_fetch(map, "name") == {:ok, "Alice"}
    end

    test "flex_fetch with string key finds value in atom-keyed map" do
      map = %{name: "Alice"}
      assert Runtime.flex_fetch(map, "name") == {:ok, "Alice"}
    end

    test "flex_fetch with atom key returns :error for missing key" do
      map = %{name: "Alice"}
      assert Runtime.flex_fetch(map, :age) == :error
    end

    test "flex_fetch with string key returns :error for missing key" do
      map = %{"name" => "Alice"}
      assert Runtime.flex_fetch(map, "age") == :error
    end

    test "flex_fetch preserves nil values" do
      map = %{status: nil}
      assert Runtime.flex_fetch(map, :status) == {:ok, nil}
    end

    test "flex_fetch preserves nil values in string-keyed map" do
      map = %{"status" => nil}
      assert Runtime.flex_fetch(map, "status") == {:ok, nil}
    end

    test "flex_fetch with MapSet returns :error" do
      set = MapSet.new([1, 2, 3])
      assert Runtime.flex_fetch(set, :key) == :error
    end

    test "flex_fetch with nil returns :error" do
      assert Runtime.flex_fetch(nil, :key) == :error
      assert Runtime.flex_fetch(nil, "key") == :error
    end

    test "flex_fetch prefers atom key when both exist" do
      map = %{"name" => "Bob", name: "Alice"}
      assert Runtime.flex_fetch(map, :name) == {:ok, "Alice"}
    end

    test "flex_fetch with non-atom/string key uses Map.fetch directly" do
      map = %{1 => "value"}
      assert Runtime.flex_fetch(map, 1) == {:ok, "value"}
    end
  end
end
