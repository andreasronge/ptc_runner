defmodule PtcRunner.SubAgent.Namespace.UserTest do
  use ExUnit.Case, async: true
  doctest PtcRunner.SubAgent.Namespace.User

  alias PtcRunner.SubAgent.Namespace.User

  describe "render/2" do
    test "returns nil for empty memory" do
      assert User.render(%{}, []) == nil
      assert User.render(%{}, has_println: true) == nil
    end

    test "returns nil when memory contains only uninformative values" do
      assert User.render(%{a: nil, b: [], c: %{}}, []) == nil
    end

    test "renders single function without return type" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      result = User.render(%{double: closure}, [])

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "(double [x])"
      refute result =~ "->"
    end

    test "renders single function with return type" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{return_type: "integer"}}
      result = User.render(%{double: closure}, [])

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "(double [x]) -> integer"
    end

    test "renders single value with sample when has_println is false" do
      result = User.render(%{total: 42}, [])

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "total"
      assert result =~ "; = integer, sample: 42"
    end

    test "renders single value without sample when has_println is true" do
      result = User.render(%{total: 42}, has_println: true)

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "total"
      assert result =~ "; = integer"
      refute result =~ "sample:"
    end

    test "renders functions first, then values (DEF-009)" do
      closure = {:closure, [{:var, :x}], nil, %{}, [], %{}}

      result = User.render(%{total: 42, double: closure}, [])

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "(double [x])"
      assert result =~ "total"

      # Functions appear before the untrusted envelope that wraps values
      fn_pos = :binary.match(result, "(double [x])") |> elem(0)
      val_pos = :binary.match(result, "total") |> elem(0)
      assert fn_pos < val_pos
    end

    test "sorts functions alphabetically" do
      closure_a = {:closure, [{:var, :x}], nil, %{}, [], %{}}
      closure_b = {:closure, [{:var, :y}], nil, %{}, [], %{}}

      result = User.render(%{zebra: closure_a, alpha: closure_b}, [])

      lines = String.split(result, "\n")
      assert Enum.at(lines, 1) =~ "(alpha [y])"
      assert Enum.at(lines, 2) =~ "(zebra [x])"
    end

    test "sorts values alphabetically" do
      result = User.render(%{zebra: 1, alpha: 2}, [])

      assert result =~ "alpha"
      assert result =~ "zebra"

      alpha_pos = :binary.match(result, "alpha") |> elem(0)
      zebra_pos = :binary.match(result, "zebra") |> elem(0)
      assert alpha_pos < zebra_pos
    end

    test "renders binary memory keys" do
      result = User.render(%{"counter" => 1, "_token" => "secret"}, [])

      assert result =~ "counter"
      assert result =~ "; = integer, sample: 1"
      assert result =~ "_token"
      assert result =~ "; = string, sample: \"secret\""
    end

    test "sorts mixed atom and binary memory keys by display name" do
      result = User.render(%{"alpha" => 2, zebra: 1}, [])

      assert result =~ "alpha"
      assert result =~ "zebra"

      alpha_pos = :binary.match(result, "alpha") |> elem(0)
      zebra_pos = :binary.match(result, "zebra") |> elem(0)
      assert alpha_pos < zebra_pos
    end

    test "renders binary function names and params" do
      closure = {:closure, [{:var, "x"}], nil, %{}, [], %{}}
      result = User.render(%{"my-fn" => closure}, [])

      assert result =~ "(my-fn [x])"
    end

    test "renders variadic function with rest params" do
      closure = {:closure, {:variadic, [], {:var, :args}}, nil, %{}, [], %{}}
      result = User.render(%{foo: closure}, [])

      assert result =~ "(foo [& args])"
    end

    test "renders variadic function with leading and rest params" do
      closure =
        {:closure, {:variadic, [{:var, :a}, {:var, :b}], {:var, :rest}}, nil, %{}, [], %{}}

      result = User.render(%{bar: closure}, [])

      assert result =~ "(bar [a b & rest])"
    end

    test "renders function with multiple params" do
      closure = {:closure, [{:var, :a}, {:var, :b}, {:var, :c}], nil, %{}, [], %{}}
      result = User.render(%{add: closure}, [])

      assert result =~ "(add [a b c])"
    end

    test "renders value with list type and truncated sample" do
      result = User.render(%{items: [1, 2, 3, 4, 5]}, [])

      assert result =~ "items"
      assert result =~ "list[5]"
      assert result =~ "sample: [1 2 3 ...] (3/5)"
    end

    test "renders value with map type" do
      result = User.render(%{config: %{a: 1, b: 2}}, [])

      assert result =~ "config"
      assert result =~ "map[2]"
      assert result =~ "sample: {:a 1 :b 2}"
    end

    test "filters out nil values (uninformative)" do
      result = User.render(%{nothing: nil, something: 42}, [])

      refute result =~ "nothing"
      assert result =~ "something"
      assert result =~ "42"
    end

    test "filters out empty list values (uninformative)" do
      result = User.render(%{empty: [], items: [1, 2]}, [])

      refute result =~ "empty"
      assert result =~ "items"
    end

    test "filters out empty map values (uninformative)" do
      result = User.render(%{empty: %{}, config: %{a: 1}}, [])

      refute result =~ "empty"
      assert result =~ "config"
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
          []
        )

      assert result =~ ";; === user/ (your prelude) ==="
      assert result =~ "(double [x]) -> integer"
      assert result =~ "(format_item [item])"
      assert result =~ "items"
      assert result =~ "total"

      # Functions appear before values
      fn_pos = :binary.match(result, "(double [x])") |> elem(0)
      val_pos = :binary.match(result, "items") |> elem(0)
      assert fn_pos < val_pos

      # Values wrapped in untrusted envelope
      assert result =~ "<untrusted_ptc_output source=\"memory\">"
    end

    test "renders value with underscore-prefixed name" do
      result = User.render(%{_secret: "token123"}, [])

      assert result =~ "_secret"
      assert result =~ "; = string, sample: \"token123\""
    end

    test "renders multiple underscore-prefixed values" do
      result = User.render(%{_key: "abc", _token: 42, visible: "data"}, [])

      assert result =~ "_key"
      assert result =~ "; = string, sample: \"abc\""
      assert result =~ "_token"
      assert result =~ "; = integer, sample: 42"
      assert result =~ "visible"
      assert result =~ "sample: \"data\""
    end

    test "omits samples for underscore-prefixed values with has_println true" do
      result = User.render(%{_secret: "token", normal: 5}, has_println: true)

      assert result =~ "_secret"
      assert result =~ "; = string"
      assert result =~ "normal"
      assert result =~ "; = integer"
      refute result =~ "sample:"
      refute result =~ "token"
    end
  end
end
