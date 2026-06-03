defmodule PtcRunner.Lisp.Runtime.MapOpsTest do
  @moduledoc """
  Coverage for `PtcRunner.Lisp.Runtime.MapOps`, driven through the real
  PTC-Lisp evaluator (`PtcRunner.Lisp.run/1`) so the production builtin
  dispatch is exercised.

  Focus is the silent-data-corruption surface of the list-as-vector variants:
  `get`/`assoc`/`update`/`merge` on lists, `assoc` append-at-length
  (`index == count`) vs out-of-bounds (RAISE), and the `update` arity_hint
  diagnostic LLMs see when a default value is passed as an extra argument.

  Note: PTC-Lisp keywords surface as plain strings in returned values
  (`:a` => `"a"`), so assertions use string literals for keyword results.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  # Returns the program's value, raising if the program errored.
  defp eval!(src) do
    case Lisp.run(src) do
      {:ok, %{return: value}} -> value
      {:error, %{fail: %{message: msg}}} -> flunk("PTC-Lisp program errored: #{msg}\n#{src}")
    end
  end

  # Returns the failure message for a program expected to error at runtime.
  defp eval_error(src) do
    case Lisp.run(src) do
      {:error, %{fail: %{message: msg}}} -> msg
      {:ok, %{return: value}} -> flunk("expected error, got #{inspect(value)}\n#{src}")
    end
  end

  # ==================================================================
  # get — list-as-vector index access
  # ==================================================================

  describe "get on a list (vector index access)" do
    test "in-range index returns the element" do
      assert eval!("(get [10 20 30] 1)") == 20
    end

    test "out-of-range index with a default returns the default" do
      assert eval!("(get [10 20 30] 5 :default)") == "default"
    end

    test "negative index with a default returns the default (not from-the-end read)" do
      # The list/get clause guards `k >= 0`; a negative index can never be a
      # valid vector position, so the default is returned rather than reading
      # backwards from the end.
      assert eval!("(get [1 2 3] -1 :d)") == "d"
    end
  end

  # ==================================================================
  # assoc — list-as-vector replace / append / out-of-bounds
  # ==================================================================

  describe "assoc on a list (vector semantics)" do
    test "index < count replaces in place" do
      assert eval!("(assoc [10 20 30] 1 99)") == [10, 99, 30]
    end

    test "index == count appends (Clojure vector append boundary)" do
      assert eval!("(assoc [10 20 30] 3 99)") == [10, 20, 30, 99]
    end

    test "appending past the only valid boundary on an empty list" do
      assert eval!("(assoc [] 0 :x)") == ["x"]
    end

    test "index > count RAISES out-of-bounds (silent-corruption guard)" do
      msg = eval_error("(assoc [10 20 30] 5 99)")
      assert msg =~ "index 5 out of bounds for list of length 3"
    end

    test "variadic form replaces then appends in sequence" do
      assert eval!("(assoc [10 20 30] 1 :a 3 :b)") == [10, "a", 30, "b"]
    end

    test "variadic form RAISES if a later pair lands out of bounds" do
      # The first pair (index 0) is valid; the second targets index 2 of a
      # length-1 list, which is past the append boundary -> raise.
      msg = eval_error("(assoc [1] 0 :a 2 :b)")
      assert msg =~ "index 2 out of bounds for list of length 1"
    end
  end

  # ==================================================================
  # update — list-as-vector update / out-of-bounds + arity_hint
  # ==================================================================

  describe "update on a list (vector semantics)" do
    test "in-range index applies the function" do
      assert eval!("(update [10 20 30] 1 (fn [x] (+ x 100)))") == [10, 120, 30]
    end

    test "out-of-range index RAISES (no silent append)" do
      msg = eval_error("(update [10 20 30] 5 (fn [x] x))")
      assert msg =~ "index 5 out of bounds for list of length 3"
    end

    test "extra args are forwarded to the function (Clojure update semantics)" do
      # (update l 0 (fn [x y] (+ x y)) 100) calls (f 10 100) => 110.
      assert eval!("(update [1 2 3] 0 (fn [x y] (+ x y)) 100)") == [101, 2, 3]
    end
  end

  describe "update arity_hint diagnostics" do
    test "one extra arg suggests the default-value pitfall (fnil/or hint)" do
      # The function takes 1 arg; passing an extra 99 (likely meant as a
      # default) triggers the targeted hint, not a raw BadArityError.
      msg = eval_error("(update {:n 1} :n (fn [x] x) 99)")
      assert msg =~ "function expects 1 argument(s) but was called with 2"
      assert msg =~ "may have been intended as a default value"
      assert msg =~ "wrap with fnil"
    end

    test "two-or-more extra args use the generic hint, not the default-value hint" do
      msg = eval_error("(update {:n 1} :n (fn [x] x) 99 100)")
      assert msg =~ "function expects 1 argument(s) but was called with 3"
      assert msg =~ "Extra arguments are passed to the function, not used as defaults"
      refute msg =~ "may have been intended as a default value"
    end
  end

  # ==================================================================
  # merge — map vs falsy vs single-arg passthrough vs list rejection
  # ==================================================================

  describe "merge" do
    test "merges two maps" do
      assert eval!("(merge {:a 1} {:b 2})") == %{"a" => 1, "b" => 2}
    end

    test "nil operands are treated as empty maps" do
      assert eval!("(merge nil {:a 1})") == %{"a" => 1}
      assert eval!("(merge {:a 1} nil)") == %{"a" => 1}
    end

    test "a single truthy argument is returned unchanged regardless of type" do
      # (merge x) has nothing to merge; Clojure returns x as-is, even a string.
      assert eval!(~S<(merge "ab")>) == "ab"
    end

    test "a list argument is rejected by the arg-spec as a non-map" do
      msg = eval_error("(merge [1 2] [3 4])")
      assert msg =~ "expected map, got list"
    end
  end
end
