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

    test "case sensitive matching" do
      text = "Error: big\nerror: small"
      assert Runtime.grep("error", text) == ["error: small"]
      assert Runtime.grep("Error", text) == ["Error: big"]
    end
  end

  describe "grep_n" do
    test "returns lines with 1-based line numbers" do
      text = "info\nerror: failed\nok"
      assert Runtime.grep_n("error", text) == [%{line: 2, text: "error: failed"}]
    end

    test "returns multiple matches with correct line numbers" do
      text = "error: first\nok\nerror: second"

      assert Runtime.grep_n("error", text) == [
               %{line: 1, text: "error: first"},
               %{line: 3, text: "error: second"}
             ]
    end

    test "returns empty list when no matches" do
      text = "info: starting\ninfo: done"
      assert Runtime.grep_n("error", text) == []
    end

    test "empty pattern matches all lines with numbers" do
      text = "a\nb"
      assert Runtime.grep_n("", text) == [%{line: 1, text: "a"}, %{line: 2, text: "b"}]
    end

    test "handles empty text" do
      assert Runtime.grep_n("error", "") == []
    end

    test "preserves line numbers with gaps" do
      text = "ok\nok\nerror: here\nok\nok"
      assert Runtime.grep_n("error", text) == [%{line: 3, text: "error: here"}]
    end

    test "handles mixed line endings" do
      text = "info\r\nerror: win\nok\r\nerror: unix"

      assert Runtime.grep_n("error", text) == [
               %{line: 2, text: "error: win"},
               %{line: 4, text: "error: unix"}
             ]
    end
  end
end
