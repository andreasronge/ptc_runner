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
      assert {:error, step} = Lisp.run("(.toString data/date)", context: %{date: "2024-01-01"})
      msg = step.fail.message
      assert msg =~ "Unsupported method"
      assert msg =~ "Supported interop methods:"
      assert msg =~ ".getTime"
      assert msg =~ ".indexOf"
      assert msg =~ ".lastIndexOf"
      assert msg =~ ".toLowerCase"
      assert msg =~ ".toUpperCase"
    end

    # Issue #878: the error used to be wrapped in :unbound_var with a
    # pre-formatted message, then run through format_closure_error which
    # treated the message as a variable name and tried to suggest replacing
    # underscores with hyphens. That produced (a) the wrong "undefined
    # variable:" prefix, (b) duplicated text inside a "(try: ...)" block,
    # and (c) an irrelevant hyphenation hint.
    test "unsupported method error: no 'undefined variable' prefix, no duplicated text, no hyphen hint" do
      assert {:error, step} = Lisp.run("(.unknownMethod \"hello\")")
      msg = step.fail.message

      refute msg =~ "undefined variable",
             "method-call error should not be framed as an undefined variable: #{inspect(msg)}"

      refute msg =~ "Hint: Use hyphens",
             "method names don't have underscores; hyphen hint is irrelevant: #{inspect(msg)}"

      refute msg =~ "(try:",
             "duplicated text inside (try: ...) block: #{inspect(msg)}"

      # The supported-list should appear exactly once.
      occurrences = msg |> String.split("Supported interop methods:") |> length() |> Kernel.-(1)
      assert occurrences == 1, "expected 'Supported interop methods:' once, got #{occurrences}"
    end

    test "unsupported method error: reason atom is :unsupported_method (not :unbound_var)" do
      assert {:error, step} = Lisp.run("(.unknownMethod \"hello\")")
      assert step.fail.reason == :unsupported_method
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
      assert step.fail.message =~ "parse: invalid ISO-8601 date 'not-a-date'"
    end

    test "LocalDate/parse error on nil" do
      assert {:error, step} = Lisp.run("(LocalDate/parse nil)")
      assert step.fail.message =~ "parse: cannot parse nil"
    end

    test ".toEpochDay returns Java-compatible epoch day" do
      assert {:ok, %{return: 0}} = Lisp.run(~s|(.toEpochDay (LocalDate/parse "1970-01-01"))|)
      assert {:ok, %{return: 1}} = Lisp.run(~s|(.toEpochDay (LocalDate/parse "1970-01-02"))|)
      assert {:ok, %{return: -1}} = Lisp.run(~s|(.toEpochDay (LocalDate/parse "1969-12-31"))|)
    end

    test "day differences can be computed from epoch days" do
      source = ~s|
        (- (.toEpochDay (LocalDate/parse "2026-05-29"))
           (.toEpochDay (LocalDate/parse "2026-05-22")))
      |

      assert {:ok, %{return: 7}} = Lisp.run(source)
    end

    test ".plusDays and .minusDays return shifted LocalDate values" do
      assert {:ok, %{return: ~D[2026-05-29]}} =
               Lisp.run(~s|(.plusDays (LocalDate/parse "2026-05-22") 7)|)

      assert {:ok, %{return: ~D[2026-05-15]}} =
               Lisp.run(~s|(.minusDays (LocalDate/parse "2026-05-22") 7)|)
    end

    test "LocalDate arithmetic rejects wrong receiver and day argument types" do
      assert {:error, step} = Lisp.run(~s|(.toEpochDay (Instant/parse "2026-05-22T00:00:00Z"))|)
      assert step.fail.message =~ ".toEpochDay: expected LocalDate, got DateTime"

      assert {:error, step} = Lisp.run(~s|(.plusDays (LocalDate/parse "2026-05-22") "7")|)
      assert step.fail.message =~ ".plusDays: expected integer days, got string"

      assert {:error, step} = Lisp.run(~s|(.minusDays "2026-05-22" 7)|)
      assert step.fail.message =~ ".minusDays: expected LocalDate, got string"
    end
  end

  describe "ISO-8601 instant parsing (#885)" do
    test "parse returns a DateTime for an instant string with offset Z" do
      {:ok, step} = Lisp.run(~s|(parse "2026-01-01T00:00:00Z")|)
      assert %DateTime{} = step.return
      assert step.return.year == 2026
      assert step.return.time_zone == "Etc/UTC"
    end

    test "Instant/parse namespace alias also works" do
      {:ok, step} = Lisp.run(~s|(Instant/parse "2026-03-04T12:30:00Z")|)
      assert %DateTime{} = step.return
      assert step.return.month == 3
      assert step.return.day == 4
    end

    test "numeric offset is honoured (result is UTC)" do
      {:ok, step} = Lisp.run(~s|(parse "2026-01-01T02:00:00+02:00")|)
      assert %DateTime{} = step.return
      assert step.return.hour == 0
    end

    test "offsetless date-time is treated as UTC" do
      {:ok, step} = Lisp.run(~s|(parse "2026-01-01T08:15:00")|)
      assert %DateTime{} = step.return
      assert step.return.hour == 8
      assert step.return.time_zone == "Etc/UTC"
    end

    test "bare YYYY-MM-DD still returns a Date" do
      {:ok, step} = Lisp.run(~s|(parse "2026-01-01")|)
      assert %Date{} = step.return
    end

    test "the parsed DateTime works with comparison interop" do
      {:ok, step} =
        Lisp.run(~s|(.isBefore (parse "2026-01-01T00:00:00Z") (parse "2026-12-31T00:00:00Z"))|)

      assert step.return == true
    end

    test "invalid instant string raises a clean error" do
      assert {:error, step} = Lisp.run(~s|(parse "2026-13-99T00:00:00Z")|)
      assert step.fail.message =~ "parse: invalid ISO-8601 date/time"
    end
  end

  describe "java.time.Duration interop" do
    test "Duration/between returns a duration usable with .toMillis" do
      source = ~s|
        (.toMillis
          (Duration/between
            (Instant/parse "2026-05-01T00:00:00Z")
            (Instant/parse "2026-05-22T00:00:00Z")))
      |

      assert {:ok, %{return: 1_814_400_000}} = Lisp.run(source)
    end

    test "java.time.Duration/between also works" do
      source = ~s|
        (.toMillis
          (java.time.Duration/between
            (Instant/parse "2026-05-22T00:00:00Z")
            (Instant/parse "2026-05-22T00:00:01Z")))
      |

      assert {:ok, %{return: 1000}} = Lisp.run(source)
    end

    test ".toDays returns whole days and truncates partial days toward zero" do
      assert {:ok, %{return: 2}} =
               Lisp.run(
                 ~s|(.toDays (Duration/between (Instant/parse "2026-05-01T00:00:00Z") (Instant/parse "2026-05-03T12:00:00Z")))|
               )

      assert {:ok, %{return: 0}} =
               Lisp.run(
                 ~s|(.toDays (Duration/between (Instant/parse "2026-05-03T00:00:00Z") (Instant/parse "2026-05-02T12:00:00Z")))|
               )

      assert {:ok, %{return: -2}} =
               Lisp.run(
                 ~s|(.toDays (Duration/between (Instant/parse "2026-05-04T12:00:00Z") (Instant/parse "2026-05-02T00:00:00Z")))|
               )
    end

    test "negative durations preserve sign in milliseconds" do
      source = ~s|
        (.toMillis
          (Duration/between
            (Instant/parse "2026-05-22T00:00:01Z")
            (Instant/parse "2026-05-22T00:00:00Z")))
      |

      assert {:ok, %{return: -1000}} = Lisp.run(source)
    end

    test "direct Duration display is readable and not an Elixir struct" do
      {:ok, step} =
        Lisp.run(
          ~s|(Duration/between (Instant/parse "2026-05-22T00:00:00Z") (Instant/parse "2026-05-22T00:00:01Z"))|
        )

      assert Format.to_clojure(step.return) == {"#duration[1000ms]", false}

      assert {:ok, %{return: "#duration[1000ms]"}} =
               Lisp.run(
                 ~s|(str (Duration/between (Instant/parse "2026-05-22T00:00:00Z") (Instant/parse "2026-05-22T00:00:01Z")))|
               )
    end

    test "Duration/between rejects LocalDate values and .toMillis/.toDays reject non-durations" do
      assert {:error, step} =
               Lisp.run(
                 ~s|(Duration/between (LocalDate/parse "2026-05-01") (LocalDate/parse "2026-05-02"))|
               )

      assert step.fail.message =~
               "Duration/between: expected DateTime start argument, got LocalDate"

      assert {:error, step} = Lisp.run(~s|(.toMillis (Instant/parse "2026-05-22T00:00:00Z"))|)
      assert step.fail.message =~ ".toMillis: expected Duration, got DateTime"

      assert {:error, step} = Lisp.run(~s|(.toDays nil)|)
      assert step.fail.message =~ ".toDays: expected Duration, got nil"
    end
  end

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

  describe ".isBefore" do
    test "Date: earlier is before later" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isBefore (LocalDate/parse "2023-01-01") (LocalDate/parse "2023-12-31"))|
               )

      assert step.return == true
    end

    test "Date: later is not before earlier" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isBefore (LocalDate/parse "2023-12-31") (LocalDate/parse "2023-01-01"))|
               )

      assert step.return == false
    end

    test "Date: equal dates return false" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isBefore (LocalDate/parse "2023-06-15") (LocalDate/parse "2023-06-15"))|
               )

      assert step.return == false
    end

    test "DateTime: earlier is before later" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isBefore (java.util.Date. "2023-01-01T00:00:00Z") (java.util.Date. "2023-12-31T00:00:00Z"))|
               )

      assert step.return == true
    end

    test "DateTime: equal datetimes return false" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isBefore (java.util.Date. "2023-06-15T12:00:00Z") (java.util.Date. "2023-06-15T12:00:00Z"))|
               )

      assert step.return == false
    end

    test "error: mixed Date and DateTime" do
      assert {:error, step} =
               Lisp.run(
                 ~s|(.isBefore (LocalDate/parse "2023-01-01") (java.util.Date. "2023-01-01T00:00:00Z"))|
               )

      assert step.fail.message =~ "cannot compare LocalDate with DateTime"
    end

    test "error: mixed DateTime and Date" do
      assert {:error, step} =
               Lisp.run(
                 ~s|(.isBefore (java.util.Date. "2023-01-01T00:00:00Z") (LocalDate/parse "2023-01-01"))|
               )

      assert step.fail.message =~ "cannot compare DateTime with LocalDate"
    end

    test "error: non-date receiver" do
      assert {:error, step} = Lisp.run(~s|(.isBefore "2023-01-01" "2023-12-31")|)
      assert step.fail.message =~ ".isBefore: expected LocalDate or DateTime, got string"
    end

    test "error: nil receiver" do
      assert {:error, step} = Lisp.run(~s|(.isBefore nil (LocalDate/parse "2023-01-01"))|)
      assert step.fail.message =~ ".isBefore: expected LocalDate or DateTime, got nil"
    end

    test "error: integer receiver" do
      assert {:error, step} = Lisp.run(~s|(.isBefore 123 456)|)
      assert step.fail.message =~ ".isBefore: expected LocalDate or DateTime, got integer"
    end

    test "error: valid Date receiver with invalid argument" do
      assert {:error, step} =
               Lisp.run(~s|(.isBefore (LocalDate/parse "2023-01-01") "2023-12-31")|)

      assert step.fail.message =~ ".isBefore: expected LocalDate argument, got string"
    end

    test "error: valid DateTime receiver with nil argument" do
      assert {:error, step} =
               Lisp.run(~s|(.isBefore (java.util.Date. "2023-01-01T00:00:00Z") nil)|)

      assert step.fail.message =~ ".isBefore: expected DateTime argument, got nil"
    end
  end

  describe ".isAfter" do
    test "Date: later is after earlier" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isAfter (LocalDate/parse "2023-12-31") (LocalDate/parse "2023-01-01"))|
               )

      assert step.return == true
    end

    test "Date: earlier is not after later" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isAfter (LocalDate/parse "2023-01-01") (LocalDate/parse "2023-12-31"))|
               )

      assert step.return == false
    end

    test "Date: equal dates return false" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isAfter (LocalDate/parse "2023-06-15") (LocalDate/parse "2023-06-15"))|
               )

      assert step.return == false
    end

    test "DateTime: later is after earlier" do
      assert {:ok, step} =
               Lisp.run(
                 ~s|(.isAfter (java.util.Date. "2023-12-31T00:00:00Z") (java.util.Date. "2023-01-01T00:00:00Z"))|
               )

      assert step.return == true
    end

    test "error: mixed types rejected" do
      assert {:error, step} =
               Lisp.run(
                 ~s|(.isAfter (LocalDate/parse "2023-01-01") (java.util.Date. "2023-01-01T00:00:00Z"))|
               )

      assert step.fail.message =~ "cannot compare LocalDate with DateTime"
    end

    test "error: integer receiver" do
      assert {:error, step} = Lisp.run(~s|(.isAfter 123 456)|)
      assert step.fail.message =~ ".isAfter: expected LocalDate or DateTime, got integer"
    end

    test "error: valid Date receiver with integer argument" do
      assert {:error, step} = Lisp.run(~s|(.isAfter (LocalDate/parse "2023-01-01") 123)|)
      assert step.fail.message =~ ".isAfter: expected LocalDate argument, got integer"
    end

    test "error: valid DateTime receiver with string argument" do
      assert {:error, step} =
               Lisp.run(~s|(.isAfter (java.util.Date. "2023-01-01T00:00:00Z") "2023-12-31")|)

      assert step.fail.message =~ ".isAfter: expected DateTime argument, got string"
    end
  end

  # Regression: when a tool returns a `%DateTime{}` and the LLM calls
  # `(java.util.Date. dt)` directly, the call must accept the struct as a
  # no-op (or upgrade Date/NaiveDateTime to a UTC DateTime). Forcing the LLM
  # to stringify-then-parse is unnecessary friction.
  describe "java.util.Date. with already-temporal arguments" do
    test "DateTime is returned as-is" do
      {:ok, step} =
        Lisp.run("(.getTime (java.util.Date. data/dt))",
          context: %{dt: ~U[2026-05-03 09:14:00Z]}
        )

      assert is_integer(step.return)
      assert step.return == DateTime.to_unix(~U[2026-05-03 09:14:00Z], :millisecond)
    end

    test "NaiveDateTime is upgraded to UTC DateTime" do
      {:ok, step} =
        Lisp.run("(.getTime (java.util.Date. data/ndt))",
          context: %{ndt: ~N[2026-05-03 09:14:00]}
        )

      assert is_integer(step.return)
    end

    test "Date is upgraded to UTC DateTime at midnight" do
      {:ok, step} =
        Lisp.run("(.getTime (java.util.Date. data/d))",
          context: %{d: ~D[2026-05-03]}
        )

      assert is_integer(step.return)
      assert step.return == DateTime.to_unix(~U[2026-05-03 00:00:00Z], :millisecond)
    end

    test "Time alone raises (no date component)" do
      assert {:error, step} =
               Lisp.run("(java.util.Date. data/t)", context: %{t: ~T[09:14:00]})

      assert step.fail.message =~ "Time"
    end

    # Regression (codex review on the temporal sweep): `(str ~N[...])` produces
    # an offsetless ISO string. `(java.util.Date. ...)` used to reject those
    # because `DateTime.from_iso8601/1` requires an offset. The advertised path
    # `(java.util.Date. (str data/ndt))` was broken until we taught the parser
    # to fall through to NaiveDateTime + assume UTC.
    test "string round-trip via (str ndt) -> (java.util.Date. ...) works for NaiveDateTime" do
      {:ok, step} =
        Lisp.run("(.getTime (java.util.Date. (str data/ndt)))",
          context: %{ndt: ~N[2026-05-03 09:14:00]}
        )

      assert step.return == DateTime.to_unix(~U[2026-05-03 09:14:00Z], :millisecond)
    end

    test "(java.util.Date. \"2026-05-03T09:14:00\") parses offsetless ISO as UTC" do
      {:ok, step} = Lisp.run(~s|(.getTime (java.util.Date. "2026-05-03T09:14:00"))|)
      assert step.return == DateTime.to_unix(~U[2026-05-03 09:14:00Z], :millisecond)
    end
  end
end
