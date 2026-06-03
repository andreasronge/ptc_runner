defmodule PtcRunner.Lisp.Runtime.CollectionOpsTest do
  @moduledoc """
  Coverage for `PtcRunner.Lisp.Runtime.Collection.Transform` and
  `PtcRunner.Lisp.Runtime.Collection.Select`, driven through the real
  PTC-Lisp evaluator (`PtcRunner.Lisp.run/1`).

  Targets the data-integrity dispatch branches:

    * Transform — multi-arity `map`/`mapv` zipping 2-3 collections (element-wise
      truncation to the shortest, nil-collection short-circuits), keyword-field
      `mapcat` flatten, and the keyword-applied-to-string nil paths.
    * Select — `find` associative INDEX vs PREDICATE semantics (DIV-47/48):
      maps look up by key, vectors by non-negative integer index, and
      non-associative collections (sets, strings) surface a recoverable
      `type_error` (DIV-48) instead of crashing; plus map-stream
      `take-while`/`drop-while` early-stop semantics.

  Map iteration order is not guaranteed, so map-output assertions sort first.
  PTC-Lisp keywords surface as plain strings in returned values.
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
    test "map/3 zips two collections element-wise" do
      assert eval!("(map (fn [a b] (+ a b)) [1 2 3] [10 20 30])") == [11, 22, 33]
    end

    test "map/3 truncates to the shorter collection" do
      assert eval!("(map (fn [a b] (+ a b)) [1 2 3] [10 20])") == [11, 22]
    end

    test "map/4 zips three collections element-wise" do
      assert eval!("(map (fn [a b c] (+ a b c)) [1 2] [10 20] [100 200])") == [111, 222]
    end

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
    test "mapv/3 zips two collections" do
      assert eval!("(mapv (fn [a b] (+ a b)) [1 2 3] [10 20 30])") == [11, 22, 33]
    end

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

    test "keyword field wraps a non-list value in a singleton" do
      assert eval!("(mapcat :id [{:id 1} {:id 2}])") == [1, 2]
    end

    test "function form flattens per-element results" do
      assert eval!("(mapcat (fn [x] [x x]) [1 2])") == [1, 1, 2, 2]
    end

    test "over a map passes each [k v] pair to the function and flattens" do
      assert eval!("(sort (mapcat (fn [kv] kv) {:a 1 :b 2}))") == [1, 2, "a", "b"]
    end
  end

  # ==================================================================
  # Transform/Select: keyword applied to a string -> nil paths
  # ==================================================================

  describe "keyword applied to a string (grapheme nil paths)" do
    test "map yields a nil per grapheme" do
      assert eval!(~S<(map :x "abc")>) == [nil, nil, nil]
    end

    test "filter yields empty (keyword access on graphemes is always nil)" do
      assert eval!(~S<(filter :x "abc")>) == []
    end

    test "keep yields empty (all results are nil)" do
      assert eval!(~S<(keep :x "abc")>) == []
    end

    test "remove keeps every grapheme (predicate is always falsy)" do
      assert eval!(~S<(remove :x "abc")>) == ["a", "b", "c"]
    end
  end

  # ==================================================================
  # Select: find — associative lookup (INDEX vs key), DIV-47/48
  # ==================================================================

  describe "find on a map (associative key lookup, NOT predicate search)" do
    test "present key returns the [key value] entry" do
      assert eval!("(find {:a 1} :a)") == ["a", 1]
    end

    test "missing key returns nil" do
      assert eval!("(find {:a 1} :b)") == nil
    end

    test "present key with a nil value returns [key nil], distinct from missing" do
      assert eval!("(find {:a nil} :a)") == ["a", nil]
    end

    test "nil collection returns nil" do
      assert eval!("(find nil :a)") == nil
    end
  end

  describe "find on a vector (associative by non-negative integer index)" do
    test "in-range index returns the [index value] entry" do
      assert eval!("(find [10 20] 1)") == [1, 20]
    end

    test "index of a present nil element returns [index nil]" do
      assert eval!("(find [nil 20] 0)") == [0, nil]
    end

    test "out-of-range index returns nil" do
      assert eval!("(find [10 20] 2)") == nil
    end

    test "negative index returns nil (no from-the-end read)" do
      assert eval!("(find [10 20] -1)") == nil
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

  describe "take-while and drop-while on a map (Stream entry semantics)" do
    # A single-entry map keeps the assertion order-independent while still
    # exercising the map-specific Stream.map clause: each entry is materialized
    # as a [k v] pair before the predicate runs.
    test "take-while passes [k v] entries and keeps matching ones" do
      assert eval!("(take-while (fn [kv] true) {:a 1})") == [["a", 1]]
    end

    test "take-while stops immediately when the first entry fails" do
      assert eval!("(take-while (fn [kv] false) {:a 1})") == []
    end

    test "drop-while drops the matching entry" do
      assert eval!("(drop-while (fn [kv] true) {:a 1})") == []
    end

    test "drop-while keeps entries once the predicate fails" do
      assert eval!("(drop-while (fn [kv] false) {:a 1})") == [["a", 1]]
    end
  end
end
