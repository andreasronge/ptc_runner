defmodule PtcRunner.SubAgent.Namespace.UserTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.Namespace.User

  alias PtcRunner.SubAgent.Namespace.User

  describe "render/2" do
    test "returns nil for empty memory" do
      assert User.render(%{}, false) == nil
      assert User.render(%{}, true) == nil
    end

    test "renders single function without return type" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      result = User.render(%{double: closure}, false)

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "(double [x])"
      refute result =~ "->"
    end

    test "renders single function with return type" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{return_type: "integer"}}
      result = User.render(%{double: closure}, false)

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "(double [x]) -> integer"
    end

    test "renders single value with sample when has_println is false" do
      result = User.render(%{total: 42}, false)

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "total"
      assert result =~ "; = integer, sample: 42"
    end

    test "renders single value without sample when has_println is true" do
      result = User.render(%{total: 42}, true)

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "total"
      assert result =~ "; = integer"
      refute result =~ "sample:"
    end

    test "renders functions first, then values (DEF-009)" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}

      result = User.render(%{total: 42, double: closure}, false)

      lines = String.split(result, "\n")
      # First line is header
      assert Enum.at(lines, 0) == ";; === user/ (your prelude) ==="
      # Second line should be the function
      assert Enum.at(lines, 1) =~ "(double [x])"
      # Third line should be the value
      assert Enum.at(lines, 2) =~ "total"
    end

    test "sorts functions alphabetically" do
      closure_a = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      closure_b = {:closure, [{:var, :y}], nil, %{}, [], %{}}

      result = User.render(%{zebra: closure_a, alpha: closure_b}, false)

      lines = String.split(result, "\n")
      assert Enum.at(lines, 1) =~ "(alpha [y])"
      assert Enum.at(lines, 2) =~ "(zebra [x])"
    end

    test "sorts values alphabetically" do
      result = User.render(%{zebra: 1, alpha: 2}, false)

      lines = String.split(result, "\n")
      assert Enum.at(lines, 1) =~ "alpha"
      assert Enum.at(lines, 2) =~ "zebra"
    end

    test "renders variadic function with rest params" do
      closure = {:closure, {:variadic, [], {:var, :args}}, nil, %{}, [], %{}}
      result = User.render(%{foo: closure}, false)

      assert result =~ "(foo [& args])"
    end

    test "renders variadic function with leading and rest params" do
      closure =
        {:closure, {:variadic, [{:var, :a}, {:var, :b}], {:var, :rest}}, nil, %{}, [], %{}}

      result = User.render(%{bar: closure}, false)

      assert result =~ "(bar [a b & rest])"
    end

    test "renders function with multiple params" do
      closure = {:closure, [{:var, :a}, {:var, :b}, {:var, :c}], nil, %{}, [], %{}}
      result = User.render(%{add: closure}, false)

      assert result =~ "(add [a b c])"
    end

    test "renders value with list type and truncated sample" do
      result = User.render(%{items: [1, 2, 3, 4, 5]}, false)

      assert result =~ "items"
      assert result =~ "list[5]"
      assert result =~ "sample: [1 2 3 ...] (5 items, showing first 3)"
    end

    test "renders value with map type" do
      result = User.render(%{config: %{a: 1, b: 2}}, false)

      assert result =~ "config"
      assert result =~ "map[2]"
      assert result =~ "sample: {:a 1 :b 2}"
    end

    test "renders nil value" do
      result = User.render(%{nothing: nil}, false)

      assert result =~ "nothing"
      assert result =~ "; = nil, sample: nil"
    end

    test "renders empty list value" do
      result = User.render(%{empty: []}, false)

      assert result =~ "empty"
      assert result =~ "list[0]"
      assert result =~ "sample: []"
    end

    test "handles legacy 5-tuple closure" do
      closure = {:closure, [{:var, :x}], nil, %{}, []}
      result = User.render(%{legacy: closure}, false)

      assert result =~ "(legacy [x])"
      refute result =~ "->"
    end

    test "mixed functions and values" do
      closure1 = {:closure, [{:var, :x}], nil, %{}, [], %{return_type: "integer"}}
      closure2 = {:closure, [{:var, :item}], nil, %{}, [], %{}}

      result =
        User.render(
          %{
            double: closure1,
            format_item: closure2,
            items: [1, 2, 3, 4, 5],
            total: 100
          },
          false
        )

      lines = String.split(result, "\n")
      # Header
      assert Enum.at(lines, 0) == ";; === user/ (your prelude) ==="
      # Functions (alphabetical, first)
      assert Enum.at(lines, 1) =~ "(double [x]) -> integer"
      assert Enum.at(lines, 2) =~ "(format_item [item])"
      # Values (alphabetical, after functions)
      assert Enum.at(lines, 3) =~ "items"
      assert Enum.at(lines, 4) =~ "total"
    end
  end
end
