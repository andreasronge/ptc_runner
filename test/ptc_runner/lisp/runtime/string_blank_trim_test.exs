defmodule PtcRunner.Lisp.Runtime.StringBlankTrimTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime

  @clojure_whitespace [
    0x0009,
    0x000A,
    0x000B,
    0x000C,
    0x000D,
    0x001C,
    0x001D,
    0x001E,
    0x001F,
    0x0020,
    0x1680,
    0x2000,
    0x2001,
    0x2002,
    0x2003,
    0x2004,
    0x2005,
    0x2006,
    0x2008,
    0x2009,
    0x200A,
    0x2028,
    0x2029,
    0x205F,
    0x3000
  ]

  @non_clojure_whitespace [0x0000, 0x0085, 0x00A0, 0x2007, 0x202F]

  describe "blank?/1" do
    test "returns true for nil, empty, and whitespace-only strings" do
      assert Runtime.blank?(nil) == true
      assert Runtime.blank?("") == true
      assert Runtime.blank?("   ") == true
      assert Runtime.blank?("\t\n") == true
    end

    test "returns false for non-blank strings" do
      assert Runtime.blank?("x") == false
      assert Runtime.blank?("  x  ") == false
    end

    test "uses the pinned Clojure Character.isWhitespace set" do
      for codepoint <- @clojure_whitespace do
        whitespace = <<codepoint::utf8>>

        assert Runtime.blank?(whitespace),
               "expected U+#{codepoint |> Integer.to_string(16) |> String.pad_leading(4, "0")} to be blank"
      end

      for codepoint <- @non_clojure_whitespace do
        whitespace = <<codepoint::utf8>>

        refute Runtime.blank?(whitespace),
               "expected U+#{codepoint |> Integer.to_string(16) |> String.pad_leading(4, "0")} not to be blank"
      end
    end
  end

  describe "trim/1, triml/1, and trimr/1" do
    test "share the pinned Clojure whitespace classifier" do
      for codepoint <- @clojure_whitespace do
        whitespace = <<codepoint::utf8>>

        assert Runtime.trim(whitespace <> "x" <> whitespace) == "x"
        assert Runtime.triml(whitespace <> "x" <> whitespace) == "x" <> whitespace
        assert Runtime.trimr(whitespace <> "x" <> whitespace) == whitespace <> "x"
      end

      for codepoint <- @non_clojure_whitespace do
        whitespace = <<codepoint::utf8>>
        value = whitespace <> "x" <> whitespace

        assert Runtime.trim(value) == value
        assert Runtime.triml(value) == value
        assert Runtime.trimr(value) == value
      end
    end
  end

  describe "trim-newline/1" do
    test "removes trailing newline and carriage return characters only" do
      assert Runtime.trim_newline("a\n") == "a"
      assert Runtime.trim_newline("a\r") == "a"
      assert Runtime.trim_newline("a\r\n") == "a"
      assert Runtime.trim_newline("a\n\r") == "a"
      assert Runtime.trim_newline("a\n\n") == "a"
      assert Runtime.trim_newline("a  ") == "a  "
    end
  end

  describe "triml/1 and trimr/1" do
    test "trim one side of whitespace" do
      assert Runtime.triml("  a  ") == "a  "
      assert Runtime.triml("\t\na") == "a"
      assert Runtime.trimr("  a  ") == "  a"
      assert Runtime.trimr("a\t\n") == "a"
    end
  end
end
