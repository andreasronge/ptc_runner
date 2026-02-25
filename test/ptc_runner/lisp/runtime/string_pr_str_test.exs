defmodule PtcRunner.Lisp.Runtime.StringPrStrTest do
  use ExUnit.Case, async: true

  defp run!(code) do
    {:ok, step} = PtcRunner.Lisp.run(code, context: %{})
    step.return
  end

  describe "(pr-str) with no arguments" do
    test "returns empty string" do
      assert run!("(pr-str)") == ""
    end
  end

  describe "(pr-str) with single argument" do
    test "string gets quoted" do
      assert run!("(pr-str \"hello\")") == "\"hello\""
    end

    test "number stays as-is" do
      assert run!("(pr-str 42)") == "42"
    end

    test "keyword" do
      assert run!("(pr-str :foo)") == ":foo"
    end

    test "nil becomes the string nil" do
      assert run!("(pr-str nil)") == "nil"
    end

    test "true" do
      assert run!("(pr-str true)") == "true"
    end

    test "false" do
      assert run!("(pr-str false)") == "false"
    end

    test "vector" do
      assert run!("(pr-str [1 2 3])") == "[1 2 3]"
    end

    test "map" do
      assert run!("(pr-str {:a 1})") == "{:a 1}"
    end
  end

  describe "(pr-str) with multiple arguments" do
    test "joins with space" do
      assert run!("(pr-str 1 \"a\")") == "1 \"a\""
    end

    test "three arguments" do
      assert run!("(pr-str 1 :foo nil)") == "1 :foo nil"
    end

    test "strings get quoted in multi-arg" do
      assert run!(~s|(pr-str "hello" "world")|) == ~s|"hello" "world"|
    end
  end

  describe "(pr-str) vs (str) differences" do
    test "pr-str quotes strings, str does not" do
      assert run!("(str \"hello\")") == "hello"
      assert run!("(pr-str \"hello\")") == "\"hello\""
    end

    test "pr-str returns nil as \"nil\", str returns empty string" do
      assert run!("(str nil)") == ""
      assert run!("(pr-str nil)") == "nil"
    end

    test "pr-str space-separates, str concatenates" do
      assert run!("(str 1 2 3)") == "123"
      assert run!("(pr-str 1 2 3)") == "1 2 3"
    end
  end
end
