defmodule PtcRunner.Lisp.RuntimeBitwiseTest do
  use ExUnit.Case

  # Bitwise operations (#825). Values chosen to match Clojure/JVM exactly
  # (BEAM integers are arbitrary-precision two's-complement, which agrees
  # with the JVM for these inputs — see notes in priv/functions.exs).

  describe "bit-and / bit-or / bit-xor" do
    test "binary" do
      assert_lisp("(bit-and 12 10)", 8)
      assert_lisp("(bit-or 12 10)", 14)
      assert_lisp("(bit-xor 12 10)", 6)
    end

    test "variadic folds left-to-right" do
      assert_lisp("(bit-and 255 15 3)", 3)
      assert_lisp("(bit-or 1 2 4 8)", 15)
      assert_lisp("(bit-xor 1 2 4 8)", 15)
    end

    test "single argument returns itself" do
      assert_lisp("(bit-and 42)", 42)
      assert_lisp("(bit-or 42)", 42)
    end

    test "negative operands (two's complement)" do
      assert_lisp("(bit-and -1 7)", 7)
      assert_lisp("(bit-or -8 1)", -7)
    end
  end

  describe "bit-not / bit-and-not" do
    test "bit-not is two's-complement negation minus one" do
      assert_lisp("(bit-not 0)", -1)
      assert_lisp("(bit-not 5)", -6)
    end

    test "bit-and-not clears the bits set in subsequent args" do
      assert_lisp("(bit-and-not 255 15)", 240)
      assert_lisp("(bit-and-not 255 15 48)", 192)
    end
  end

  describe "bit-shift-left / bit-shift-right" do
    test "shift" do
      assert_lisp("(bit-shift-left 1 4)", 16)
      assert_lisp("(bit-shift-right 256 4)", 16)
    end

    test "right shift is arithmetic (sign-extending)" do
      assert_lisp("(bit-shift-right -16 2)", -4)
    end

    test "BEAM has no fixed width: left shift can grow past 64 bits" do
      assert_lisp("(bit-shift-left 1 64)", 18_446_744_073_709_551_616)
    end
  end

  describe "bit-set / bit-clear / bit-flip / bit-test" do
    test "set and clear" do
      assert_lisp("(bit-set 0 3)", 8)
      assert_lisp("(bit-clear 15 1)", 13)
    end

    test "flip toggles" do
      assert_lisp("(bit-flip 0 5)", 32)
      assert_lisp("(bit-flip 32 5)", 0)
    end

    test "test returns a boolean" do
      assert_lisp("(bit-test 8 3)", true)
      assert_lisp("(bit-test 8 2)", false)
    end
  end

  describe "type errors" do
    test "non-integer argument reports a clean PTC-Lisp error, not an Erlang ArithmeticError" do
      assert {:error, %{fail: %{message: msg}}} = PtcRunner.Lisp.run("(bit-and 5 2.5)")
      assert msg =~ "bit-and: expected an integer, got number 2.5"
      refute msg =~ "ArithmeticError"
    end

    test "negative shift amount is rejected" do
      assert {:error, %{fail: %{message: msg}}} = PtcRunner.Lisp.run("(bit-shift-left 1 -1)")
      assert msg =~ "non-negative integer"
    end
  end

  defp assert_lisp(source, expected) do
    {:ok, %{return: result}} = PtcRunner.Lisp.run(source)
    assert result == expected
  end
end
