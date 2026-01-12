defmodule PtcRunner.Lisp.FlexAccessTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Step

  describe "flex_fetch preserves nil values" do
    test "select-keys includes nil values" do
      program = ~S"(select-keys data/data [:a :b])"
      context = %{"data" => %{"a" => nil, "b" => 2}}

      assert {:ok, %Step{return: %{a: nil, b: 2}}} = PtcRunner.Lisp.run(program, context: context)
    end

    test "destructuring with :or does not replace nil" do
      program = ~S"(let [{:keys [a] :or {a 100}} data/data] a)"
      context = %{"data" => %{"a" => nil}}

      assert {:ok, %Step{return: nil}} = PtcRunner.Lisp.run(program, context: context)
    end

    test "destructuring with :or uses default for missing key" do
      program = ~S"(let [{:keys [a] :or {a 100}} data/data] a)"
      context = %{"data" => %{}}

      assert {:ok, %Step{return: 100}} = PtcRunner.Lisp.run(program, context: context)
    end

    test "keyword-as-function with default returns nil value" do
      program = ~s'(:a data/data "default")'
      context = %{"data" => %{"a" => nil}}

      assert {:ok, %Step{return: nil}} = PtcRunner.Lisp.run(program, context: context)
    end

    test "keyword-as-function with default uses default for missing" do
      program = ~s'(:a data/data "default")'
      context = %{"data" => %{}}

      assert {:ok, %Step{return: "default"}} = PtcRunner.Lisp.run(program, context: context)
    end
  end

  describe "flex_get_in consistency" do
    test "get-in works with string keys" do
      program = ~S"(get-in data/data [:user :name])"
      context = %{"data" => %{"user" => %{"name" => "Alice"}}}

      assert {:ok, %Step{return: "Alice"}} = PtcRunner.Lisp.run(program, context: context)
    end

    test "where clause path works with string keys" do
      program = ~S"(->> data/items (filter (where [:meta :active] = true)))"

      context = %{
        "items" => [
          %{"meta" => %{"active" => true}, "name" => "A"},
          %{"meta" => %{"active" => false}, "name" => "B"}
        ]
      }

      assert {:ok, %Step{return: [%{"meta" => %{"active" => true}, "name" => "A"}]}} =
               PtcRunner.Lisp.run(program, context: context)
    end
  end

  describe "where clause with keyword/string coercion" do
    test "where = coerces keyword to string for equality" do
      program = ~S"(->> data/items (filter (where :status = :active)))"

      context = %{
        "items" => [
          %{"status" => "active", "name" => "A"},
          %{"status" => "inactive", "name" => "B"}
        ]
      }

      assert {:ok, %Step{return: [%{"status" => "active", "name" => "A"}]}} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where not= with keyword/string coercion" do
      program = ~S"(->> data/items (filter (where :status not= :active)))"

      context = %{
        "items" => [
          %{"status" => "active", "name" => "A"},
          %{"status" => "inactive", "name" => "B"}
        ]
      }

      assert {:ok, %Step{return: [%{"status" => "inactive", "name" => "B"}]}} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where in coerces keywords in collection to strings" do
      program = ~S"(->> data/items (filter (where :status in [:active :pending])))"

      context = %{
        "items" => [
          %{"status" => "active", "name" => "A"},
          %{"status" => "inactive", "name" => "B"},
          %{"status" => "pending", "name" => "C"}
        ]
      }

      assert {:ok,
              %Step{
                return: [
                  %{"status" => "active", "name" => "A"},
                  %{"status" => "pending", "name" => "C"}
                ]
              }} = PtcRunner.Lisp.run(program, context: context)
    end

    test "where includes with list membership using keyword/string coercion" do
      program = ~S"(->> data/items (filter (where :tags includes :urgent)))"

      context = %{
        "items" => [
          %{"tags" => ["urgent", "bug"], "name" => "A"},
          %{"tags" => ["feature"], "name" => "B"}
        ]
      }

      assert {:ok, %Step{return: [%{"tags" => ["urgent", "bug"], "name" => "A"}]}} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where = does not coerce booleans" do
      program = ~S"(->> data/items (filter (where :active = true)))"

      context = %{
        "items" => [
          %{"active" => true, "name" => "A"},
          %{"active" => "true", "name" => "B"}
        ]
      }

      # Only the boolean true should match, not the string "true"
      assert {:ok, %Step{return: [%{"active" => true, "name" => "A"}]}} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where = does not coerce false to string" do
      program = ~S"(->> data/items (filter (where :active = false)))"

      context = %{
        "items" => [
          %{"active" => false, "name" => "A"},
          %{"active" => "false", "name" => "B"}
        ]
      }

      # Only the boolean false should match, not the string "false"
      assert {:ok, %Step{return: [%{"active" => false, "name" => "A"}]}} =
               PtcRunner.Lisp.run(program, context: context)
    end

    test "where = coerces empty atom to empty string" do
      program = ~S'(->> data/items (filter (where :value = "")))'

      context = %{
        "items" => [
          %{"value" => "", "name" => "A"},
          %{"value" => "nonempty", "name" => "B"}
        ]
      }

      assert {:ok, %Step{return: [%{"value" => "", "name" => "A"}]}} =
               PtcRunner.Lisp.run(program, context: context)
    end
  end
end
