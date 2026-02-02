defmodule PtcRunner.SubAgent.Loop.ResponseHandlerParseTest do
  @moduledoc """
  Tests for LLM response parsing in ResponseHandler.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Loop.ResponseHandler

  describe "parse/1" do
    test "extracts code from clojure code block" do
      response = """
      ```clojure
      (+ 1 2)
      ```
      """

      assert {:ok, "(+ 1 2)"} = ResponseHandler.parse(response)
    end

    test "extracts code from lisp code block" do
      response = """
      ```lisp
      (def x 42)
      ```
      """

      assert {:ok, "(def x 42)"} = ResponseHandler.parse(response)
    end

    test "extracts raw s-expression without code block" do
      assert {:ok, "(count items)"} = ResponseHandler.parse("(count items)")
    end

    test "handles multiple code blocks by using the last one" do
      response = """
      ```clojure
      (def x 1)
      ```

      Some explanation

      ```clojure
      (def y 2)
      ```
      """

      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def y 2)"
    end

    test "extracts code from plain code block without language tag" do
      response = """
      Here's my solution:

      ```
      (def x 42)
      ```
      """

      assert {:ok, "(def x 42)"} = ResponseHandler.parse(response)
    end

    test "extracts code from code block with clj language tag" do
      response = """
      ```clj
      (def x 1)
      ```
      """

      assert {:ok, "(def x 1)"} = ResponseHandler.parse(response)
    end

    test "extracts code from code block with arbitrary language tag" do
      response = """
      ```text
      (def y 2)
      ```
      """

      assert {:ok, "(def y 2)"} = ResponseHandler.parse(response)
    end

    test "handles multiple plain code blocks by using the last one" do
      response = """
      ```
      (def a 1)
      ```

      ```
      (def b 2)
      ```
      """

      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def b 2)"
    end

    test "ignores plain code blocks that don't contain Lisp" do
      response = """
      Here's some JSON:

      ```
      {"key": "value"}
      ```

      And here's the Lisp:

      ```
      (+ 1 2)
      ```
      """

      # The JSON block is ignored, but the Lisp block is extracted
      assert {:ok, "(+ 1 2)"} = ResponseHandler.parse(response)
    end

    test "returns error when no code found" do
      assert {:error, :no_code_in_response} = ResponseHandler.parse("Just some text")
      assert {:error, :no_code_in_response} = ResponseHandler.parse("123 not s-expression")
    end
  end

  describe "parse/1 Unicode sanitization" do
    test "removes BOM (Byte Order Mark)" do
      # U+FEFF at the start
      response = "\uFEFF(def x 1)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x 1)"
    end

    test "removes zero-width space" do
      # U+200B in the middle
      response = "(def\u200B x 1)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x 1)"
    end

    test "removes zero-width non-joiner" do
      # U+200C
      response = "(def\u200C x 1)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x 1)"
    end

    test "removes zero-width joiner" do
      # U+200D
      response = "(def\u200D x 1)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x 1)"
    end

    test "normalizes smart double quotes to ASCII" do
      # U+201C (left) and U+201D (right)
      response = "(def x \u201Chello\u201D)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x \"hello\")"
    end

    test "normalizes smart single quotes to ASCII" do
      # U+2018 (left) and U+2019 (right)
      response = "(def x \u2018a)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x 'a)"
    end

    test "sanitizes code from code blocks too" do
      response = """
      ```clojure
      \uFEFF(def x \u201Chello\u201D)
      ```
      """

      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x \"hello\")"
    end

    test "handles multiple invisible characters" do
      # BOM + zero-width space + code
      response = "\uFEFF\u200B(+ 1 2)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(+ 1 2)"
    end
  end

  describe "parse/1 #_ reader macro stripping" do
    test "strips #_ with symbol" do
      response = "(def x #_ignored 42)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x  42)"
    end

    test "strips #_ with s-expression" do
      response = "(def x #_(ignored expr) 42)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x  42)"
    end

    test "strips multiple #_ at start" do
      response = "#_comment1 #_comment2 (+ 1 2)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(+ 1 2)"
    end

    test "strips #_ on its own line" do
      response = """
      #_
      ignored
      (+ 1 2)
      """

      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(+ 1 2)"
    end

    test "strips nested #_ forms" do
      # #_#_a b means: first #_ discards #_a (including its discard), leaving b
      response = "(def x #_#_nested-discard ignored 42)"
      {:ok, code} = ResponseHandler.parse(response)
      # Only #_nested-discard is discarded, "ignored" remains
      assert code == "(def x  ignored 42)"
    end

    test "strips chained #_ that discard multiple forms" do
      # To discard two forms, need two separate #_ at the same level
      response = "(def x #_first #_second actual)"
      {:ok, code} = ResponseHandler.parse(response)
      assert code == "(def x   actual)"
    end

    test "strips #_ in code blocks" do
      response = """
      ```clojure
      (def x 1)
      #_
      #_high-value (filter pred items)
      (def y 2)
      ```
      """

      {:ok, code} = ResponseHandler.parse(response)
      assert String.contains?(code, "(def x 1)")
      assert String.contains?(code, "(def y 2)")
      # The #_ discards #_high-value, leaving (filter pred items)
      assert String.contains?(code, "(filter pred items)")
    end
  end

  describe "XML-style code blocks" do
    test "extracts code from ```clojure with </clojure> closer" do
      response = "```clojure\n(+ 1 2)\n</clojure>"
      assert {:ok, "(+ 1 2)"} = ResponseHandler.parse(response)
    end

    test "extracts code from fully XML-style <clojure> block" do
      response = "Some text\n<clojure>\n(def x 42)\n</clojure>\nMore text"
      assert {:ok, "(def x 42)"} = ResponseHandler.parse(response)
    end

    test "extracts code from <lisp> XML block" do
      response = "<lisp>\n(+ 1 2)\n</lisp>"
      assert {:ok, "(+ 1 2)"} = ResponseHandler.parse(response)
    end

    test "extracts code from ```clojure with </lisp> closer" do
      response = "```clojure\n(map inc [1 2 3])\n</lisp>"
      assert {:ok, "(map inc [1 2 3])"} = ResponseHandler.parse(response)
    end

    test "normal ```python block is not affected by XML closer support" do
      # Ensure a non-clojure block with </clojure> in prose doesn't cause issues
      response = "```python\nprint('hello')\n```\nSome text mentioning </clojure> later"
      assert {:error, :no_code_in_response} = ResponseHandler.parse(response)
    end

    test "prefers standard ``` closer over XML closer" do
      response = "```clojure\n(+ 1 2)\n```"
      assert {:ok, "(+ 1 2)"} = ResponseHandler.parse(response)
    end

    test "multiline code with XML closer" do
      response = "```clojure\n(defn foo [x]\n  (+ x 1))\n\n(foo 42)\n</clojure>"
      {:ok, code} = ResponseHandler.parse(response)
      assert String.contains?(code, "(defn foo [x]")
      assert String.contains?(code, "(foo 42)")
    end
  end
end
