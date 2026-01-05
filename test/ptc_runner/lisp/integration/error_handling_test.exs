defmodule PtcRunner.Lisp.Integration.ErrorHandlingTest do
  @moduledoc """
  Tests for invalid programs and error handling in PTC-Lisp.

  Covers parse errors, semantic errors, type errors, and common LLM mistakes.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp
  alias PtcRunner.Step

  describe "invalid programs - parse errors" do
    test "missing closing paren" do
      source = "(filter (where :active ctx/users"

      assert {:error, %Step{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)
      assert message =~ "expected"
    end

    test "unbalanced brackets" do
      source = "[1 2 3"

      assert {:error, %Step{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)
      assert message =~ "expected"
    end

    test "invalid token" do
      source = "(+ 1 @invalid)"

      assert {:error, %Step{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)
      assert message =~ "@invalid"
    end
  end

  describe "invalid programs - semantic errors" do
    test "unbound variable" do
      # Referencing undefined variable returns specific error with variable name
      source = "(+ x 1)"

      assert {:error, %Step{fail: %{reason: :unbound_var}}} = Lisp.run(source)
    end

    test "calling non-function" do
      # Attempting to call a literal value returns error with the value
      source = "(42 1 2)"

      assert {:error, %Step{fail: %{reason: :not_callable}}} = Lisp.run(source)
    end

    @tag :capture_log
    test "unknown tool returns execution error" do
      # Tool calls to unregistered tools return error tuple
      source = ~S|(call "unknown-tool" {})|

      assert {:error, %Step{fail: %{reason: :execution_error, message: message}}} =
               Lisp.run(source)

      assert message =~ "Unknown tool"
      assert message =~ "unknown-tool"
    end
  end

  describe "invalid programs - type errors" do
    test "filter with non-collection returns type error" do
      # Passing non-list to filter returns error tuple
      source = "(filter (where :x) 42)"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} = Lisp.run(source)
      assert message =~ "invalid argument types"
    end

    test "count with non-collection returns type error" do
      # Passing non-list to count returns error tuple
      source = "(count 42)"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} = Lisp.run(source)
      assert message =~ "invalid argument types"
    end

    test "take on set returns type error" do
      # Sets are unordered, so take doesn't make sense
      source = "(take 2 \#{1 2 3})"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} = Lisp.run(source)
      assert message =~ "take does not support sets"
    end

    test "first on set returns type error" do
      # Sets are unordered, so first doesn't make sense
      source = "(first \#{1 2 3})"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} = Lisp.run(source)
      assert message =~ "first does not support sets"
    end
  end

  describe "invalid programs - common LLM mistakes" do
    test "where with field and value but missing operator" do
      # LLMs often write (where :field value) expecting equality
      # but where requires explicit operator: (where :field = value)
      source = ~S|(filter (where :status "active") ctx/items)|
      ctx = %{items: [%{status: "active"}]}

      assert {:error, %Step{fail: %{reason: :invalid_where_form, message: message}}} =
               Lisp.run(source, context: ctx)

      assert message =~ "expected (where field) or (where field op value)"
    end

    test "using quoted list syntax instead of vector" do
      # PTC-Lisp uses vectors [1 2 3], not quoted lists '(1 2 3)
      source = "'(1 2 3)"

      assert {:error, %Step{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)
      assert message =~ "expected"
    end

    test "if without else clause" do
      # PTC-Lisp requires else clause: (if cond then else)
      # Use (when cond then) for single-branch conditionals
      source = "(if true 1)"

      assert {:error, %Step{fail: %{reason: :invalid_arity, message: message}}} = Lisp.run(source)
      assert message =~ "expected (if cond then else)"
    end

    test "3-arity comparison (range syntax)" do
      # Clojure allows (<= 1 x 10) but PTC-Lisp only supports 2-arity
      # Use (and (>= x 1) (<= x 10)) instead
      source = "(<= 1 5 10)"

      assert {:error, %Step{fail: %{reason: :invalid_arity, message: message}}} = Lisp.run(source)
      assert message =~ "comparison operators require exactly 2 arguments"
      assert message =~ "got 3"
    end

    test "destructuring in fn params - map pattern with wrong argument type" do
      # Analyzer now accepts destructuring patterns in fn parameters
      # Evaluator supports map destructuring patterns
      # But this test passes wrong argument type to catch runtime error
      source = "((fn [{:keys [a]}] a) :not-a-map)"

      # The error should be from destructuring error at runtime
      assert {:error, %Step{}} = Lisp.run(source)
    end

    test "destructuring in fn params - vector pattern success" do
      source = "((fn [[a b]] a) [1 2])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == 1
    end

    test "destructuring in fn params - map pattern success" do
      source = "((fn [{:keys [x]}] x) {:x 10})"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == 10
    end

    test "destructuring in fn params - vector pattern ignores extra elements" do
      source = "((fn [[a]] a) [1 2 3])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == 1
    end

    test "destructuring in fn params - vector pattern insufficient elements error" do
      source = "((fn [[a b c]] a) [1 2])"

      assert {:error, %Step{fail: %{reason: :destructure_error, message: message}}} =
               Lisp.run(source)

      assert message =~ "expected at least 3 elements, got 2"
    end
  end
end
