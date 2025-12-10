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
end
