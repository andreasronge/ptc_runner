defmodule PtcRunner.Lisp.Runtime.StringSplitLinesTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime

  describe "split-lines" do
    test "splits string by newline" do
      assert Runtime.split_lines("line1\nline2\nline3") == ["line1", "line2", "line3"]
    end

    test "splits string by \r\n" do
      assert Runtime.split_lines("line1\r\nline2\r\nline3") == ["line1", "line2", "line3"]
    end

    test "splits string by mixed \n and \r\n" do
      assert Runtime.split_lines("line1\nline2\r\nline3") == ["line1", "line2", "line3"]
    end

    test "discards trailing newlines" do
      assert Runtime.split_lines("line1\nline2\n\n\n") == ["line1", "line2"]
      assert Runtime.split_lines("test\n") == ["test"]
    end

    test "preserves inner empty lines" do
      assert Runtime.split_lines("line1\n\nline3") == ["line1", "", "line3"]
    end

    test "handles empty string" do
      assert Runtime.split_lines("") == []
    end

    test "handles input with only newlines" do
      assert Runtime.split_lines("\n") == []
      assert Runtime.split_lines("\n\n\n") == []
      assert Runtime.split_lines("\r\n\r\n") == []
    end

    test "preserves leading empty lines" do
      assert Runtime.split_lines("\nline1") == ["", "line1"]
    end

    test "handles single line without newline" do
      assert Runtime.split_lines("hello") == ["hello"]
    end

    test "treats \r alone as part of the line (not a line ending)" do
      # This matches Clojure behavior where only \n and \r\n are splitters
      assert Runtime.split_lines("\r") == ["\r"]
      assert Runtime.split_lines("a\rb") == ["a\rb"]
    end
  end
end
