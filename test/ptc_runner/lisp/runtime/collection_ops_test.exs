defmodule PtcRunner.Lisp.Runtime.CollectionOpsTest do
  @moduledoc """
  Collection edge cases exercised through the PTC-Lisp evaluator.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Lisp

  defp eval!(src) do
    case Lisp.run(src) do
      {:ok, %{return: value}} -> value
      {:error, %{fail: %{message: msg}}} -> flunk("PTC-Lisp program errored: #{msg}\n#{src}")
    end
  end

  defp eval_error(src) do
    case Lisp.run(src) do
      {:error, %{fail: %{message: msg}}} -> msg
      {:ok, %{return: value}} -> flunk("expected error, got #{inspect(value)}\n#{src}")
    end
  end

  # ==================================================================
  # Transform: multi-arity map / mapv (zip 2-3 colls)
  # ==================================================================

  describe "map/3 and map/4 (multi-collection zip)" do
    test "map/3 short-circuits to empty when the second collection is nil" do
      assert eval!("(map (fn [a b] [a b]) [1 2 3] nil)") == []
    end

    test "map/4 short-circuits to empty when the third collection is nil" do
      assert eval!("(map (fn [a b c] c) [1 2] [3 4] nil)") == []
    end

    test "map/3 coerces a string operand to graphemes for the zip (GAP-S102)" do
      # The string is coerced to graphemes and zipped element-wise; the closure
      # then sees a one-char string paired with a number. Asserting the closure
      # type_error proves the string was admitted to the zip rather than
      # rejected as a non-seqable arg.
      msg = eval_error(~S<(map (fn [a b] (+ a b)) "abc" [1 2 3])>)
      assert msg =~ "add: invalid argument types: string, number"
    end
  end

  describe "mapv/3 and mapv/4 (delegates to map)" do
    test "mapv/4 zips three collections" do
      # Values 9 and 12 land in printable-ASCII range; the list value is
      # [9, 12] regardless of how Elixir's inspect renders it as a charlist.
      assert eval!("(mapv (fn [a b c] (+ a b c)) [1 2] [3 4] [5 6])") == [9, 12]
    end

    test "mapv/3 short-circuits to empty on a nil collection" do
      assert eval!("(mapv (fn [a b] a) [1 2] nil)") == []
    end
  end

  # ==================================================================
  # Transform: mapcat keyword-field flatten + map dispatch
  # ==================================================================

  describe "mapcat" do
    test "keyword field extracts and flattens list values, skipping nil/missing" do
      src = "(mapcat :tags [{:tags [1 2]} {:tags [3]} {:tags nil} {:no 9}])"
      assert eval!(src) == [1, 2, 3]
    end
  end

  # ==================================================================
  # Select: find — associative lookup (INDEX vs key), DIV-47/48
  # ==================================================================

  describe "find on a vector (associative by non-negative integer index)" do
    test "index of a present nil element returns [index nil]" do
      assert eval!("(find [nil 20] 0)") == [0, nil]
    end
  end

  describe "find on a non-associative collection (DIV-48 type_error)" do
    test "a set surfaces a recoverable type_error signal" do
      msg = eval_error("(find " <> "\#{1 2 3}" <> " 1)")
      assert msg =~ "type_error"
      assert msg =~ "find: set is not associative"
    end

    test "a string surfaces a recoverable type_error signal" do
      msg = eval_error(~S<(find "abc" 0)>)
      assert msg =~ "type_error"
      assert msg =~ "find: string is not associative"
    end
  end

  # ==================================================================
  # Select: take-while / drop-while
  # ==================================================================

  describe "take-while and drop-while on a list" do
    test "take-while stops at the first failing element" do
      assert eval!("(take-while (fn [x] (< x 3)) [1 2 3 4 1])") == [1, 2]
    end

    test "drop-while skips the leading run that satisfies the predicate" do
      assert eval!("(drop-while (fn [x] (< x 3)) [1 2 3 4 1])") == [3, 4, 1]
    end

    test "take-while over a vector-of-pairs inspects each pair" do
      src = "(take-while (fn [kv] (< (get kv 1) 3)) [[:a 1] [:b 2] [:c 5]])"
      assert eval!(src) == [["a", 1], ["b", 2]]
    end

    test "drop-while over a vector-of-pairs inspects each pair" do
      src = "(drop-while (fn [kv] (< (get kv 1) 3)) [[:a 1] [:b 2] [:c 5]])"
      assert eval!(src) == [["c", 5]]
    end
  end
end
