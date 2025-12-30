defmodule PtcRunner.SubAgent.Signature.ValidatorTest do
  use ExUnit.Case

  alias PtcRunner.SubAgent.Signature.Validator

  describe "validate/2 - primitives" do
    test "validates string" do
      assert :ok = Validator.validate("hello", :string)
    end

    test "rejects non-string" do
      assert {:error, [%{path: [], message: "expected string, got " <> _}]} =
               Validator.validate(42, :string)
    end

    test "validates integer" do
      assert :ok = Validator.validate(42, :int)
    end

    test "rejects float as int" do
      assert {:error, [%{path: [], message: "expected int, got " <> _}]} =
               Validator.validate(3.14, :int)
    end

    test "rejects boolean as int" do
      assert {:error, [%{path: [], message: "expected int, got " <> _}]} =
               Validator.validate(true, :int)
    end

    test "validates float" do
      assert :ok = Validator.validate(3.14, :float)
    end

    test "rejects int as float" do
      assert {:error, [%{path: [], message: "expected float, got " <> _}]} =
               Validator.validate(42, :float)
    end

    test "validates boolean" do
      assert :ok = Validator.validate(true, :bool)
      assert :ok = Validator.validate(false, :bool)
    end

    test "rejects non-boolean" do
      assert {:error, [%{path: [], message: "expected bool, got " <> _}]} =
               Validator.validate("true", :bool)
    end

    test "validates keyword (atom)" do
      assert :ok = Validator.validate(:pending, :keyword)
    end

    test "rejects string as keyword" do
      assert {:error, [%{path: [], message: "expected keyword, got " <> _}]} =
               Validator.validate("pending", :keyword)
    end
  end

  describe "validate/2 - any type" do
    test "accepts any value" do
      assert :ok = Validator.validate("string", :any)
      assert :ok = Validator.validate(42, :any)
      assert :ok = Validator.validate(%{}, :any)
      assert :ok = Validator.validate([], :any)
    end
  end

  describe "validate/2 - map type" do
    test "accepts any map" do
      assert :ok = Validator.validate(%{}, :map)
      assert :ok = Validator.validate(%{"key" => "value"}, :map)
      assert :ok = Validator.validate(%{custom: "value"}, :map)
    end

    test "rejects non-map" do
      assert {:error, [%{path: [], message: "expected map, got " <> _}]} =
               Validator.validate("not a map", :map)
    end
  end

  describe "validate/2 - optional types" do
    test "accepts nil for optional" do
      assert :ok = Validator.validate(nil, {:optional, :string})
    end

    test "validates value for optional" do
      assert :ok = Validator.validate("hello", {:optional, :string})
    end

    test "rejects wrong type for optional" do
      assert {:error, [%{path: [], message: "expected string, got " <> _}]} =
               Validator.validate(42, {:optional, :string})
    end

    test "validates optional in nested map" do
      assert :ok =
               Validator.validate(%{"email" => nil}, {:map, [{"email", {:optional, :string}}]})
    end

    test "validates optional with value in nested map" do
      assert :ok =
               Validator.validate(
                 %{"email" => "test@example.com"},
                 {:map, [{"email", {:optional, :string}}]}
               )
    end
  end

  describe "validate/2 - lists" do
    test "validates empty list" do
      assert :ok = Validator.validate([], {:list, :int})
    end

    test "validates list of strings" do
      assert :ok = Validator.validate(["a", "b", "c"], {:list, :string})
    end

    test "validates list of integers" do
      assert :ok = Validator.validate([1, 2, 3], {:list, :int})
    end

    test "rejects non-list" do
      assert {:error, [%{path: [], message: "expected list, got " <> _}]} =
               Validator.validate("not a list", {:list, :string})
    end

    test "reports error for wrong element type with index" do
      assert {:error, [%{path: [1], message: "expected int, got " <> _}]} =
               Validator.validate([1, "two", 3], {:list, :int})
    end

    test "reports all element errors" do
      result = Validator.validate([1, "two", 3.0], {:list, :int})
      assert {:error, errors} = result
      assert length(errors) == 2
      assert Enum.any?(errors, &(Enum.at(&1.path, 0) == 1))
      assert Enum.any?(errors, &(Enum.at(&1.path, 0) == 2))
    end

    test "validates list of maps" do
      assert :ok =
               Validator.validate(
                 [%{"id" => 1}, %{"id" => 2}],
                 {:list, {:map, [{"id", :int}]}}
               )
    end
  end

  describe "validate/2 - maps with fields" do
    test "validates single field map" do
      assert :ok = Validator.validate(%{"id" => 1}, {:map, [{"id", :int}]})
    end

    test "validates multiple fields" do
      assert :ok =
               Validator.validate(
                 %{"id" => 1, "name" => "Alice"},
                 {:map, [{"id", :int}, {"name", :string}]}
               )
    end

    test "rejects missing required field" do
      assert {:error, [%{path: ["name"], message: "expected field, got nil"}]} =
               Validator.validate(%{"id" => 1}, {:map, [{"id", :int}, {"name", :string}]})
    end

    test "rejects wrong field type" do
      assert {:error, [%{path: ["id"], message: "expected int, got " <> _}]} =
               Validator.validate(%{"id" => "not an int"}, {:map, [{"id", :int}]})
    end

    test "validates field with atom key" do
      assert :ok = Validator.validate(%{id: 1}, {:map, [{"id", :int}]})
    end

    test "validates field with string key" do
      assert :ok = Validator.validate(%{"id" => 1}, {:map, [{"id", :int}]})
    end

    test "validates optional field as nil" do
      assert :ok =
               Validator.validate(
                 %{"id" => 1},
                 {:map, [{"id", :int}, {"email", {:optional, :string}}]}
               )
    end

    test "validates optional field with value" do
      assert :ok =
               Validator.validate(
                 %{"id" => 1, "email" => "test@example.com"},
                 {:map, [{"id", :int}, {"email", {:optional, :string}}]}
               )
    end
  end

  describe "validate/2 - nested structures" do
    test "validates nested map" do
      assert :ok =
               Validator.validate(
                 %{"user" => %{"id" => 1, "name" => "Alice"}},
                 {:map, [{"user", {:map, [{"id", :int}, {"name", :string}]}}]}
               )
    end

    test "rejects nested field error" do
      result =
        Validator.validate(
          %{"user" => %{"id" => "not int"}},
          {:map, [{"user", {:map, [{"id", :int}]}}]}
        )

      assert {:error, [%{path: ["user", "id"], message: "expected int, got " <> _}]} = result
    end

    test "validates deeply nested structure" do
      assert :ok =
               Validator.validate(
                 %{
                   "user" => %{
                     "profile" => %{
                       "settings" => %{"theme" => "dark"}
                     }
                   }
                 },
                 {:map,
                  [
                    {"user",
                     {:map,
                      [
                        {"profile",
                         {:map,
                          [
                            {"settings", {:map, [{"theme", :string}]}}
                          ]}}
                      ]}}
                  ]}
               )
    end

    test "validates list of maps with nested fields" do
      assert :ok =
               Validator.validate(
                 [%{"id" => 1, "tags" => ["a", "b"]}, %{"id" => 2, "tags" => ["c"]}],
                 {:list, {:map, [{"id", :int}, {"tags", {:list, :string}}]}}
               )
    end
  end

  describe "validate/2 - path reporting" do
    test "includes full path for nested error" do
      result =
        Validator.validate(
          %{"results" => [%{"id" => "not int"}]},
          {:map,
           [
             {"results", {:list, {:map, [{"id", :int}]}}}
           ]}
        )

      assert {:error, [%{path: ["results", 0, "id"], message: _}]} = result
    end

    test "collects multiple errors with paths" do
      result =
        Validator.validate(
          %{"id" => "wrong", "count" => "also wrong"},
          {:map, [{"id", :int}, {"count", :int}]}
        )

      assert {:error, errors} = result
      assert length(errors) == 2

      assert Enum.any?(errors, &(Enum.at(&1.path, 0) == "id"))
      assert Enum.any?(errors, &(Enum.at(&1.path, 0) == "count"))
    end
  end

  describe "validate/2 - spec edge cases" do
    test "validates empty map (no required fields)" do
      assert :ok = Validator.validate(%{}, {:map, []})
    end

    test "allows extra fields in map" do
      # Extra fields are allowed (not strict mode)
      assert :ok =
               Validator.validate(
                 %{"id" => 1, "extra" => "ignored"},
                 {:map, [{"id", :int}]}
               )
    end

    test "validates list of any" do
      assert :ok = Validator.validate([1, "string", %{}, nil], {:list, :any})
    end

    test "validates optional list element" do
      assert :ok =
               Validator.validate(
                 [1, nil, 3],
                 {:list, {:optional, :int}}
               )
    end

    test "validates complex real-world signature output" do
      assert :ok =
               Validator.validate(
                 %{
                   "count" => 5,
                   "items" => [
                     %{"id" => 1, "title" => "Item 1"},
                     %{"id" => 2, "title" => "Item 2"}
                   ]
                 },
                 {:map,
                  [
                    {"count", :int},
                    {"items", {:list, {:map, [{"id", :int}, {"title", :string}]}}}
                  ]}
               )
    end
  end
end
