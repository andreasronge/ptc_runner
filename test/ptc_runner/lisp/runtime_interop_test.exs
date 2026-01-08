defmodule PtcRunner.Lisp.RuntimeInteropTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  describe "java.util.Date interop" do
    test "java.util.Date. with timestamp (ms) returns a DateTime" do
      {:ok, step} = Lisp.run("(java.util.Date. 1767860276937)")
      result = step.return
      assert %DateTime{} = result
      assert DateTime.to_unix(result, :millisecond) == 1_767_860_276_937
    end

    test "java.util.Date. with timestamp (seconds) returns a DateTime" do
      # 1000000000 is year 2001, which is < 1 trillion, so assumed as seconds
      {:ok, step} = Lisp.run("(java.util.Date. 1000000000)")
      result = step.return
      assert %DateTime{} = result
      assert DateTime.to_unix(result, :second) == 1_000_000_000
    end

    test "java.util.Date. with negative timestamp" do
      # -1000000000 is before 1970, treated as seconds
      {:ok, step} = Lisp.run("(java.util.Date. -1000000000)")
      result = step.return
      assert %DateTime{} = result
      assert DateTime.to_unix(result, :second) == -1_000_000_000
    end

    test "java.util.Date. with no-arg constructor" do
      {:ok, step} = Lisp.run("(java.util.Date.)")
      result = step.return
      assert %DateTime{} = result
      # Close enough to now
      now = DateTime.utc_now()
      assert abs(DateTime.diff(result, now, :second)) < 5
    end

    test "java.util.Date. with ISO-8601 string" do
      {:ok, step} = Lisp.run("(java.util.Date. \"2026-01-08T14:30:00Z\")")
      result = step.return
      assert %DateTime{} = result
      assert result.year == 2026
      assert result.month == 1
      assert result.day == 8
      assert result.hour == 14
    end

    test "java.util.Date. with Date-only string" do
      {:ok, step} = Lisp.run("(java.util.Date. \"2026-01-08\")")
      result = step.return
      assert %DateTime{} = result
      assert result.year == 2026
      assert result.hour == 0
      assert result.minute == 0
    end

    test "java.util.Date. with RFC 2822 string" do
      {:ok, step} = Lisp.run("(java.util.Date. \"Wed, 8 Jan 2026 14:30:00 +0000\")")
      result = step.return
      assert %DateTime{} = result
      assert result.year == 2026
      assert result.month == 1
      assert result.day == 8
      assert result.hour == 14
    end

    test "java.util.Date. with RFC 2822 string without timezone" do
      {:ok, step} = Lisp.run("(java.util.Date. \"Wed, 8 Jan 2026 14:30:00\")")
      result = step.return
      assert %DateTime{} = result
      assert result.hour == 14
    end

    test "System/currentTimeMillis returns current time in ms" do
      {:ok, step} = Lisp.run("(System/currentTimeMillis)")
      result = step.return
      assert is_integer(result)
      now_ms = System.system_time(:millisecond)
      assert abs(result - now_ms) < 2000
    end

    test "error on unsupported (. obj method) syntax" do
      assert {:error, step} = Lisp.run("(. date getTime)")
      msg = step.fail.message
      assert msg =~ "(. obj method) syntax is not supported"
    end

    test "hint on unknown method call" do
      assert {:error, step} = Lisp.run("(.toString date)")
      msg = step.fail.message
      assert msg =~ "Unknown method '.toString'"

      assert msg =~
               "Supported interop methods: java.util.Date., .getTime, System/currentTimeMillis"
    end

    test "Runtime error on nil in .getTime (raised exception)" do
      assert {:error, step} = Lisp.run("(.getTime nil)")
      assert step.fail.message =~ "expected DateTime, got nil"
    end

    test "Runtime error on invalid string in java.util.Date." do
      assert {:error, step} = Lisp.run("(java.util.Date. \"not-a-date\")")
      assert step.fail.message =~ "cannot parse 'not-a-date'"
    end
  end
end
