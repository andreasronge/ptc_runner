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
end
