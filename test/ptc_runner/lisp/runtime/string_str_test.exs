defmodule PtcRunner.Lisp.Runtime.StringStrTest do
  use ExUnit.Case, async: true

  defp run!(code) do
    {:ok, step} = PtcRunner.Lisp.run(code, context: %{})
    step.return
  end

  describe "(str) with single non-string argument" do
    test "converts a map to Clojure-style string" do
      assert run!("(str {:a 1})") == "{:a 1}"
    end

    test "converts a multi-key map to Clojure-style string" do
      result = run!("(str {:a 1 :b 2})")
      assert result =~ ~r/^\{.*\}$/
      assert result =~ ":a 1"
      assert result =~ ":b 2"
    end

    test "converts a list to Clojure-style string" do
      assert run!("(str [1 2 3])") == "[1 2 3]"
    end

    test "converts an integer to string" do
      assert run!("(str 42)") == "42"
    end

    test "converts nil to empty string" do
      assert run!("(str nil)") == ""
    end

    test "returns a string unchanged" do
      assert run!("(str \"hello\")") == "hello"
    end

    test "converts keyword to string" do
      assert run!("(str :foo)") == ":foo"
    end

    test "converts boolean to string" do
      assert run!("(str true)") == "true"
    end
  end

  describe "(str) concatenation" do
    test "concatenates multiple values without separator" do
      assert run!(~s|(str "a" "b" "c")|) == "abc"
    end

    test "concatenates mixed types" do
      assert run!(~s|(str "count: " 42)|) == "count: 42"
    end

    test "nil is empty in concatenation" do
      assert run!(~s|(str "a" nil "b")|) == "ab"
    end

    test "no arguments returns empty string" do
      assert run!("(str)") == ""
    end
  end
end
