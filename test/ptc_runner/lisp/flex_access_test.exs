defmodule PtcRunner.Lisp.FlexAccessTest do
  use ExUnit.Case, async: true

  describe "flex_fetch preserves nil values" do
    test "select-keys includes nil values" do
      program = ~S"(select-keys ctx/data [:a :b])"
      context = %{"data" => %{"a" => nil, "b" => 2}}

      assert {:ok, %{a: nil, b: 2}, _, _} = PtcRunner.Lisp.run(program, context: context)
    end

    test "destructuring with :or does not replace nil" do
      program = ~S"(let [{:keys [a] :or {:a 100}} ctx/data] a)"
      context = %{"data" => %{"a" => nil}}

      assert {:ok, nil, _, _} = PtcRunner.Lisp.run(program, context: context)
    end

    test "destructuring with :or uses default for missing key" do
      program = ~S"(let [{:keys [a] :or {:a 100}} ctx/data] a)"
      context = %{"data" => %{}}

      assert {:ok, 100, _, _} = PtcRunner.Lisp.run(program, context: context)
    end

    test "keyword-as-function with default returns nil value" do
      program = ~s'(:a ctx/data "default")'
      context = %{"data" => %{"a" => nil}}

      assert {:ok, nil, _, _} = PtcRunner.Lisp.run(program, context: context)
    end

    test "keyword-as-function with default uses default for missing" do
      program = ~s'(:a ctx/data "default")'
      context = %{"data" => %{}}

      assert {:ok, "default", _, _} = PtcRunner.Lisp.run(program, context: context)
    end
  end

  describe "flex_get_in consistency" do
    test "get-in works with string keys" do
      program = ~S"(get-in ctx/data [:user :name])"
      context = %{"data" => %{"user" => %{"name" => "Alice"}}}

      assert {:ok, "Alice", _, _} = PtcRunner.Lisp.run(program, context: context)
    end

    test "where clause path works with string keys" do
      program = ~S"(->> ctx/items (filter (where [:meta :active] = true)))"

      context = %{
        "items" => [
          %{"meta" => %{"active" => true}, "name" => "A"},
          %{"meta" => %{"active" => false}, "name" => "B"}
        ]
      }

      assert {:ok, [%{"meta" => %{"active" => true}, "name" => "A"}], _, _} =
               PtcRunner.Lisp.run(program, context: context)
    end
  end

  describe "where clause with keyword/string coercion" do
    test "where = coerces keyword to string for equality" do
      program = ~S"(->> ctx/items (filter (where :status = :active)))"

      context = %{
        "items" => [
          %{"status" => "active", "name" => "A"},
          %{"status" => "inactive", "name" => "B"}
        ]
      }

      assert {:ok, [%{"status" => "active", "name" => "A"}], _, _} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where not= with keyword/string coercion" do
      program = ~S"(->> ctx/items (filter (where :status not= :active)))"

      context = %{
        "items" => [
          %{"status" => "active", "name" => "A"},
          %{"status" => "inactive", "name" => "B"}
        ]
      }

      assert {:ok, [%{"status" => "inactive", "name" => "B"}], _, _} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where in coerces keywords in collection to strings" do
      program = ~S"(->> ctx/items (filter (where :status in [:active :pending])))"

      context = %{
        "items" => [
          %{"status" => "active", "name" => "A"},
          %{"status" => "inactive", "name" => "B"},
          %{"status" => "pending", "name" => "C"}
        ]
      }

      assert {:ok,
              [%{"status" => "active", "name" => "A"}, %{"status" => "pending", "name" => "C"}],
              _, _} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where includes with list membership using keyword/string coercion" do
      program = ~S"(->> ctx/items (filter (where :tags includes :urgent)))"

      context = %{
        "items" => [
          %{"tags" => ["urgent", "bug"], "name" => "A"},
          %{"tags" => ["feature"], "name" => "B"}
        ]
      }

      assert {:ok, [%{"tags" => ["urgent", "bug"], "name" => "A"}], _, _} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where = does not coerce booleans" do
      program = ~S"(->> ctx/items (filter (where :active = true)))"

      context = %{
        "items" => [
          %{"active" => true, "name" => "A"},
          %{"active" => "true", "name" => "B"}
        ]
      }

      # Only the boolean true should match, not the string "true"
      assert {:ok, [%{"active" => true, "name" => "A"}], _, _} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where = does not coerce false to string" do
      program = ~S"(->> ctx/items (filter (where :active = false)))"

      context = %{
        "items" => [
          %{"active" => false, "name" => "A"},
          %{"active" => "false", "name" => "B"}
        ]
      }

      # Only the boolean false should match, not the string "false"
      assert {:ok, [%{"active" => false, "name" => "A"}], _, _} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where = coerces empty atom to empty string" do
      program = ~S'(->> ctx/items (filter (where :value = "")))'

      context = %{
        "items" => [
          %{"value" => "", "name" => "A"},
          %{"value" => "nonempty", "name" => "B"}
        ]
      }

      assert {:ok, [%{"value" => "", "name" => "A"}], _, _} =
               PtcRunner.Lisp.run(program, context: context)
    end
  end
end
