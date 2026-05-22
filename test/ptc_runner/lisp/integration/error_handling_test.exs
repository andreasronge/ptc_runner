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
      source = "(filter :active data/users"

      assert {:error, %Step{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)
      assert message =~ "unbalanced parentheses"
    end

    test "unbalanced brackets" do
      source = "[1 2 3"

      assert {:error, %Step{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)
      assert message =~ "unbalanced brackets"
    end

    test "invalid token" do
      source = "(+ 1 @invalid)"

      assert {:error, %Step{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)
      # @deref is not supported
      assert message =~ "deref syntax"
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

    test "unknown tool returns unknown_tool error" do
      # Tool calls to unregistered tools return error tuple with specific reason
      source = ~S|(tool/unknown-tool {})|

      assert {:error, %Step{fail: %{reason: :unknown_tool, message: message}}} =
               Lisp.run(source)

      assert message =~ "Unknown tool"
      assert message =~ "unknown-tool"
    end
  end

  describe "invalid programs - type errors" do
    test "filter with non-collection returns type error" do
      # Passing non-list to filter returns error tuple
      source = "(filter :x 42)"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} = Lisp.run(source)
      assert message =~ "filter: arg 2 expected seqable, got number"
    end

    test "filter with arguments swapped returns a clean error, not a raw protocol error" do
      # (filter coll pred) instead of (filter pred coll) — the predicate ends up
      # in the collection slot. Previously leaked `protocol Enumerable not
      # implemented for Function ...`.
      source = "(filter [1 2 3] (fn [x] true))"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} = Lisp.run(source)
      assert message =~ "expected a collection, got a function"
      assert message =~ "arguments may be swapped"
      refute message =~ "protocol Enumerable"
    end

    test "count with non-collection returns type error" do
      # Passing non-list to count returns error tuple
      source = "(count 42)"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} = Lisp.run(source)
      assert message =~ "count: arg 1 expected seqable, got number"
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

    test "get with key and map swapped suggests the right order" do
      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} =
               Lisp.run(~s|(get :status {"status" "ok"})|)

      assert message =~ "get expects the collection first"
      assert message =~ "arguments appear to be swapped"
    end

    test "builtin used as a value reports type 'function', not 'unknown'" do
      # ((first filter) 1 2): `filter` is a builtin reference; (first <builtin>)
      # is a type error whose argument used to render as the leaky "unknown".
      assert {:error, %Step{fail: %{message: message}}} = Lisp.run("((first filter) 1 2)")
      assert message =~ "function"
      refute message =~ "unknown"
    end

    test "map builtin type errors include function name and argument position" do
      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} =
               Lisp.run("(merge nil [1 2])")

      assert message =~ "merge: arg 2 expected map, got list"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} =
               Lisp.run("(merge [1 2] nil)")

      assert message =~ "merge: arg 1 expected map, got list"
    end

    test "keyword arguments are reported as keyword in canonical type errors" do
      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} =
               Lisp.run("(merge :x {})")

      assert message =~ "merge: arg 1 expected map, got keyword"

      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} =
               Lisp.run("(take :n [1 2])")

      assert message =~ "take: arg 1 expected integer, got keyword"
    end

    test "sort-by swapped collection and comparator keeps custom hint" do
      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} =
               Lisp.run("(sort-by :k [1 2] >)")

      assert message =~ "sort-by expects (key, comparator, collection)"
      assert message =~ "got (key, collection, comparator)"
    end

    test "sort-by swapped vector path hint uses source-like values" do
      assert {:error, %Step{fail: %{reason: :type_error, message: message}}} =
               Lisp.run(~S|(sort-by [:a :b] [{:a {:b 1}} {:a {:b 2}}] >)|)

      assert message =~ "Try: (sort-by [:a :b] > collection)"
      refute message =~ "%PtcRunner.Lisp.Keyword"
      refute message =~ "%PtcRunner.Lisp.Env.Builtin"
    end

    test "merge-with without function is an arity error" do
      assert {:error, %Step{fail: %{reason: :arity_error, message: message}}} =
               Lisp.run("(merge-with)")

      assert message =~ "merge-with requires at least 1 argument"
    end
  end

  describe "invalid programs - common LLM mistakes" do
    test "using quoted list syntax instead of vector" do
      # PTC-Lisp uses vectors [1 2 3], not quoted lists '(1 2 3)
      source = "'(1 2 3)"

      assert {:error, %Step{fail: %{reason: :parse_error, message: message}}} = Lisp.run(source)
      # Quote syntax is not supported
      assert message =~ "quote syntax"
    end

    test "if without then or else clause" do
      # PTC-Lisp requires at least a then clause: (if cond then) or (if cond then else)
      source = "(if true)"

      assert {:error, %Step{fail: %{reason: :invalid_arity, message: message}}} = Lisp.run(source)
      assert message =~ "expected (if cond then else?)"
    end

    test "zero-arity ordered comparison returns arity error" do
      source = "(<)"

      assert {:error, %Step{fail: %{reason: :arity_error, message: message}}} = Lisp.run(source)
      assert message =~ "< requires at least 1 argument"
    end

    test "range with 0 arguments returns arity error" do
      # range requires at least 1 argument in PTC-Lisp
      source = "(range)"

      assert {:error, %Step{fail: %{reason: :arity_error, message: message}}} =
               Lisp.run(source)

      assert message =~ "range expects 1, 2, 3 argument(s)"
      assert message =~ "got 0"
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

    test "destructuring in fn params - vector pattern binds nil for insufficient elements" do
      # In Clojure, missing elements bind to nil instead of erroring
      source = "((fn [[a b c]] [a b c]) [1 2])"
      {:ok, %Step{return: result}} = Lisp.run(source)
      assert result == [1, 2, nil]
    end
  end
end
