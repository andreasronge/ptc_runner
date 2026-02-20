defmodule PtcRunner.Lisp.Runtime.StringGrepTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime

  describe "grep" do
    test "returns lines containing pattern" do
      text = "info: starting\nerror: failed\ninfo: done"
      assert Runtime.grep("error", text) == ["error: failed"]
    end

    test "returns multiple matching lines" do
      text = "error: first\nok\nerror: second"
      assert Runtime.grep("error", text) == ["error: first", "error: second"]
    end

    test "returns empty list when no matches" do
      text = "info: starting\ninfo: done"
      assert Runtime.grep("error", text) == []
    end

    test "empty pattern matches all lines" do
      text = "a\nb\nc"
      assert Runtime.grep("", text) == ["a", "b", "c"]
    end

    test "handles empty text" do
      assert Runtime.grep("error", "") == []
    end

    test "handles text with only newlines" do
      assert Runtime.grep("error", "\n\n") == []
    end

    test "handles mixed line endings" do
      text = "error: win\r\ninfo\nerror: unix"
      assert Runtime.grep("error", text) == ["error: win", "error: unix"]
    end

    test "case insensitive matching by default" do
      text = "Error: big\nerror: small\nINFO: ok"
      assert Runtime.grep("error", text) == ["Error: big", "error: small"]
      assert Runtime.grep("info", text) == ["INFO: ok"]
    end

    test "string pattern is treated as regex" do
      text = "info: ok\nerror: bad\nwarn: meh"
      assert Runtime.grep("error|warn", text) == ["error: bad", "warn: meh"]
    end

    test "BRE-style \\| is auto-converted to PCRE alternation" do
      text = "info: ok\nerror: bad\nwarn: meh"
      # LLMs often write \| for alternation (BRE habit)
      assert Runtime.grep("error\\|warn", text) == ["error: bad", "warn: meh"]
    end

    test "regex patterns like \\d+ work in string grep" do
      text = "item1\nno match\nitem42"
      assert Runtime.grep("item\\d+", text) == ["item1", "item42"]
    end

    test "BRE-style \\( \\) are converted to PCRE groups" do
      text = "foo123\nbar456\nbaz"
      assert Runtime.grep("\\(foo\\|bar\\)\\d+", text) == ["foo123", "bar456"]
    end
  end

  describe "grep_n" do
    test "returns lines with 1-based line numbers and match flag" do
      text = "info\nerror: failed\nok"
      assert Runtime.grep_n("error", text) == [%{line: 2, text: "error: failed", match: true}]
    end

    test "returns multiple matches with correct line numbers" do
      text = "error: first\nok\nerror: second"

      assert Runtime.grep_n("error", text) == [
               %{line: 1, text: "error: first", match: true},
               %{line: 3, text: "error: second", match: true}
             ]
    end

    test "returns empty list when no matches" do
      text = "info: starting\ninfo: done"
      assert Runtime.grep_n("error", text) == []
    end

    test "empty pattern matches all lines with numbers" do
      text = "a\nb"

      assert Runtime.grep_n("", text) == [
               %{line: 1, text: "a", match: true},
               %{line: 2, text: "b", match: true}
             ]
    end

    test "handles empty text" do
      assert Runtime.grep_n("error", "") == []
    end

    test "preserves line numbers with gaps" do
      text = "ok\nok\nerror: here\nok\nok"
      assert Runtime.grep_n("error", text) == [%{line: 3, text: "error: here", match: true}]
    end

    test "handles mixed line endings" do
      text = "info\r\nerror: win\nok\r\nerror: unix"

      assert Runtime.grep_n("error", text) == [
               %{line: 2, text: "error: win", match: true},
               %{line: 4, text: "error: unix", match: true}
             ]
    end

    test "BRE-style \\| alternation works in grep_n" do
      text = "info\nerror: bad\nwarn: meh\nok"

      assert Runtime.grep_n("error\\|warn", text) == [
               %{line: 2, text: "error: bad", match: true},
               %{line: 3, text: "warn: meh", match: true}
             ]
    end
  end

  describe "grep_n with context" do
    test "context=1 includes surrounding lines" do
      text = "line1\nline2\nerror here\nline4\nline5"

      assert Runtime.grep_n("error", text, 1) == [
               %{line: 2, text: "line2", match: false},
               %{line: 3, text: "error here", match: true},
               %{line: 4, text: "line4", match: false}
             ]
    end

    test "context at start boundary does not go out of bounds" do
      text = "error here\nline2\nline3\nline4"

      assert Runtime.grep_n("error", text, 2) == [
               %{line: 1, text: "error here", match: true},
               %{line: 2, text: "line2", match: false},
               %{line: 3, text: "line3", match: false}
             ]
    end

    test "context at end boundary does not go out of bounds" do
      text = "line1\nline2\nline3\nerror here"

      assert Runtime.grep_n("error", text, 2) == [
               %{line: 2, text: "line2", match: false},
               %{line: 3, text: "line3", match: false},
               %{line: 4, text: "error here", match: true}
             ]
    end

    test "overlapping context merges into one block" do
      text = "line1\nerror1\nline3\nerror2\nline5"

      # Matches at lines 2 and 4 with context=1 → ranges [1,3] and [3,5] merge to [1,5]
      assert Runtime.grep_n("error", text, 1) == [
               %{line: 1, text: "line1", match: false},
               %{line: 2, text: "error1", match: true},
               %{line: 3, text: "line3", match: false},
               %{line: 4, text: "error2", match: true},
               %{line: 5, text: "line5", match: false}
             ]
    end

    test "non-overlapping context produces separate blocks" do
      text = "error1\nline2\nline3\nline4\nerror2"

      # Matches at lines 1 and 5 with context=1 → ranges [1,2] and [4,5] (non-overlapping)
      assert Runtime.grep_n("error", text, 1) == [
               %{line: 1, text: "error1", match: true},
               %{line: 2, text: "line2", match: false},
               %{line: 4, text: "line4", match: false},
               %{line: 5, text: "error2", match: true}
             ]
    end

    test "context=0 returns only matches with match flag" do
      text = "line1\nerror here\nline3"

      assert Runtime.grep_n("error", text, 0) == [
               %{line: 2, text: "error here", match: true}
             ]
    end

    test "no matches with context returns empty list" do
      text = "line1\nline2\nline3"
      assert Runtime.grep_n("error", text, 2) == []
    end

    test "empty pattern with context returns all lines as matches" do
      text = "a\nb\nc"

      assert Runtime.grep_n("", text, 1) == [
               %{line: 1, text: "a", match: true},
               %{line: 2, text: "b", match: true},
               %{line: 3, text: "c", match: true}
             ]
    end

    test "hard cap truncation appends virtual marker line" do
      # Generate 200 lines, every line matches
      lines = Enum.map(1..200, &"error line #{&1}")
      text = Enum.join(lines, "\n")

      result = Runtime.grep_n("error", text, 0)

      # 100 capped lines + 1 truncation marker
      assert length(result) == 101
      assert hd(result) == %{line: 1, text: "error line 1", match: true}

      marker = List.last(result)
      assert marker.line == -1
      assert marker.match == false
      assert marker.text =~ "truncated"
      assert marker.text =~ "100 more matches"
    end
  end
end
