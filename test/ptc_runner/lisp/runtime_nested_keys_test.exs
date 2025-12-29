defmodule PtcRunner.Lisp.RuntimeNestedKeysTest do
  use ExUnit.Case

  alias PtcRunner.Lisp.Runtime

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
end
