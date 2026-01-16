defmodule PtcRunner.Lisp.Runtime.CallableTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime.Callable
  alias PtcRunner.Lisp.Runtime.Math

  describe "call/2 with plain functions" do
    test "calls function with args" do
      assert Callable.call(&Kernel.+/2, [1, 2]) == 3
    end

    test "calls unary function" do
      assert Callable.call(&abs/1, [-5]) == 5
    end
  end

  describe "call/2 with {:normal, fun}" do
    test "calls normal builtin" do
      normal = {:normal, &String.upcase/1}
      assert Callable.call(normal, ["hello"]) == "HELLO"
    end
  end

  describe "call/2 with {:variadic, fun2, identity}" do
    test "returns identity for empty args" do
      variadic = {:variadic, &Math.add/2, 0}
      assert Callable.call(variadic, []) == 0
    end

    test "returns element for single arg" do
      variadic = {:variadic, &Math.add/2, 0}
      assert Callable.call(variadic, [5]) == 5
    end

    test "applies binary function for two args" do
      variadic = {:variadic, &Math.add/2, 0}
      assert Callable.call(variadic, [1, 2]) == 3
    end

    test "reduces for multiple args" do
      variadic = {:variadic, &Math.add/2, 0}
      assert Callable.call(variadic, [1, 2, 3, 4]) == 10
    end

    test "handles unary minus (negation)" do
      variadic = {:variadic, &Math.subtract/2, 0}
      assert Callable.call(variadic, [5]) == -5
    end
  end

  describe "call/2 with {:variadic_nonempty, name, fun2}" do
    test "raises for empty args" do
      variadic = {:variadic_nonempty, "max", &max/2}

      assert_raise ArgumentError, ~r/requires at least 1 argument/, fn ->
        Callable.call(variadic, [])
      end
    end

    test "returns element for single arg" do
      variadic = {:variadic_nonempty, "max", &max/2}
      assert Callable.call(variadic, [5]) == 5
    end

    test "applies binary function for two args" do
      variadic = {:variadic_nonempty, "max", &max/2}
      assert Callable.call(variadic, [1, 5]) == 5
    end

    test "reduces for multiple args" do
      variadic = {:variadic_nonempty, "max", &max/2}
      assert Callable.call(variadic, [3, 1, 4, 1, 5]) == 5
    end
  end

  describe "call/2 with {:multi_arity, name, funs}" do
    test "selects correct function by arity" do
      # Simulating range which has arities 1, 2, 3
      range1 = fn n -> Enum.to_list(0..(n - 1)) end
      range2 = fn s, e -> Enum.to_list(s..(e - 1)) end
      range3 = fn s, e, step -> Enum.to_list(s..e//step) |> Enum.take_while(&(&1 < e)) end
      multi = {:multi_arity, "range", {range1, range2, range3}}

      assert Callable.call(multi, [3]) == [0, 1, 2]
      assert Callable.call(multi, [1, 4]) == [1, 2, 3]
      assert Callable.call(multi, [0, 6, 2]) == [0, 2, 4]
    end

    test "raises for invalid arity" do
      range1 = fn n -> Enum.to_list(0..(n - 1)) end
      multi = {:multi_arity, "range", {range1}}

      assert_raise ArgumentError, ~r/arity mismatch/, fn ->
        Callable.call(multi, [1, 2, 3, 4])
      end
    end
  end

  describe "call/2 with {:collect, fun}" do
    test "passes args as list to unary function" do
      collect = {:collect, fn args -> Enum.sum(args) end}
      assert Callable.call(collect, [1, 2, 3, 4, 5]) == 15
    end
  end
end
