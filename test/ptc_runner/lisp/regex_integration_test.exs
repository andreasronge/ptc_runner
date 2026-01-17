defmodule PtcRunner.Lisp.RegexIntegrationTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  describe "re-split via interpreter" do
    test "splits by simple regex pattern" do
      source = ~S|(re-split (re-pattern ",") "a,b,c")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["a", "b", "c"]
    end

    test "splits by whitespace pattern" do
      source = ~S|(re-split (re-pattern "\\s+") "a  b   c")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["a", "b", "c"]
    end

    test "splits by newlines" do
      source = ~S|(re-split (re-pattern "\\r?\\n") "line1\nline2\r\nline3")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["line1", "line2", "line3"]
    end

    test "works in pipeline" do
      source = ~S|(->> "a  b   c" (re-split (re-pattern "\\s+")) count)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 3
    end
  end

  describe "re-seq via interpreter" do
    test "finds all matches" do
      source = ~S|(re-seq (re-pattern "\\d+") "a1b22c333")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == ["1", "22", "333"]
    end

    test "returns empty list when no matches" do
      source = ~S|(re-seq (re-pattern "\\d+") "abc")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == []
    end

    test "returns groups when pattern has capture groups" do
      source = ~S|(re-seq (re-pattern "(\\d)(\\w)") "1a2b3c")|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == [["1a", "1", "a"], ["2b", "2", "b"], ["3c", "3", "c"]]
    end

    test "works in pipeline" do
      source = ~S|(->> "foo1bar2baz3" (re-seq (re-pattern "\\d+")) count)|
      {:ok, %{return: result}} = Lisp.run(source)
      assert result == 3
    end
  end

  describe "regex literal error message" do
    test "provides helpful error for #\"...\" syntax" do
      source = ~S|(clojure.string/split "a b c" #"\s+")|
      {:error, %{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)

      assert message =~ "regex literals"
      assert message =~ "re-split"
      assert message =~ "split-lines"
    end
  end
end
