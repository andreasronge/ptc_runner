defmodule PtcRunner.Lisp.Runtime.StringBlankTrimTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp.Runtime

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
