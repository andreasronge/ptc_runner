defmodule PtcRunner.Lisp.RuntimeInteropTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.Format

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
      assert msg =~ "Supported interop methods:"
      assert msg =~ ".getTime"
      assert msg =~ ".indexOf"
      assert msg =~ ".lastIndexOf"
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

  describe "java.time.LocalDate interop" do
    test "java.time.LocalDate/parse returns a Date" do
      {:ok, step} = Lisp.run("(java.time.LocalDate/parse \"2023-10-27\")")
      result = step.return
      assert %Date{} = result
      assert result.year == 2023
      assert result.month == 10
      assert result.day == 27
    end

    test "LocalDate/parse alias returns a Date" do
      {:ok, step} = Lisp.run("(LocalDate/parse \"2023-10-27\")")
      result = step.return
      assert %Date{} = result
    end

    test "LocalDate formatted output for feedback" do
      {:ok, step} = Lisp.run("(LocalDate/parse \"2023-10-27\")")
      {formatted, _} = Format.to_clojure(step.return)
      assert formatted == "\"2023-10-27\""
    end

    test "LocalDate/parse error on invalid date" do
      assert {:error, step} = Lisp.run("(LocalDate/parse \"not-a-date\")")
      assert step.fail.message =~ "LocalDate/parse: invalid date 'not-a-date'"
    end

    test "LocalDate/parse error on nil" do
      assert {:error, step} = Lisp.run("(LocalDate/parse nil)")
      assert step.fail.message =~ "LocalDate/parse: cannot parse nil"
    end
  end

  describe ".indexOf" do
    test "finds substring" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "hello" "ll")|)
      assert step.return == 2
    end

    test "returns -1 when not found" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "hello" "x")|)
      assert step.return == -1
    end

    test "with from-index" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "hello" "l" 3)|)
      assert step.return == 3
    end

    test "with from-index beyond match" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "hello" "l" 4)|)
      assert step.return == -1
    end

    test "with negative from-index treated as 0" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "hello" "h" -5)|)
      assert step.return == 0
    end

    test "error on non-string" do
      assert {:error, step} = Lisp.run("(.indexOf 123 \"x\")")
      assert step.fail.message =~ ".indexOf: expected string, got integer"
    end

    # Grapheme-based indexing tests (critical for multi-byte characters)
    test "returns grapheme index, not byte offset, for emoji" do
      # "🍎alt" - emoji is 1 grapheme but 4 bytes
      assert {:ok, step} = Lisp.run(~s|(.indexOf "🍎alt" "alt")|)
      assert step.return == 1
    end

    test "works with subs for multi-byte characters" do
      # The index returned should work correctly with subs
      assert {:ok, step} = Lisp.run(~s|(let [s "🍎alt"] (subs s (.indexOf s "alt")))|)
      assert step.return == "alt"
    end

    test "handles multiple emoji correctly" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "🍎🍊🍋fruit" "fruit")|)
      assert step.return == 3
    end

    # Empty substring tests (Java semantics)
    test "empty substring returns 0" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "hello" "")|)
      assert step.return == 0
    end

    test "empty substring with from-index returns min(from, length)" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "abc" "" 3)|)
      assert step.return == 3
    end

    test "empty substring with from-index beyond length returns length" do
      assert {:ok, step} = Lisp.run(~s|(.indexOf "abc" "" 10)|)
      assert step.return == 3
    end
  end

  describe ".lastIndexOf" do
    test "finds last occurrence" do
      assert {:ok, step} = Lisp.run(~s|(.lastIndexOf "hello" "l")|)
      assert step.return == 3
    end

    test "returns -1 when not found" do
      assert {:ok, step} = Lisp.run(~s|(.lastIndexOf "hello" "x")|)
      assert step.return == -1
    end

    test "error on non-string" do
      assert {:error, step} = Lisp.run("(.lastIndexOf [] \"x\")")
      assert step.fail.message =~ ".lastIndexOf: expected string, got list"
    end

    # Grapheme-based indexing tests
    test "returns grapheme index for emoji" do
      # "alt🍎alt" = a(0) l(1) t(2) 🍎(3) a(4) l(5) t(6)
      # Last "alt" starts at index 4
      assert {:ok, step} = Lisp.run(~s|(.lastIndexOf "alt🍎alt" "alt")|)
      assert step.return == 4
    end

    test "works with subs for multi-byte characters" do
      assert {:ok, step} = Lisp.run(~s|(let [s "🍎x🍊x"] (subs s (.lastIndexOf s "x")))|)
      assert step.return == "x"
    end

    # Empty substring tests (Java semantics)
    test "empty substring returns string length" do
      assert {:ok, step} = Lisp.run(~s|(.lastIndexOf "hello" "")|)
      assert step.return == 5
    end

    test "empty substring on empty string returns 0" do
      assert {:ok, step} = Lisp.run(~s|(.lastIndexOf "" "")|)
      assert step.return == 0
    end
  end
end
