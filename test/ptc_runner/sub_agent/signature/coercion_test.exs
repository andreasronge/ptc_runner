defmodule PtcRunner.SubAgent.Signature.CoercionTest do
  use ExUnit.Case
  doctest PtcRunner.SubAgent.Signature.Coercion

  alias PtcRunner.SubAgent.Signature.Coercion

  describe "coerce/2 - string" do
    test "accepts string" do
      assert {:ok, "hello", []} = Coercion.coerce("hello", :string)
    end

    test "coerces atom to string with warning" do
      assert {:ok, "pending", ["coerced keyword to string"]} =
               Coercion.coerce(:pending, :string)
    end

    test "rejects non-string, non-atom" do
      assert {:error, _} = Coercion.coerce(42, :string)
    end
  end

  describe "coerce/2 - integer" do
    test "accepts integer" do
      assert {:ok, 42, []} = Coercion.coerce(42, :int)
    end

    test "accepts negative integer" do
      assert {:ok, -5, []} = Coercion.coerce(-5, :int)
    end

    test "rejects boolean as integer" do
      assert {:error, _} = Coercion.coerce(true, :int)
    end

    test "coerces string to integer with warning" do
      assert {:ok, 42, ["coerced string \"42\" to integer"]} =
               Coercion.coerce("42", :int)
    end

    test "coerces negative string to integer" do
      assert {:ok, -5, ["coerced string \"-5\" to integer"]} =
               Coercion.coerce("-5", :int)
    end

    test "rejects non-numeric string" do
      assert {:error, "cannot coerce string \"hello\" to integer"} =
               Coercion.coerce("hello", :int)
    end

    test "rejects float as integer (precision loss)" do
      assert {:error, _} = Coercion.coerce(42.0, :int)
    end
  end

  describe "coerce/2 - float" do
    test "accepts float" do
      assert {:ok, 3.14, []} = Coercion.coerce(3.14, :float)
    end

    test "widens integer to float silently" do
      assert {:ok, 42.0, []} = Coercion.coerce(42, :float)
    end

    test "coerces string to float with warning" do
      assert {:ok, 3.14, ["coerced string \"3.14\" to float"]} =
               Coercion.coerce("3.14", :float)
    end

    test "coerces integer string to float" do
      assert {:ok, 42.0, ["coerced string \"42\" to float"]} =
               Coercion.coerce("42", :float)
    end

    test "rejects non-numeric string" do
      assert {:error, _} = Coercion.coerce("hello", :float)
    end
  end

  describe "coerce/2 - bool" do
    test "accepts true" do
      assert {:ok, true, []} = Coercion.coerce(true, :bool)
    end

    test "accepts false" do
      assert {:ok, false, []} = Coercion.coerce(false, :bool)
    end

    test "coerces \"true\" string with warning" do
      assert {:ok, true, ["coerced string \"true\" to boolean"]} =
               Coercion.coerce("true", :bool)
    end

    test "coerces \"false\" string with warning" do
      assert {:ok, false, ["coerced string \"false\" to boolean"]} =
               Coercion.coerce("false", :bool)
    end

    test "rejects other strings" do
      assert {:error, _} = Coercion.coerce("yes", :bool)
    end

    test "rejects integer as boolean" do
      assert {:error, _} = Coercion.coerce(1, :bool)
    end
  end

  describe "coerce/2 - keyword (atom)" do
    test "accepts atom" do
      assert {:ok, :pending, []} = Coercion.coerce(:pending, :keyword)
    end

    test "coerces string to keyword with warning" do
      assert {:ok, :hello, ["coerced string \"hello\" to keyword"]} =
               Coercion.coerce("hello", :keyword)
    end

    test "rejects string that is not an existing atom" do
      assert {:error, "cannot coerce string \"" <> _} =
               Coercion.coerce("nonexistent_atom_#{System.unique_integer()}", :keyword)
    end

    test "rejects non-string, non-atom" do
      assert {:error, _} = Coercion.coerce(42, :keyword)
    end
  end

  describe "coerce/2 - any" do
    test "accepts any value" do
      assert {:ok, "string", []} = Coercion.coerce("string", :any)
      assert {:ok, 42, []} = Coercion.coerce(42, :any)
      assert {:ok, true, []} = Coercion.coerce(true, :any)
      assert {:ok, %{}, []} = Coercion.coerce(%{}, :any)
      assert {:ok, [], []} = Coercion.coerce([], :any)
    end
  end

  describe "coerce/2 - map (untyped)" do
    test "accepts map" do
      assert {:ok, %{"key" => "value"}, []} = Coercion.coerce(%{"key" => "value"}, :map)
    end

    test "accepts empty map" do
      assert {:ok, %{}, []} = Coercion.coerce(%{}, :map)
    end

    test "rejects non-map" do
      assert {:error, _} = Coercion.coerce("not a map", :map)
    end
  end

  describe "coerce/2 - optional types" do
    test "accepts nil for optional" do
      assert {:ok, nil, []} = Coercion.coerce(nil, {:optional, :string})
    end

    test "coerces value for optional" do
      assert {:ok, "hello", []} = Coercion.coerce("hello", {:optional, :string})
    end

    test "coerces string to int for optional" do
      assert {:ok, 42, ["coerced string \"42\" to integer"]} =
               Coercion.coerce("42", {:optional, :int})
    end
  end

  describe "coerce/2 - list types" do
    test "accepts empty list" do
      assert {:ok, [], []} = Coercion.coerce([], {:list, :int})
    end

    test "accepts list of integers" do
      assert {:ok, [1, 2, 3], []} = Coercion.coerce([1, 2, 3], {:list, :int})
    end

    test "coerces nested lists in maps" do
      data = %{"items" => ["1", "2", "3"]}
      signature = {:map, [{"items", {:list, :int}}]}

      assert {:ok, %{"items" => [1, 2, 3]}, warnings} =
               Coercion.coerce(data, signature)

      assert length(warnings) == 3
    end

    test "coerces list of floats with mixed types" do
      assert {:ok, [1.0, 2.5, 3.0], warnings} =
               Coercion.coerce([1, 2.5, "3"], {:list, :float})

      # 1 -> 1.0 is silent, 2.5 is accepted, "3" -> 3.0 generates 1 warning
      assert length(warnings) == 1
    end

    test "rejects non-list" do
      assert {:error, _} = Coercion.coerce("not a list", {:list, :int})
    end

    test "fails if element cannot be coerced" do
      assert {:error, "cannot coerce string \"hello\" to integer"} =
               Coercion.coerce(["1", "hello", "3"], {:list, :int})
    end
  end

  describe "coerce/2 - map types (typed maps)" do
    test "accepts map with correct types" do
      data = %{"id" => 42, "name" => "Alice"}
      signature = {:map, [{"id", :int}, {"name", :string}]}

      assert {:ok, %{"id" => 42, "name" => "Alice"}, []} =
               Coercion.coerce(data, signature)
    end

    test "coerces map fields with warnings" do
      data = %{"id" => "42", "name" => "Alice"}
      signature = {:map, [{"id", :int}, {"name", :string}]}

      assert {:ok, %{"id" => 42, "name" => "Alice"}, ["coerced string \"42\" to integer"]} =
               Coercion.coerce(data, signature)
    end

    test "accepts map with atom keys" do
      data = %{id: 42, name: "Alice"}
      signature = {:map, [{"id", :int}, {"name", :string}]}

      assert {:ok, %{id: 42, name: "Alice"}, []} =
               Coercion.coerce(data, signature)
    end

    test "accepts map with optional fields (present)" do
      data = %{"id" => 42, "email" => "alice@example.com"}
      signature = {:map, [{"id", :int}, {"email", {:optional, :string}}]}

      assert {:ok, %{"id" => 42, "email" => "alice@example.com"}, []} =
               Coercion.coerce(data, signature)
    end

    test "accepts map with optional fields (missing)" do
      data = %{"id" => 42}
      signature = {:map, [{"id", :int}, {"email", {:optional, :string}}]}

      assert {:ok, %{"id" => 42}, []} =
               Coercion.coerce(data, signature)
    end

    test "rejects map with missing required field" do
      data = %{"id" => 42}
      signature = {:map, [{"id", :int}, {"name", :string}]}

      assert {:error, "missing required field \"name\""} =
               Coercion.coerce(data, signature)
    end

    test "rejects non-map" do
      assert {:error, _} = Coercion.coerce("not a map", {:map, [{"id", :int}]})
    end
  end

  describe "coerce/2 - nested maps" do
    test "coerces nested map structures" do
      data = %{"user" => %{"id" => "42", "name" => "Alice"}}

      signature = {:map, [{"user", {:map, [{"id", :int}, {"name", :string}]}}]}

      assert {:ok, %{"user" => %{"id" => 42, "name" => "Alice"}}, warnings} =
               Coercion.coerce(data, signature)

      assert ["coerced string \"42\" to integer"] = warnings
    end

    test "coerces nested lists in maps" do
      data = %{"items" => ["1", "2", "3"]}
      signature = {:map, [{"items", {:list, :int}}]}

      assert {:ok, %{"items" => [1, 2, 3]}, warnings} =
               Coercion.coerce(data, signature)

      assert length(warnings) == 3
    end
  end

  describe "edge cases" do
    test "empty string cannot be coerced to int" do
      assert {:error, _} = Coercion.coerce("", :int)
    end

    test "whitespace string cannot be coerced to int" do
      assert {:error, _} = Coercion.coerce("   ", :int)
    end

    test "handles zero correctly" do
      assert {:ok, 0, []} = Coercion.coerce(0, :int)
      assert {:ok, 0, ["coerced string \"0\" to integer"]} = Coercion.coerce("0", :int)
    end

    test "handles negative zero" do
      assert {:ok, 0, ["coerced string \"-0\" to integer"]} = Coercion.coerce("-0", :int)
    end

    test "handles float with no integer part" do
      assert {:ok, 0.5, ["coerced string \"0.5\" to float"]} =
               Coercion.coerce("0.5", :float)
    end

    test "handles scientific notation for float" do
      assert {:ok, 1.0e3, _} = Coercion.coerce("1e3", :float)
    end

    test "accumulates warnings from nested structures" do
      data = %{
        "results" => [
          %{"id" => "1", "count" => "10"},
          %{"id" => "2", "count" => "20"}
        ]
      }

      signature = {:map, [{"results", {:list, {:map, [{"id", :int}, {"count", :int}]}}}]}

      assert {:ok, _, warnings} = Coercion.coerce(data, signature)
      assert length(warnings) == 4
    end
  end

  describe "coerce/3 with options" do
    test "accepts options parameter" do
      assert {:ok, 42, ["coerced string \"42\" to integer"]} =
               Coercion.coerce("42", :int, [])
    end

    test "accepts nested option" do
      assert {:ok, 42, ["coerced string \"42\" to integer"]} =
               Coercion.coerce("42", :int, nested: true)
    end
  end

  # Regression: the @doc says "DateTime.t() -> :string" but the actual
  # `:string` clauses used to reject anything that wasn't a binary or atom.
  # An agent returning a DateTime through a `:string` field would fail
  # validation. Now the temporal-struct clauses normalize to ISO 8601.
  describe "coerce/2 - temporal structs to :string" do
    test "DateTime coerces to ISO 8601" do
      assert {:ok, "2026-05-03T09:14:00Z", _} =
               Coercion.coerce(~U[2026-05-03 09:14:00Z], :string, [])
    end

    test "NaiveDateTime coerces to ISO 8601" do
      assert {:ok, "2026-05-03T09:14:00", _} =
               Coercion.coerce(~N[2026-05-03 09:14:00], :string, [])
    end

    test "Date coerces to ISO 8601" do
      assert {:ok, "2026-05-03", _} = Coercion.coerce(~D[2026-05-03], :string, [])
    end

    test "Time coerces to ISO 8601" do
      assert {:ok, "09:14:00", _} = Coercion.coerce(~T[09:14:00], :string, [])
    end
  end

  describe "coerce/2 - :datetime" do
    test "ISO 8601 string with Z normalizes to UTC %DateTime{}" do
      assert {:ok, %DateTime{} = dt, ["normalized to UTC"]} =
               Coercion.coerce("2026-05-03T09:14:00Z", :datetime, [])

      assert dt == ~U[2026-05-03 09:14:00Z]
    end

    test "ISO 8601 string with non-UTC offset shifts to UTC and warns" do
      assert {:ok, %DateTime{} = dt, warnings} =
               Coercion.coerce("2026-05-03T09:14:00+02:00", :datetime, [])

      assert dt == ~U[2026-05-03 07:14:00Z]
      assert "non-UTC offset in datetime, normalized to UTC" in warnings
    end

    test "%DateTime{} passes through unchanged" do
      assert {:ok, ~U[2026-05-03 09:14:00Z], []} =
               Coercion.coerce(~U[2026-05-03 09:14:00Z], :datetime, [])
    end

    test "naive ISO 8601 (no offset) is rejected" do
      assert {:error, msg} = Coercion.coerce("2026-05-03T09:14:00", :datetime, [])
      assert msg =~ "naive"
      assert msg =~ "timezone offset"
    end

    test "garbage string is rejected" do
      assert {:error, msg} = Coercion.coerce("not a date", :datetime, [])
      assert msg =~ "invalid datetime"
    end

    test "non-string non-DateTime is rejected with a hint" do
      assert {:error, msg} = Coercion.coerce(42, :datetime, [])
      assert msg =~ "ISO 8601"
      assert msg =~ "%DateTime{}"
    end

    test "%NaiveDateTime{} is rejected (use %DateTime{} or string with offset)" do
      assert {:error, msg} = Coercion.coerce(~N[2026-05-03 09:14:00], :datetime, [])
      assert msg =~ "ISO 8601"
    end
  end
end
