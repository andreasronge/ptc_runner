defmodule PtcRunner.Lisp.RuntimeInteropTest do
  use ExUnit.Case, async: true
  alias PtcRunner.Lisp

  describe ".contains" do
    test "returns true when substring found" do
      assert {:ok, step} = Lisp.run(~s|(.contains "hello world" "world")|)
      assert step.return == true
    end

    test "returns false when substring not found" do
      assert {:ok, step} = Lisp.run(~s|(.contains "hello" "xyz")|)
      assert step.return == false
    end

    test "error on non-string" do
      assert {:error, step} = Lisp.run("(.contains 123 \"x\")")
      assert step.fail.message =~ ".contains: expected string, got integer"
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

  describe ".length" do
    test "returns grapheme count of a string" do
      assert {:ok, step} = Lisp.run(~s|(.length "hello")|)
      assert step.return == 5
    end

    test "returns 0 for empty string" do
      assert {:ok, step} = Lisp.run(~s|(.length "")|)
      assert step.return == 0
    end

    test "counts graphemes, not bytes (unicode)" do
      assert {:ok, step} = Lisp.run(~s|(.length "über")|)
      assert step.return == 4
    end

    test "error on non-string" do
      assert {:error, step} = Lisp.run("(.length 123)")
      assert step.fail.message =~ ".length: expected string, got integer"
    end
  end

  describe ".substring" do
    test "single-arg form returns suffix from start index" do
      assert {:ok, step} = Lisp.run(~s|(.substring "hello world" 6)|)
      assert step.return == "world"
    end

    test "two-arg form returns range [start, end)" do
      assert {:ok, step} = Lisp.run(~s|(.substring "hello world" 0 5)|)
      assert step.return == "hello"
    end

    test "two-arg form with mid-range" do
      assert {:ok, step} = Lisp.run(~s|(.substring "abcdef" 1 4)|)
      assert step.return == "bcd"
    end

    test "uses grapheme indices, not bytes" do
      assert {:ok, step} = Lisp.run(~s|(.substring "über" 1 3)|)
      assert step.return == "be"
    end

    test "error on non-string receiver" do
      assert {:error, step} = Lisp.run("(.substring 123 0 1)")
      assert step.fail.message =~ ".substring: expected string"
    end

    test "error on non-numeric start" do
      assert {:error, step} = Lisp.run(~s|(.substring "abc" "bad")|)
      assert step.fail.message =~ ".substring: expected numeric start, got string"
    end

    test "error on non-numeric two-arg indexes" do
      assert {:error, step} = Lisp.run(~s|(.substring "abc" "bad" 2)|)
      assert step.fail.message =~ ".substring: expected numeric start, got string"

      assert {:error, step} = Lisp.run(~s|(.substring "abc" 0 "bad")|)
      assert step.fail.message =~ ".substring: expected numeric stop, got string"
    end

    # Bounds-checking regression tests (Java StringIndexOutOfBoundsException semantics).
    # The .indexOf -> .substring chain is the canonical Java idiom; .indexOf returns
    # -1 on miss. Without bounds checking, (.substring s -1) silently returns the
    # last grapheme via Elixir's negative-index semantics — a quiet wrong answer.
    test "single-arg form: negative start raises (would silently return last grapheme)" do
      assert {:error, step} = Lisp.run(~s|(.substring "abcdef" -1)|)
      assert step.fail.message =~ ".substring"
      assert step.fail.message =~ "out of range"
    end

    test "single-arg form: start beyond length raises" do
      assert {:error, step} = Lisp.run(~s|(.substring "abc" 10)|)
      assert step.fail.message =~ ".substring"
      assert step.fail.message =~ "out of range"
    end

    test "single-arg form: start == length returns empty string (Java semantics)" do
      assert {:ok, step} = Lisp.run(~s|(.substring "abc" 3)|)
      assert step.return == ""
    end

    test "two-arg form: negative start raises" do
      assert {:error, step} = Lisp.run(~s|(.substring "abcdef" -1 3)|)
      assert step.fail.message =~ ".substring"
      assert step.fail.message =~ "out of range"
    end

    test "two-arg form: end > length raises" do
      assert {:error, step} = Lisp.run(~s|(.substring "abc" 0 10)|)
      assert step.fail.message =~ ".substring"
      assert step.fail.message =~ "out of range"
    end

    test "two-arg form: start > end raises (would silently return empty)" do
      assert {:error, step} = Lisp.run(~s|(.substring "abcdef" 4 2)|)
      assert step.fail.message =~ ".substring"
      assert step.fail.message =~ "out of range"
    end

    test "two-arg form: start == end returns empty string (Java semantics)" do
      assert {:ok, step} = Lisp.run(~s|(.substring "abc" 1 1)|)
      assert step.return == ""
    end

    test "two-arg form: end == length returns suffix (Java semantics)" do
      assert {:ok, step} = Lisp.run(~s|(.substring "abc" 1 3)|)
      assert step.return == "bc"
    end

    # The trap that motivated the bounds checks: indexOf miss feeding substring.
    test "indexOf miss feeding single-arg substring raises (does not silently return suffix)" do
      assert {:error, step} =
               Lisp.run(~s|(let [s "abcdef"] (.substring s (.indexOf s "xyz")))|)

      assert step.fail.message =~ ".substring"
      assert step.fail.message =~ "out of range"
    end
  end

  describe ".toLowerCase" do
    test "converts string to lower case" do
      assert {:ok, step} = Lisp.run(~s|(.toLowerCase "Hello World")|)
      assert step.return == "hello world"
    end

    test "already lowercase string unchanged" do
      assert {:ok, step} = Lisp.run(~s|(.toLowerCase "hello")|)
      assert step.return == "hello"
    end

    test "handles unicode" do
      assert {:ok, step} = Lisp.run(~s|(.toLowerCase "ÜBER")|)
      assert step.return == "über"
    end

    test "error on non-string" do
      assert {:error, step} = Lisp.run("(.toLowerCase 123)")
      assert step.fail.message =~ ".toLowerCase: expected string, got integer"
    end
  end

  describe ".toUpperCase" do
    test "converts string to upper case" do
      assert {:ok, step} = Lisp.run(~s|(.toUpperCase "Hello World")|)
      assert step.return == "HELLO WORLD"
    end

    test "already uppercase string unchanged" do
      assert {:ok, step} = Lisp.run(~s|(.toUpperCase "HELLO")|)
      assert step.return == "HELLO"
    end

    test "handles unicode" do
      assert {:ok, step} = Lisp.run(~s|(.toUpperCase "über")|)
      assert step.return == "ÜBER"
    end

    test "error on non-string" do
      assert {:error, step} = Lisp.run("(.toUpperCase 123)")
      assert step.fail.message =~ ".toUpperCase: expected string, got integer"
    end
  end

  describe ".startsWith" do
    test "returns true when string starts with prefix" do
      assert {:ok, step} = Lisp.run(~s|(.startsWith "hello world" "hello")|)
      assert step.return == true
    end

    test "returns false when string does not start with prefix" do
      assert {:ok, step} = Lisp.run(~s|(.startsWith "hello world" "world")|)
      assert step.return == false
    end

    test "empty prefix returns true" do
      assert {:ok, step} = Lisp.run(~s|(.startsWith "hello" "")|)
      assert step.return == true
    end

    test "handles unicode" do
      assert {:ok, step} = Lisp.run(~s|(.startsWith "über" "üb")|)
      assert step.return == true
    end

    test "error on non-string receiver" do
      assert {:error, step} = Lisp.run(~s|(.startsWith 123 "x")|)
      assert step.fail.message =~ ".startsWith: expected string, got integer"
    end

    test "error on non-string prefix" do
      assert {:error, step} = Lisp.run(~s|(.startsWith "hello" 123)|)
      assert step.fail.message =~ ".startsWith: expected string argument, got integer"
    end
  end

  describe ".endsWith" do
    test "returns true when string ends with suffix" do
      assert {:ok, step} = Lisp.run(~s|(.endsWith "hello world" "world")|)
      assert step.return == true
    end

    test "returns false when string does not end with suffix" do
      assert {:ok, step} = Lisp.run(~s|(.endsWith "hello world" "hello")|)
      assert step.return == false
    end

    test "empty suffix returns true" do
      assert {:ok, step} = Lisp.run(~s|(.endsWith "hello" "")|)
      assert step.return == true
    end

    test "handles unicode" do
      assert {:ok, step} = Lisp.run(~s|(.endsWith "über" "ber")|)
      assert step.return == true
    end

    test "error on non-string receiver" do
      assert {:error, step} = Lisp.run(~s|(.endsWith 123 "x")|)
      assert step.fail.message =~ ".endsWith: expected string, got integer"
    end

    test "error on non-string suffix" do
      assert {:error, step} = Lisp.run(~s|(.endsWith "hello" 123)|)
      assert step.fail.message =~ ".endsWith: expected string argument, got integer"
    end
  end
end
