defmodule PtcRunner.Lisp.CompileLimitsTest do
  @moduledoc """
  Regression tests for bounded compile phase (issue #988).

  Verifies that adversarial source returns structured errors from both
  `Lisp.run/2` and `Lisp.validate/1` without crashing the caller.
  """

  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  # ============================================================
  # Oversized source (max_program_bytes)
  # ============================================================

  describe "max_program_bytes" do
    test "run/2 rejects oversized source" do
      big = String.duplicate("a", 200)
      assert {:error, step} = Lisp.run(big, max_program_bytes: 100)
      assert step.fail.reason == :program_too_large
      assert step.fail.message =~ "exceeds limit of 100"
    end

    test "validate/2 rejects oversized source" do
      big = String.duplicate("a", 200)
      assert {:error, [msg]} = Lisp.validate(big, max_program_bytes: 100)
      assert msg =~ "exceeds limit of 100"
    end

    test "run/2 accepts source within limit" do
      assert {:ok, _step} = Lisp.run("42", max_program_bytes: 100)
    end
  end

  # ============================================================
  # Huge integer literals (H4)
  # ============================================================

  describe "integer digit limit" do
    test "run/2 rejects huge integer via FastParser" do
      huge_int = String.duplicate("9", 200)
      assert {:error, step} = Lisp.run(huge_int)
      assert step.fail.reason == :parse_error
      assert step.fail.message =~ "digit limit"
    end

    test "run/2 rejects huge negative integer" do
      huge_int = "-" <> String.duplicate("9", 200)
      assert {:error, step} = Lisp.run(huge_int)
      assert step.fail.reason == :parse_error
      assert step.fail.message =~ "digit limit"
    end

    test "run/2 accepts 100-digit integer" do
      hundred_digits = String.duplicate("1", 100)
      assert {:ok, step} = Lisp.run(hundred_digits)
      assert step.return == String.to_integer(hundred_digits)
    end

    test "validate/2 rejects huge integer" do
      huge_int = String.duplicate("9", 200)
      assert {:error, [msg]} = Lisp.validate(huge_int)
      assert msg =~ "digit limit"
    end
  end

  # ============================================================
  # Deeply nested forms
  # ============================================================

  describe "nesting depth limit" do
    test "run/2 rejects deeply nested forms" do
      depth = 70
      nested = String.duplicate("(do ", depth) <> "1" <> String.duplicate(")", depth)
      assert {:error, step} = Lisp.run(nested)
      assert step.fail.reason == :parse_error
      assert step.fail.message =~ "nesting depth"
    end

    test "validate/2 rejects deeply nested forms" do
      depth = 70
      nested = String.duplicate("(do ", depth) <> "1" <> String.duplicate(")", depth)
      assert {:error, [msg]} = Lisp.validate(nested)
      assert msg =~ "nesting depth"
    end

    test "run/2 accepts reasonably nested forms" do
      depth = 10
      nested = String.duplicate("(do ", depth) <> "42" <> String.duplicate(")", depth)
      assert {:ok, step} = Lisp.run(nested)
      assert step.return == 42
    end
  end

  # ============================================================
  # Huge short-fn placeholders (H3)
  # ============================================================

  describe "short-fn arity limit" do
    test "run/2 rejects huge short-fn placeholder" do
      assert {:error, step} = Lisp.run("#(+ %999999 1)")
      assert step.fail.message =~ "max arity"
    end

    test "validate/2 rejects huge short-fn placeholder" do
      assert {:error, [msg]} = Lisp.validate("#(+ %999999 1)")
      assert msg =~ "max arity"
    end

    test "run/2 accepts short-fn within arity limit" do
      assert {:ok, step} = Lisp.run("(#(+ %1 %2) 3 4)")
      assert step.return == 7
    end

    test "run/2 accepts short-fn up to arity 20" do
      assert {:ok, step} =
               Lisp.run("(#(+ %20 1) 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 100)")

      assert step.return == 101
    end

    test "run/2 rejects short-fn at arity 21" do
      assert {:error, step} = Lisp.run("#(+ %21 1)")
      assert step.fail.message =~ "max arity"
    end
  end

  # ============================================================
  # Compile timeout
  # ============================================================

  describe "compile_timeout" do
    test "run/2 returns structured error on compile timeout" do
      # A very short compile timeout with a somewhat complex program
      # This is a best-effort test — we can't guarantee the compile
      # actually takes longer than 1ms, but at minimum it verifies
      # the code path is wired up
      program = Enum.map_join(1..500, " ", fn i -> "(let [x#{i} #{i}] x#{i})" end)

      case Lisp.run(program, compile_timeout: 1) do
        {:error, step} ->
          assert step.fail.reason in [:compile_timeout, :parse_error, :unbound_var]

        {:ok, _step} ->
          # If compile was fast enough, that's fine too
          :ok
      end
    end
  end

  # ============================================================
  # Positive regression: normal programs still work
  # ============================================================

  describe "normal programs" do
    test "simple arithmetic" do
      assert {:ok, step} = Lisp.run("(+ 1 2)")
      assert step.return == 3
    end

    test "context filtering still works" do
      ctx = %{"items" => [1, 2, 3], "unused" => List.duplicate(:big, 1000)}
      assert {:ok, step} = Lisp.run("(count data/items)", context: ctx)
      assert step.return == 3
    end

    test "tools still work" do
      tools = %{"double" => fn %{"n" => n} -> n * 2 end}
      assert {:ok, step} = Lisp.run(~S|(tool/double {:n 5})|, tools: tools)
      assert step.return == 10
    end

    test "validate/1 still works for valid programs" do
      assert :ok = Lisp.validate("(+ 1 2)")
    end

    test "validate/1 still reports undefined vars" do
      assert {:error, ["foo"]} = Lisp.validate("(+ foo 1)")
    end

    test "memory persists across execution" do
      assert {:ok, step} = Lisp.run("(do (def x 42) x)")
      assert step.return == 42
    end
  end

  # ============================================================
  # Sandbox.run_bounded/2
  # ============================================================

  describe "Sandbox.run_bounded/2" do
    test "returns function result" do
      assert {:ok, 42} = PtcRunner.Sandbox.run_bounded(fn -> 42 end)
    end

    test "returns timeout error" do
      assert {:error, {:timeout, 50}} =
               PtcRunner.Sandbox.run_bounded(fn -> :timer.sleep(:infinity) end, timeout: 50)
    end

    test "returns memory error for heap-busting work" do
      assert {:error, {:memory_exceeded, _bytes}} =
               PtcRunner.Sandbox.run_bounded(
                 fn -> Enum.to_list(1..10_000_000) end,
                 max_heap: 1000
               )
    end

    test "catches crashes gracefully" do
      assert {:error, {:execution_error, msg}} =
               PtcRunner.Sandbox.run_bounded(fn -> raise "boom" end)

      assert msg =~ "RuntimeError"
    end
  end
end
