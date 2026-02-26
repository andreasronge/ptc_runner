defmodule PtcRunner.SubAgent.Namespace.DataTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.Namespace.Data

  alias PtcRunner.SubAgent.Namespace.Data

  describe "render/1" do
    test "returns nil for empty map" do
      assert Data.render(%{}) == nil
    end

    test "renders single entry with list" do
      result = Data.render(%{products: [%{id: 1}, %{id: 2}]})

      assert result =~ ";; === data/ ==="
      assert result =~ "data/products"
      assert result =~ "list[2]"
      assert result =~ "sample: [{:id 1} {:id 2}]"
    end

    test "renders string entry with type" do
      result = Data.render(%{name: "Alice"})

      assert result =~ "data/name"
      assert result =~ "string"
      assert result =~ ~s(sample: "Alice")
    end

    test "renders integer entry with type" do
      result = Data.render(%{count: 42})

      assert result =~ "data/count"
      assert result =~ "integer"
      assert result =~ "sample: 42"
    end

    test "renders map entry with type" do
      result = Data.render(%{config: %{a: 1, b: 2}})

      assert result =~ "data/config"
      assert result =~ "map[2]"
      assert result =~ "sample: {:a 1 :b 2}"
    end

    test "truncates large strings" do
      data = %{content: String.duplicate("x", 200)}
      result = Data.render(data)

      assert result =~ "data/content"
      assert result =~ "string"
      # Should be truncated due to printable_limit: 80
      assert result =~ "sample: \"xxx"
      assert result =~ "...\""
    end

    test "truncates large lists" do
      data = %{items: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]}
      result = Data.render(data)

      assert result =~ "data/items"
      assert result =~ "list[10]"
      # Should be truncated due to limit: 3
      assert result =~ "[1 2 3 ...] (10 items, showing first 3)"
    end

    test "sorts entries alphabetically" do
      data = %{zebra: 1, apple: 2, mango: 3}
      result = Data.render(data)

      lines = String.split(result, "\n")
      # First line is header
      assert Enum.at(lines, 0) == ";; === data/ ==="
      # Entries should be sorted
      assert Enum.at(lines, 1) =~ "data/apple"
      assert Enum.at(lines, 2) =~ "data/mango"
      assert Enum.at(lines, 3) =~ "data/zebra"
    end

    test "renders multiple entries" do
      data = %{users: [%{id: 1}], count: 100}
      result = Data.render(data)

      assert result =~ ";; === data/ ==="
      assert result =~ "data/count"
      assert result =~ "data/users"
    end
  end

  describe "closure rendering in data/" do
    test "renders closure with signature and docstring" do
      closure = {:closure, [{:var, :line}], nil, %{}, [], %{docstring: "Parse a log line"}}
      result = Data.render(%{mapper_fn: closure})
      assert result =~ "data/mapper_fn"
      assert result =~ "fn [line]"
      assert result =~ "Parse a log line"
    end

    test "renders closure without docstring" do
      closure = {:closure, [{:var, :a}, {:var, :b}], nil, %{}, [], %{}}
      result = Data.render(%{compare: closure})
      assert result =~ "fn [a b]"
      refute result =~ "--"
    end
  end
end
