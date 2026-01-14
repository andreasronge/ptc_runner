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
