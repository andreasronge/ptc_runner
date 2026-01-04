defmodule PtcRunner.Lisp.FormatTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Format

  doctest PtcRunner.Lisp.Format

  describe "to_string/2 with closures" do
    test "formats closure with single parameter" do
      closure = {:closure, [{:var, :x}], nil, %{}, []}
      assert Format.to_string(closure) == "#fn[x]"
    end

    test "formats closure with multiple parameters" do
      closure = {:closure, [{:var, :x}, {:var, :y}, {:var, :z}], nil, %{}, []}
      assert Format.to_string(closure) == "#fn[x y z]"
    end

    test "formats zero-param closure" do
      closure = {:closure, [], nil, %{}, []}
      assert Format.to_string(closure) == "#fn[]"
    end

    test "formats closure with destructuring pattern as underscore" do
      closure = {:closure, [{:destructure, {:keys, [:a, :b], []}}], nil, %{}, []}
      assert Format.to_string(closure) == "#fn[_]"
    end
  end

  describe "to_string/2 with builtins" do
    test "formats :normal builtin" do
      assert Format.to_string({:normal, &Enum.map/2}) == "#<builtin>"
    end

    test "formats :variadic builtin" do
      assert Format.to_string({:variadic, &Kernel.+/2, 0}) == "#<builtin>"
    end

    test "formats :variadic_nonempty builtin" do
      assert Format.to_string({:variadic_nonempty, &Kernel.//2}) == "#<builtin>"
    end

    test "formats :multi_arity builtin" do
      assert Format.to_string({:multi_arity, {&String.slice/2, &String.slice/3}}) == "#<builtin>"
    end
  end

  describe "to_string/2 with regular values" do
    test "formats integers" do
      assert Format.to_string(42) == "42"
    end

    test "formats strings" do
      assert Format.to_string("hello") == ~s("hello")
    end

    test "formats maps" do
      assert Format.to_string(%{a: 1}) == "%{a: 1}"
    end

    test "formats lists" do
      assert Format.to_string([1, 2, 3]) == "[1, 2, 3]"
    end

    test "formats nil" do
      assert Format.to_string(nil) == "nil"
    end

    test "formats atoms" do
      assert Format.to_string(:foo) == ":foo"
    end
  end

  describe "to_string/2 with nested values" do
    test "formats closure nested in map" do
      closure = {:closure, [{:var, :x}], nil, %{}, []}
      assert Format.to_string(%{f: closure}) == "%{f: #fn[x]}"
    end

    test "formats closure nested in list" do
      closure = {:closure, [{:var, :x}], nil, %{}, []}
      assert Format.to_string([1, closure, 3]) == "[1, #fn[x], 3]"
    end

    test "formats builtin nested in map" do
      assert Format.to_string(%{add: {:variadic, &Kernel.+/2, 0}}) == "%{add: #<builtin>}"
    end

    test "formats deeply nested closures" do
      closure = {:closure, [{:var, :n}], nil, %{}, []}
      result = Format.to_string(%{outer: %{inner: closure}})
      assert result =~ "#fn[n]"
    end
  end

  describe "to_string/2 with vars" do
    test "formats simple var" do
      assert Format.to_string({:var, :x}) == "#'x"
    end

    test "formats var with question mark" do
      assert Format.to_string({:var, :suspicious?}) == "#'suspicious?"
    end

    test "formats var nested in map" do
      assert Format.to_string(%{result: {:var, :foo}}) == "%{result: #'foo}"
    end

    test "formats var nested in list" do
      assert Format.to_string([{:var, :a}, {:var, :b}]) == "[#'a, #'b]"
    end
  end

  describe "to_clojure/2 with vars" do
    test "formats simple var" do
      assert Format.to_clojure({:var, :x}) == "#'x"
    end

    test "formats var with question mark" do
      assert Format.to_clojure({:var, :suspicious?}) == "#'suspicious?"
    end

    test "formats var nested in list" do
      assert Format.to_clojure([{:var, :x}, {:var, :y}]) == "[#'x #'y]"
    end

    test "formats var nested in map" do
      assert Format.to_clojure(%{result: {:var, :foo}}) == "{:result #'foo}"
    end
  end

  describe "to_string/2 with options" do
    test "respects limit option" do
      assert Format.to_string([1, 2, 3, 4, 5], limit: 2) == "[1, 2, ...]"
    end

    test "respects pretty option" do
      # Pretty printing affects formatting but result should still be valid
      result = Format.to_string(%{a: 1, b: 2}, pretty: true)
      assert result =~ "a:"
      assert result =~ "b:"
    end

    test "options are ignored for closures" do
      closure = {:closure, [{:var, :x}], nil, %{}, []}
      assert Format.to_string(closure, pretty: true, limit: 5) == "#fn[x]"
    end

    test "options are ignored for builtins" do
      assert Format.to_string({:normal, &Enum.map/2}, pretty: true) == "#<builtin>"
    end
  end
end
