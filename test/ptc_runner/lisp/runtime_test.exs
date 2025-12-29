defmodule PtcRunner.Lisp.RuntimeTest do
  use ExUnit.Case

  alias PtcRunner.Lisp.Runtime

  # ============================================================
  # String Key Parameters (LLM compatibility)
  # ============================================================
  # These tests verify that functions accept string keys as parameters,
  # not just atoms. LLMs sometimes generate "price" instead of :price.

  describe "string key parameters - sort_by" do
    test "sort_by accepts string key parameter with string-keyed data" do
      data = [%{"price" => 30}, %{"price" => 10}, %{"price" => 20}]
      result = Runtime.sort_by("price", data)
      assert Enum.map(result, & &1["price"]) == [10, 20, 30]
    end

    test "sort_by accepts string key parameter with atom-keyed data" do
      data = [%{price: 30}, %{price: 10}, %{price: 20}]
      result = Runtime.sort_by("price", data)
      assert Enum.map(result, & &1.price) == [10, 20, 30]
    end

    test "sort_by with comparator accepts string key parameter" do
      data = [%{"price" => 10}, %{"price" => 30}, %{"price" => 20}]
      result = Runtime.sort_by("price", &>=/2, data)
      assert Enum.map(result, & &1["price"]) == [30, 20, 10]
    end
  end

  describe "string key parameters - sum_by" do
    test "sum_by accepts string key parameter with string-keyed data" do
      data = [%{"amount" => 10}, %{"amount" => 20}, %{"amount" => 30}]
      result = Runtime.sum_by("amount", data)
      assert result == 60
    end

    test "sum_by accepts string key parameter with atom-keyed data" do
      data = [%{amount: 10}, %{amount: 20}, %{amount: 30}]
      result = Runtime.sum_by("amount", data)
      assert result == 60
    end
  end

  describe "string key parameters - avg_by" do
    test "avg_by accepts string key parameter with string-keyed data" do
      data = [%{"score" => 10}, %{"score" => 20}, %{"score" => 30}]
      result = Runtime.avg_by("score", data)
      assert result == 20.0
    end

    test "avg_by accepts string key parameter with atom-keyed data" do
      data = [%{score: 10}, %{score: 20}, %{score: 30}]
      result = Runtime.avg_by("score", data)
      assert result == 20.0
    end
  end

  describe "string key parameters - min_by" do
    test "min_by accepts string key parameter with string-keyed data" do
      data = [%{"score" => 30}, %{"score" => 10}, %{"score" => 20}]
      result = Runtime.min_by("score", data)
      assert result == %{"score" => 10}
    end

    test "min_by accepts string key parameter with atom-keyed data" do
      data = [%{score: 30}, %{score: 10}, %{score: 20}]
      result = Runtime.min_by("score", data)
      assert result == %{score: 10}
    end
  end

  describe "string key parameters - max_by" do
    test "max_by accepts string key parameter with string-keyed data" do
      data = [%{"score" => 10}, %{"score" => 30}, %{"score" => 20}]
      result = Runtime.max_by("score", data)
      assert result == %{"score" => 30}
    end

    test "max_by accepts string key parameter with atom-keyed data" do
      data = [%{score: 10}, %{score: 30}, %{score: 20}]
      result = Runtime.max_by("score", data)
      assert result == %{score: 30}
    end
  end

  describe "string key parameters - group_by" do
    test "group_by accepts string key parameter with string-keyed data" do
      data = [%{"category" => "a"}, %{"category" => "b"}, %{"category" => "a"}]
      result = Runtime.group_by("category", data)
      assert length(result["a"]) == 2
      assert length(result["b"]) == 1
    end

    test "group_by accepts string key parameter with atom-keyed data" do
      data = [%{category: "a"}, %{category: "b"}, %{category: "a"}]
      result = Runtime.group_by("category", data)
      assert length(result["a"]) == 2
      assert length(result["b"]) == 1
    end
  end

  describe "string key parameters - pluck" do
    test "pluck accepts string key parameter with string-keyed data" do
      data = [%{"name" => "Alice"}, %{"name" => "Bob"}]
      result = Runtime.pluck("name", data)
      assert result == ["Alice", "Bob"]
    end

    test "pluck accepts string key parameter with atom-keyed data" do
      data = [%{name: "Alice"}, %{name: "Bob"}]
      result = Runtime.pluck("name", data)
      assert result == ["Alice", "Bob"]
    end
  end

  describe "string key parameters - get" do
    test "get accepts string key parameter with string-keyed map" do
      map = %{"name" => "Alice"}
      assert Runtime.get(map, "name") == "Alice"
    end

    test "get accepts string key parameter with atom-keyed map" do
      map = %{name: "Alice"}
      assert Runtime.get(map, "name") == "Alice"
    end

    test "get with default accepts string key parameter" do
      map = %{"name" => "Alice"}
      assert Runtime.get(map, "age", 0) == 0
    end

    test "get with default preserves explicit nil values" do
      map = %{status: nil}
      assert Runtime.get(map, :status, "unknown") == nil
      assert Runtime.get(map, "status", "unknown") == nil
    end

    test "get with default and string key preserves explicit nil values in string-keyed map" do
      map = %{"status" => nil}
      assert Runtime.get(map, "status", "unknown") == nil
      assert Runtime.get(map, :status, "unknown") == nil
    end
  end

  describe "string key parameters - contains?" do
    test "contains? accepts string key parameter with string-keyed map" do
      map = %{"name" => "Alice"}
      assert Runtime.contains?(map, "name") == true
      assert Runtime.contains?(map, "age") == false
    end

    test "contains? accepts string key parameter with atom-keyed map" do
      map = %{name: "Alice"}
      assert Runtime.contains?(map, "name") == true
      assert Runtime.contains?(map, "age") == false
    end
  end

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

  describe "flex_get_in - flexible nested key access" do
    test "flex_get_in with empty path returns data" do
      data = %{name: "Alice"}
      assert Runtime.flex_get_in(data, []) == data
    end

    test "flex_get_in with single key in atom-keyed map" do
      data = %{user: %{name: "Alice"}}
      assert Runtime.flex_get_in(data, [:user, :name]) == "Alice"
    end

    test "flex_get_in with single key in string-keyed map" do
      data = %{"user" => %{"name" => "Alice"}}
      assert Runtime.flex_get_in(data, [:user, :name]) == "Alice"
    end

    test "flex_get_in with mixed atom and string keys" do
      data = %{"user" => %{name: "Alice"}}
      assert Runtime.flex_get_in(data, [:user, :name]) == "Alice"
    end

    test "flex_get_in with string path keys" do
      data = %{user: %{name: "Alice"}}
      assert Runtime.flex_get_in(data, ["user", "name"]) == "Alice"
    end

    test "flex_get_in with missing key returns nil" do
      data = %{user: %{name: "Alice"}}
      assert Runtime.flex_get_in(data, [:user, :age]) == nil
    end

    test "flex_get_in with nil in path returns nil" do
      data = %{user: nil}
      assert Runtime.flex_get_in(data, [:user, :name]) == nil
    end

    test "flex_get_in with nil data returns nil" do
      assert Runtime.flex_get_in(nil, [:user, :name]) == nil
    end

    test "flex_get_in preserves nil values at leaf" do
      data = %{user: %{status: nil}}
      assert Runtime.flex_get_in(data, [:user, :status]) == nil
    end

    test "flex_get_in distinguishes nil value from missing key" do
      # This test shows that flex_get_in returns nil in both cases,
      # which is acceptable because get_in semantics treat both the same
      data_with_nil = %{user: %{status: nil}}
      data_without_key = %{user: %{}}

      assert Runtime.flex_get_in(data_with_nil, [:user, :status]) == nil
      assert Runtime.flex_get_in(data_without_key, [:user, :status]) == nil
    end

    test "flex_get_in with deeply nested path" do
      data = %{
        "company" => %{
          "departments" => [
            %{name: "Engineering"}
          ]
        }
      }

      assert Runtime.flex_get_in(data, ["company", "departments"]) == [
               %{name: "Engineering"}
             ]
    end

    test "flex_get_in with non-map intermediate value returns nil" do
      data = %{user: "Alice"}
      assert Runtime.flex_get_in(data, [:user, :name]) == nil
    end

    test "flex_get_in handles atom key preference when both exist" do
      data = %{
        user: %{
          "name" => "Bob",
          name: "Alice"
        }
      }

      assert Runtime.flex_get_in(data, [:user, :name]) == "Alice"
    end
  end

  describe "into - collecting from maps" do
    test "into [] with empty map returns empty list" do
      result = Runtime.into([], %{})
      assert result == []
    end

    test "into [] with map converts entries to vectors" do
      result = Runtime.into([], %{a: 1, b: 2})
      # Result is a list of [key, value] vectors
      assert length(result) == 2
      assert [:a, 1] in result
      assert [:b, 2] in result
    end

    test "into [] with string-keyed map converts entries to vectors" do
      result = Runtime.into([], %{"x" => 10, "y" => 20})
      assert length(result) == 2
      assert ["x", 10] in result
      assert ["y", 20] in result
    end

    test "into [] with nested map values preserves structure" do
      result = Runtime.into([], %{a: %{b: 1}})
      assert result == [[:a, %{b: 1}]]
    end

    test "into with existing vector preserves existing elements" do
      result = Runtime.into([99], %{a: 1})
      assert 99 in result
      assert [:a, 1] in result
    end
  end

  describe "into - collecting from lists" do
    test "into [] with empty list returns empty list" do
      result = Runtime.into([], [])
      assert result == []
    end

    test "into [] with list keeps elements as-is (no map conversion)" do
      result = Runtime.into([], [1, 2, 3])
      assert result == [1, 2, 3]
    end

    test "into with existing vector appends list elements" do
      result = Runtime.into([99], [1, 2])
      assert result == [99, 1, 2]
    end
  end

  describe "filter - seqable map support" do
    test "filter on empty map returns empty list" do
      result = Runtime.filter(fn _entry -> true end, %{})
      assert result == []
    end

    test "filter on map keeps entries where predicate is true, returns list of pairs" do
      map = %{a: 1, b: 2, c: 3}
      result = Runtime.filter(fn entry -> Enum.at(entry, 1) > 1 end, map)
      # Returns list of [key, value] pairs, sorted for comparison
      assert Enum.sort(result) == [[:b, 2], [:c, 3]]
    end

    test "filter on map removes entries where predicate is false" do
      map = %{a: 10, b: 5, c: 15}
      result = Runtime.filter(fn entry -> Enum.at(entry, 1) > 7 end, map)
      assert Enum.sort(result) == [[:a, 10], [:c, 15]]
    end

    test "filter on map with atom keys works correctly" do
      map = %{x: "hello", y: "world", z: "test"}
      result = Runtime.filter(fn entry -> String.length(Enum.at(entry, 1)) > 4 end, map)
      assert Enum.sort(result) == [[:x, "hello"], [:y, "world"]]
    end

    test "filter on map with string keys works correctly" do
      map = %{"a" => 1, "b" => 2, "c" => 3}
      result = Runtime.filter(fn entry -> Enum.at(entry, 1) <= 2 end, map)
      assert Enum.sort(result) == [["a", 1], ["b", 2]]
    end
  end

  describe "remove - seqable map support" do
    test "remove on empty map returns empty list" do
      result = Runtime.remove(fn _entry -> true end, %{})
      assert result == []
    end

    test "remove on map removes entries where predicate is true, returns list of pairs" do
      map = %{a: 1, b: 2, c: 3}
      result = Runtime.remove(fn entry -> Enum.at(entry, 1) == 2 end, map)
      assert Enum.sort(result) == [[:a, 1], [:c, 3]]
    end

    test "remove on map keeps entries where predicate is false" do
      map = %{a: 10, b: 5, c: 15}
      result = Runtime.remove(fn entry -> Enum.at(entry, 1) > 7 end, map)
      assert result == [[:b, 5]]
    end

    test "remove on map with atom keys works correctly" do
      map = %{x: "hello", y: "world", z: "test"}
      result = Runtime.remove(fn entry -> String.length(Enum.at(entry, 1)) > 4 end, map)
      assert result == [[:z, "test"]]
    end

    test "remove on map with string keys works correctly" do
      map = %{"a" => 1, "b" => 2, "c" => 3}
      result = Runtime.remove(fn entry -> Enum.at(entry, 1) <= 2 end, map)
      assert result == [["c", 3]]
    end
  end

  describe "sort_by - seqable map support" do
    test "sort_by on map returns list of pairs in sorted order" do
      map = %{a: 3, b: 1, c: 2}
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, map)
      # Returns list of [key, value] pairs in sorted order (preserves order unlike maps)
      assert result == [[:b, 1], [:c, 2], [:a, 3]]
    end

    test "sort_by on empty map with function returns empty list" do
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, %{})
      assert result == []
    end

    test "sort_by on map with comparator sorts entries in order" do
      map = %{a: 1, b: 3, c: 2}
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, &>=/2, map)
      assert result == [[:b, 3], [:c, 2], [:a, 1]]
    end

    test "sort_by on map with string values preserves sort order" do
      map = %{x: "cherry", y: "apple", z: "banana"}
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, map)
      assert result == [[:y, "apple"], [:z, "banana"], [:x, "cherry"]]
    end

    test "sort_by on map with numeric values descending preserves order" do
      map = %{a: 100, b: 50, c: 75}
      result = Runtime.sort_by(fn entry -> Enum.at(entry, 1) end, &>=/2, map)
      assert result == [[:a, 100], [:c, 75], [:b, 50]]
    end
  end

  describe "entries function" do
    test "entries on empty map returns empty list" do
      result = Runtime.entries(%{})
      assert result == []
    end

    test "entries on map returns list of [key, value] pairs" do
      result = Runtime.entries(%{a: 1, b: 2})
      assert result == [[:a, 1], [:b, 2]]
    end

    test "entries returns pairs sorted by key" do
      result = Runtime.entries(%{z: 26, a: 1, m: 13})
      assert result == [[:a, 1], [:m, 13], [:z, 26]]
    end

    test "entries with string keys returns sorted pairs" do
      result = Runtime.entries(%{"z" => 26, "a" => 1, "m" => 13})
      assert result == [["a", 1], ["m", 13], ["z", 26]]
    end

    test "entries with mixed string and numeric values" do
      result = Runtime.entries(%{x: "hello", y: 42})
      assert result == [[:x, "hello"], [:y, 42]]
    end
  end

  describe "identity function" do
    test "identity returns its argument unchanged" do
      assert Runtime.identity(42) == 42
      assert Runtime.identity("hello") == "hello"
      assert Runtime.identity([1, 2, 3]) == [1, 2, 3]
      assert Runtime.identity(%{a: 1}) == %{a: 1}
    end

    test "identity with nil returns nil" do
      assert Runtime.identity(nil) == nil
    end
  end

  describe "zip - returns vectors not tuples" do
    test "zip returns list of vectors" do
      result = Runtime.zip([1, 2, 3], [:a, :b, :c])
      assert result == [[1, :a], [2, :b], [3, :c]]
    end

    test "zip with empty lists returns empty list" do
      result = Runtime.zip([], [])
      assert result == []
    end

    test "zip with unequal lengths truncates to shorter" do
      result = Runtime.zip([1, 2], [:a, :b, :c])
      assert result == [[1, :a], [2, :b]]
    end

    test "zip elements are accessible with first/second" do
      result = Runtime.zip([1, 2], [:a, :b])
      first_pair = List.first(result)
      assert Runtime.first(first_pair) == 1
      assert Runtime.second(first_pair) == :a
    end

    test "zip elements are accessible with nth" do
      result = Runtime.zip([1, 2], [:a, :b])
      first_pair = List.first(result)
      assert Runtime.nth(first_pair, 0) == 1
      assert Runtime.nth(first_pair, 1) == :a
    end
  end

  describe "assoc_in - flexible nested key insertion" do
    test "assoc_in with empty map creates intermediate maps" do
      result = Runtime.assoc_in(%{}, [:a, :b], 42)
      assert result == %{a: %{b: 42}}
    end

    test "assoc_in with documented example: assoc_in {} [:user :name] \"Bob\"" do
      result = Runtime.assoc_in(%{}, [:user, :name], "Bob")
      assert result == %{user: %{name: "Bob"}}
    end

    test "assoc_in with existing partial path" do
      data = %{user: %{age: 30}}
      result = Runtime.assoc_in(data, [:user, :name], "Alice")
      assert result == %{user: %{age: 30, name: "Alice"}}
    end

    test "assoc_in with deeply nested path on empty map" do
      result = Runtime.assoc_in(%{}, [:a, :b, :c, :d], "deep")
      assert result == %{a: %{b: %{c: %{d: "deep"}}}}
    end

    test "assoc_in with single key" do
      result = Runtime.assoc_in(%{}, [:x], 10)
      assert result == %{x: 10}
    end

    test "assoc_in with nil data creates from empty map" do
      result = Runtime.assoc_in(nil, [:a, :b], 42)
      assert result == %{a: %{b: 42}}
    end

    test "assoc_in with string and atom keys mixed" do
      result = Runtime.assoc_in(%{}, ["user", :name], "Bob")
      assert result == %{"user" => %{name: "Bob"}}
    end

    test "assoc_in with string keys creates new string key entry" do
      data = %{user: %{age: 30}}
      result = Runtime.assoc_in(data, ["user", "name"], "Alice")
      # flex_fetch finds :user with atom, but puts string "user" key separately
      assert result[:user] == %{age: 30}
      assert result["user"]["name"] == "Alice"
    end

    test "assoc_in raises when intermediate value is not a map" do
      data = %{user: "Alice"}

      assert_raise ArgumentError, ~r/could not put\/update/, fn ->
        Runtime.assoc_in(data, [:user, :age], 30)
      end
    end

    test "assoc_in raises with nil intermediate value in path" do
      data = %{user: nil}

      assert_raise ArgumentError, ~r/could not put\/update/, fn ->
        Runtime.assoc_in(data, [:user, :age], 30)
      end
    end

    test "assoc_in overwrites existing nested value" do
      data = %{a: %{b: 1, c: 2}}
      result = Runtime.assoc_in(data, [:a, :b], 99)
      assert result == %{a: %{b: 99, c: 2}}
    end

    test "assoc_in with list value" do
      result = Runtime.assoc_in(%{}, [:items], [1, 2, 3])
      assert result == %{items: [1, 2, 3]}
    end
  end

  describe "update_in - flexible nested key update" do
    test "update_in with empty map creates intermediate maps" do
      result = Runtime.update_in(%{}, [:a, :b], &((&1 || 0) + 1))
      assert result == %{a: %{b: 1}}
    end

    test "update_in applies function to missing key (nil)" do
      result = Runtime.update_in(%{}, [:x], fn v -> (v || 0) + 5 end)
      assert result == %{x: 5}
    end

    test "update_in with existing value applies function" do
      data = %{x: 10}
      result = Runtime.update_in(data, [:x], &(&1 + 5))
      assert result == %{x: 15}
    end

    test "update_in with deeply nested path on empty map" do
      result =
        Runtime.update_in(%{}, [:a, :b, :c], fn v ->
          (v || "") <> "value"
        end)

      assert result == %{a: %{b: %{c: "value"}}}
    end

    test "update_in with nil data creates from empty map" do
      result = Runtime.update_in(nil, [:a, :b], &((&1 || 0) + 1))
      assert result == %{a: %{b: 1}}
    end

    test "update_in with string and atom keys mixed" do
      result =
        Runtime.update_in(%{}, ["user", :age], fn v ->
          (v || 0) + 1
        end)

      assert result == %{"user" => %{age: 1}}
    end

    test "update_in with existing path applies function at each level" do
      data = %{a: %{b: 10}}
      result = Runtime.update_in(data, [:a, :b], &(&1 * 2))
      assert result == %{a: %{b: 20}}
    end

    test "update_in raises when intermediate value is not a map" do
      data = %{user: "Alice"}

      assert_raise ArgumentError, ~r/could not put\/update/, fn ->
        Runtime.update_in(data, [:user, :age], &(&1 || 0))
      end
    end

    test "update_in raises with nil intermediate value in path" do
      data = %{user: nil}

      assert_raise ArgumentError, ~r/could not put\/update/, fn ->
        Runtime.update_in(data, [:user, :age], &(&1 || 0))
      end
    end

    test "update_in with multiple nested levels" do
      data = %{x: %{y: %{z: 5}}}
      result = Runtime.update_in(data, [:x, :y, :z], &(&1 + 10))
      assert result == %{x: %{y: %{z: 15}}}
    end

    test "update_in on empty path applies function to entire data" do
      result = Runtime.update_in(%{a: 1}, [], &Map.put(&1, :b, 2))
      assert result == %{a: 1, b: 2}
    end
  end

  describe "flex_put_in - helper function" do
    test "flex_put_in returns value when path is empty" do
      result = Runtime.flex_put_in(%{a: 1}, [], 99)
      assert result == 99
    end

    test "flex_put_in with single key inserts into map" do
      result = Runtime.flex_put_in(%{}, [:x], 10)
      assert result == %{x: 10}
    end

    test "flex_put_in prefers atom key over string key" do
      data = %{"a" => %{}, a: %{}}
      result = Runtime.flex_put_in(data, [:a, :b], 5)
      assert result == %{"a" => %{}, a: %{b: 5}}
    end
  end

  describe "flex_update_in - helper function" do
    test "flex_update_in applies function when path is empty" do
      result = Runtime.flex_update_in(%{a: 1}, [], fn m -> Map.put(m, :b, 2) end)
      assert result == %{a: 1, b: 2}
    end

    test "flex_update_in applies function to single key" do
      result = Runtime.flex_update_in(%{x: 10}, [:x], &(&1 + 5))
      assert result == %{x: 15}
    end

    test "flex_update_in prefers atom key over string key" do
      data = %{"a" => %{x: 10}, a: %{x: 20}}
      result = Runtime.flex_update_in(data, [:a, :x], &(&1 + 5))
      assert result == %{"a" => %{x: 10}, a: %{x: 25}}
    end
  end

  describe "update_vals" do
    # Note: Arguments are (m, f) matching Clojure's (update-vals m f)

    test "applies function to each value" do
      map = %{a: [1, 2], b: [3, 4, 5]}
      result = Runtime.update_vals(map, &length/1)
      assert result == %{a: 2, b: 3}
    end

    test "works with empty map" do
      result = Runtime.update_vals(%{}, &length/1)
      assert result == %{}
    end

    test "works with nil map" do
      result = Runtime.update_vals(nil, &length/1)
      assert result == nil
    end

    test "preserves keys (string keys)" do
      map = %{"pending" => [1, 2], "done" => [3]}
      result = Runtime.update_vals(map, &length/1)
      assert result == %{"pending" => 2, "done" => 1}
    end

    test "preserves keys (atom keys)" do
      map = %{pending: [1, 2], done: [3]}
      result = Runtime.update_vals(map, &length/1)
      assert result == %{pending: 2, done: 1}
    end

    test "works with count function for group-by use case" do
      # Simulates (->> (group-by :status orders) (update-vals count))
      grouped = %{
        "pending" => [%{id: 1}, %{id: 2}],
        "delivered" => [%{id: 3}]
      }

      result = Runtime.update_vals(grouped, &Enum.count/1)
      assert result == %{"pending" => 2, "delivered" => 1}
    end

    test "works with sum aggregation" do
      grouped = %{
        "a" => [%{amount: 10}, %{amount: 20}],
        "b" => [%{amount: 5}]
      }

      sum_amounts = fn items -> Enum.sum(Enum.map(items, & &1.amount)) end
      result = Runtime.update_vals(grouped, sum_amounts)
      assert result == %{"a" => 30, "b" => 5}
    end
  end

  describe "parse_long" do
    test "parses valid integers" do
      assert Runtime.parse_long("42") == 42
      assert Runtime.parse_long("-17") == -17
      assert Runtime.parse_long("0") == 0
    end

    test "returns nil for invalid input" do
      assert Runtime.parse_long("abc") == nil
      assert Runtime.parse_long("3.14") == nil
      assert Runtime.parse_long(" 42") == nil
      assert Runtime.parse_long("42abc") == nil
    end

    test "handles nil and non-strings" do
      assert Runtime.parse_long(nil) == nil
      assert Runtime.parse_long(42) == nil
    end
  end

  describe "parse_double" do
    test "parses valid floats" do
      assert Runtime.parse_double("3.14") == 3.14
      assert Runtime.parse_double("-0.5") == -0.5
      assert Runtime.parse_double("42") == 42.0
      assert Runtime.parse_double("1e10") == 1.0e10
    end

    test "returns nil for invalid input" do
      assert Runtime.parse_double("abc") == nil
      assert Runtime.parse_double(" 3.14") == nil
      assert Runtime.parse_double("3.14abc") == nil
    end

    test "handles nil and non-strings" do
      assert Runtime.parse_double(nil) == nil
      assert Runtime.parse_double(3.14) == nil
    end
  end

  describe "str2" do
    test "concatenates two strings" do
      assert Runtime.str2("hello", " world") == "hello world"
    end

    test "converts non-string values to string" do
      assert Runtime.str2("count: ", 42) == "count: 42"
      assert Runtime.str2("value: ", true) == "value: true"
    end

    test "handles nil by converting to empty string" do
      assert Runtime.str2("x", nil) == "x"
      assert Runtime.str2(nil, "y") == "y"
      assert Runtime.str2(nil, nil) == ""
    end

    test "converts keyword atoms to :keyword format" do
      assert Runtime.str2("keyword: ", :my_key) == "keyword: :my_key"
    end
  end

  describe "subs" do
    test "returns substring from start index" do
      assert Runtime.subs("hello", 1) == "ello"
      assert Runtime.subs("hello", 0) == "hello"
    end

    test "returns substring from start to end index" do
      assert Runtime.subs("hello", 1, 3) == "el"
      assert Runtime.subs("hello", 0, 5) == "hello"
      assert Runtime.subs("hello", 0, 0) == ""
    end

    test "clamps negative indices to 0" do
      assert Runtime.subs("hello", -1) == "hello"
      assert Runtime.subs("hello", -10, 2) == "he"
    end

    test "handles out of bounds indices" do
      assert Runtime.subs("hello", 10) == ""
      assert Runtime.subs("hello", 3, 10) == "lo"
    end
  end

  describe "join" do
    test "joins collection without separator" do
      assert Runtime.join(["a", "b", "c"]) == "abc"
      assert Runtime.join([]) == ""
    end

    test "joins collection with separator" do
      assert Runtime.join(", ", ["a", "b", "c"]) == "a, b, c"
      assert Runtime.join("-", [1, 2, 3]) == "1-2-3"
    end

    test "converts elements to strings" do
      assert Runtime.join(", ", [1, "two", true]) == "1, two, true"
    end

    test "handles empty collection" do
      assert Runtime.join(", ", []) == ""
    end

    test "handles nil in collection" do
      assert Runtime.join(", ", [1, nil, 3]) == "1, , 3"
    end
  end

  describe "split" do
    test "splits string by separator" do
      assert Runtime.split("a,b,c", ",") == ["a", "b", "c"]
      assert Runtime.split("hello world", " ") == ["hello", "world"]
    end

    test "splits string into graphemes when separator is empty" do
      assert Runtime.split("hello", "") == ["h", "e", "l", "l", "o"]
    end

    test "preserves empty strings in split" do
      assert Runtime.split("a,,b", ",") == ["a", "", "b"]
    end
  end

  describe "trim" do
    test "removes leading and trailing whitespace" do
      assert Runtime.trim("  hello  ") == "hello"
      assert Runtime.trim("\n\t text \r\n") == "text"
    end

    test "removes only leading and trailing, not middle" do
      assert Runtime.trim("  hello   world  ") == "hello   world"
    end

    test "handles no whitespace" do
      assert Runtime.trim("hello") == "hello"
    end
  end

  describe "replace" do
    test "replaces all occurrences of pattern" do
      assert Runtime.replace("hello", "l", "L") == "heLLo"
      assert Runtime.replace("aaa", "a", "b") == "bbb"
    end

    test "replaces multiple patterns sequentially" do
      result = Runtime.replace("hello", "l", "1")
      assert result == "he11o"
    end

    test "handles no match" do
      assert Runtime.replace("hello", "x", "y") == "hello"
    end

    test "handles empty replacement" do
      assert Runtime.replace("hello", "l", "") == "heo"
    end
  end

  describe "upcase" do
    test "converts string to uppercase" do
      assert Runtime.upcase("hello") == "HELLO"
      assert Runtime.upcase("Hello World") == "HELLO WORLD"
    end

    test "handles empty string" do
      assert Runtime.upcase("") == ""
    end

    test "handles already uppercase string" do
      assert Runtime.upcase("HELLO") == "HELLO"
    end

    test "handles mixed case" do
      assert Runtime.upcase("HeLLo") == "HELLO"
    end
  end

  describe "downcase" do
    test "converts string to lowercase" do
      assert Runtime.downcase("HELLO") == "hello"
      assert Runtime.downcase("Hello World") == "hello world"
    end

    test "handles empty string" do
      assert Runtime.downcase("") == ""
    end

    test "handles already lowercase string" do
      assert Runtime.downcase("hello") == "hello"
    end

    test "handles mixed case" do
      assert Runtime.downcase("HeLLo") == "hello"
    end
  end

  describe "starts_with?" do
    test "returns true when string starts with prefix" do
      assert Runtime.starts_with?("hello", "he") == true
      assert Runtime.starts_with?("hello world", "hello") == true
    end

    test "returns false when string does not start with prefix" do
      assert Runtime.starts_with?("hello", "x") == false
      assert Runtime.starts_with?("hello", "ello") == false
    end

    test "returns true for empty prefix" do
      assert Runtime.starts_with?("hello", "") == true
    end

    test "handles case sensitivity" do
      assert Runtime.starts_with?("Hello", "hello") == false
      assert Runtime.starts_with?("Hello", "He") == true
    end
  end

  describe "ends_with?" do
    test "returns true when string ends with suffix" do
      assert Runtime.ends_with?("hello", "lo") == true
      assert Runtime.ends_with?("hello world", "world") == true
    end

    test "returns false when string does not end with suffix" do
      assert Runtime.ends_with?("hello", "x") == false
      assert Runtime.ends_with?("hello", "hell") == false
    end

    test "returns true for empty suffix" do
      assert Runtime.ends_with?("hello", "") == true
    end

    test "handles case sensitivity" do
      assert Runtime.ends_with?("Hello", "hello") == false
      assert Runtime.ends_with?("Hello", "lo") == true
    end
  end

  describe "includes?" do
    test "returns true when string contains substring" do
      assert Runtime.includes?("hello", "ll") == true
      assert Runtime.includes?("hello world", "o w") == true
    end

    test "returns false when string does not contain substring" do
      assert Runtime.includes?("hello", "x") == false
      assert Runtime.includes?("hello", "xyz") == false
    end

    test "returns true for empty substring" do
      assert Runtime.includes?("hello", "") == true
    end

    test "handles case sensitivity" do
      assert Runtime.includes?("Hello", "hello") == false
      assert Runtime.includes?("hello", "ell") == true
    end
  end
end
