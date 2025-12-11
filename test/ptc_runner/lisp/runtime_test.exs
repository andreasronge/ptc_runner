defmodule PtcRunner.Lisp.RuntimeTest do
  use ExUnit.Case

  alias PtcRunner.Lisp.Runtime
  import PtcRunner.TestSupport.ClojureTestHelpers

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

  # ============================================================
  # Clojure Conformance Tests
  # ============================================================
  # These tests verify that PTC-Lisp behaves identically to Clojure
  # for pure functions in the standard library.
  #
  # Run with: mix test
  # Skip with: mix test --exclude clojure

  describe "Clojure conformance - arithmetic" do
    @describetag :clojure

    test "addition" do
      assert_clojure_equivalent("(+ 1 2)")
      assert_clojure_equivalent("(+ 1 2 3 4 5)")
      assert_clojure_equivalent("(+ 10)")
      assert_clojure_equivalent("(+)")
    end

    test "subtraction" do
      assert_clojure_equivalent("(- 10 3)")
      assert_clojure_equivalent("(- 10 3 2)")
      assert_clojure_equivalent("(- 5)")
    end

    test "multiplication" do
      assert_clojure_equivalent("(* 2 3)")
      assert_clojure_equivalent("(* 2 3 4)")
      assert_clojure_equivalent("(* 5)")
      assert_clojure_equivalent("(*)")
    end

    test "division" do
      assert_clojure_equivalent("(/ 10 2)")
      assert_clojure_equivalent("(/ 100 5 2)")
    end

    test "inc and dec" do
      assert_clojure_equivalent("(inc 5)")
      assert_clojure_equivalent("(dec 5)")
      assert_clojure_equivalent("(inc 0)")
      assert_clojure_equivalent("(dec 0)")
    end

    test "abs" do
      assert_clojure_equivalent("(abs 5)")
      assert_clojure_equivalent("(abs -5)")
      assert_clojure_equivalent("(abs 0)")
    end

    test "max and min" do
      assert_clojure_equivalent("(max 1 5 3)")
      assert_clojure_equivalent("(min 1 5 3)")
      assert_clojure_equivalent("(max 42)")
      assert_clojure_equivalent("(min 42)")
    end

    test "mod" do
      assert_clojure_equivalent("(mod 10 3)")
      assert_clojure_equivalent("(mod 15 5)")
      assert_clojure_equivalent("(mod 7 2)")
    end
  end

  describe "Clojure conformance - collections" do
    @describetag :clojure

    test "count" do
      assert_clojure_equivalent("(count [1 2 3])")
      assert_clojure_equivalent("(count [])")
      assert_clojure_equivalent("(count {:a 1 :b 2})")
    end

    test "first and last" do
      assert_clojure_equivalent("(first [1 2 3])")
      assert_clojure_equivalent("(last [1 2 3])")
      assert_clojure_equivalent("(first [])")
      assert_clojure_equivalent("(last [])")
    end

    test "take and drop" do
      assert_clojure_equivalent("(take 2 [1 2 3 4])")
      assert_clojure_equivalent("(drop 2 [1 2 3 4])")
      assert_clojure_equivalent("(take 10 [1 2 3])")
      assert_clojure_equivalent("(drop 10 [1 2 3])")
    end

    test "reverse" do
      assert_clojure_equivalent("(reverse [1 2 3])")
      assert_clojure_equivalent("(reverse [])")
    end

    test "sort" do
      assert_clojure_equivalent("(sort [3 1 2])")
      assert_clojure_equivalent("(sort [])")
    end

    test "distinct" do
      assert_clojure_equivalent("(distinct [1 2 1 3 2])")
      assert_clojure_equivalent("(distinct [])")
    end

    test "concat" do
      assert_clojure_equivalent("(concat [1 2] [3 4])")
      assert_clojure_equivalent("(concat [1] [2] [3])")
    end

    test "flatten" do
      assert_clojure_equivalent("(flatten [[1 2] [3 4]])")
      assert_clojure_equivalent("(flatten [1 [2 [3 4]]])")
    end

    test "nth" do
      assert_clojure_equivalent("(nth [1 2 3] 0)")
      assert_clojure_equivalent("(nth [1 2 3] 2)")
    end
  end

  describe "Clojure conformance - map operations" do
    @describetag :clojure

    test "get" do
      assert_clojure_equivalent("(get {:a 1 :b 2} :a)")
      assert_clojure_equivalent("(get {:a 1} :missing)")
      assert_clojure_equivalent("(get {:a 1} :missing :default)")
    end

    test "keys and vals" do
      # Note: order may differ, so we test sorted results
      assert_clojure_equivalent("(sort (keys {:a 1 :b 2}))")
      assert_clojure_equivalent("(sort (vals {:a 1 :b 2}))")
    end

    test "assoc" do
      assert_clojure_equivalent("(assoc {:a 1} :b 2)")
      assert_clojure_equivalent("(assoc {} :a 1)")
    end

    test "dissoc" do
      assert_clojure_equivalent("(dissoc {:a 1 :b 2} :b)")
      assert_clojure_equivalent("(dissoc {:a 1} :missing)")
    end

    test "merge" do
      assert_clojure_equivalent("(merge {:a 1} {:b 2})")
      assert_clojure_equivalent("(merge {:a 1} {:a 2})")
    end

    test "select-keys" do
      assert_clojure_equivalent("(select-keys {:a 1 :b 2 :c 3} [:a :c])")
    end
  end

  describe "Clojure conformance - logic" do
    @describetag :clojure

    test "and" do
      assert_clojure_equivalent("(and true true)")
      assert_clojure_equivalent("(and true false)")
      assert_clojure_equivalent("(and false true)")
      assert_clojure_equivalent("(and nil true)")
    end

    test "or" do
      assert_clojure_equivalent("(or false true)")
      assert_clojure_equivalent("(or false false)")
      assert_clojure_equivalent("(or nil false)")
    end

    test "not" do
      assert_clojure_equivalent("(not true)")
      assert_clojure_equivalent("(not false)")
      assert_clojure_equivalent("(not nil)")
    end
  end

  describe "Clojure conformance - predicates" do
    @describetag :clojure

    test "nil?" do
      assert_clojure_equivalent("(nil? nil)")
      assert_clojure_equivalent("(nil? false)")
      assert_clojure_equivalent("(nil? 0)")
    end

    test "some?" do
      assert_clojure_equivalent("(some? nil)")
      assert_clojure_equivalent("(some? false)")
      assert_clojure_equivalent("(some? 0)")
    end

    test "empty?" do
      assert_clojure_equivalent("(empty? [])")
      assert_clojure_equivalent("(empty? [1])")
      assert_clojure_equivalent("(empty? {})")
    end

    test "zero?" do
      assert_clojure_equivalent("(zero? 0)")
      assert_clojure_equivalent("(zero? 1)")
    end

    test "pos? and neg?" do
      assert_clojure_equivalent("(pos? 5)")
      assert_clojure_equivalent("(pos? -1)")
      assert_clojure_equivalent("(pos? 0)")
      assert_clojure_equivalent("(neg? -5)")
      assert_clojure_equivalent("(neg? 1)")
      assert_clojure_equivalent("(neg? 0)")
    end

    test "even? and odd?" do
      assert_clojure_equivalent("(even? 4)")
      assert_clojure_equivalent("(even? 3)")
      assert_clojure_equivalent("(odd? 3)")
      assert_clojure_equivalent("(odd? 4)")
    end
  end

  describe "Clojure conformance - higher-order functions" do
    @describetag :clojure

    test "map" do
      assert_clojure_equivalent("(map inc [1 2 3])")
      assert_clojure_equivalent("(map dec [1 2 3])")
    end

    test "filter" do
      assert_clojure_equivalent("(filter even? [1 2 3 4])")
      assert_clojure_equivalent("(filter odd? [1 2 3 4])")
    end

    test "remove" do
      assert_clojure_equivalent("(remove even? [1 2 3 4])")
      assert_clojure_equivalent("(remove odd? [1 2 3 4])")
    end

    test "reduce" do
      assert_clojure_equivalent("(reduce + [1 2 3])")
      assert_clojure_equivalent("(reduce + 10 [1 2 3])")
      assert_clojure_equivalent("(reduce * [1 2 3 4])")
    end

    test "every?" do
      assert_clojure_equivalent("(every? even? [2 4 6])")
      assert_clojure_equivalent("(every? even? [2 3 4])")
      assert_clojure_equivalent("(every? even? [])")
    end

    test "some" do
      assert_clojure_equivalent("(some even? [1 2 3])")
      assert_clojure_equivalent("(some even? [1 3 5])")
    end
  end

  describe "Clojure conformance - control flow" do
    @describetag :clojure

    test "if" do
      assert_clojure_equivalent("(if true 1 2)")
      assert_clojure_equivalent("(if false 1 2)")
      assert_clojure_equivalent("(if nil 1 2)")
    end

    test "when" do
      assert_clojure_equivalent("(when true 42)")
      assert_clojure_equivalent("(when false 42)")
    end

    test "cond" do
      assert_clojure_equivalent("(cond false 1 true 2)")
      assert_clojure_equivalent("(cond false 1 false 2 :else 3)")
    end

    test "let" do
      assert_clojure_equivalent("(let [x 10] x)")
      assert_clojure_equivalent("(let [x 10 y 20] (+ x y))")
      assert_clojure_equivalent("(let [x 5 y (* x 2)] (+ x y))")
    end
  end

  describe "Clojure conformance - threading macros" do
    @describetag :clojure

    test "thread-last" do
      assert_clojure_equivalent("(->> [1 2 3] (map inc))")
      assert_clojure_equivalent("(->> [1 2 3 4] (filter even?) (map inc))")
      assert_clojure_equivalent("(->> [1 2 3] (reduce +))")
    end

    test "thread-first" do
      assert_clojure_equivalent("(-> {:a 1} (assoc :b 2))")
      assert_clojure_equivalent("(-> {:a {:b 1}} (get :a) (get :b))")
    end
  end
end
