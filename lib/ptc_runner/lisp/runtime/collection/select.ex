defmodule PtcRunner.Lisp.Runtime.Collection.Select do
  @moduledoc """
  Selection operations for PTC-Lisp collections: filter, remove, find,
  some, every?, not_any?, take_while, drop_while.

  Each function is collapsed from ~10 type-dispatch clauses to 2-3 by
  delegating predicate/collection normalization to `Collection.Normalize`.
  """

  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Collection.Normalize
  alias PtcRunner.Lisp.Runtime.FlexAccess

  # ── filter ──────────────────────────────────────────────────────────

  # Keyword on string graphemes: keyword access always returns nil → empty
  def filter(pred, coll) when is_atom(pred) and is_binary(coll), do: []
  def filter(%LispKeyword{}, coll) when is_binary(coll), do: []

  def filter(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    coll |> Enum.filter(fn {k, v} -> pred_fn.([k, v]) end) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def filter(pred, coll) do
    Enum.filter(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── remove ──────────────────────────────────────────────────────────

  # Keyword on string: always falsy, so nothing is removed
  def remove(pred, coll) when is_atom(pred) and is_binary(coll), do: Normalize.graphemes(coll)
  def remove(%LispKeyword{}, coll) when is_binary(coll), do: Normalize.graphemes(coll)

  def remove(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    coll |> Enum.reject(fn {k, v} -> pred_fn.([k, v]) end) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def remove(pred, coll) do
    Enum.reject(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── find ────────────────────────────────────────────────────────────

  # Clojure's `(find coll key)` is associative-entry lookup, NOT a
  # predicate search: it returns the `[key value]` entry when `key` is
  # present, or nil when absent. Maps look up by key; vectors are
  # associative by non-negative integer index. `flex_fetch` distinguishes a
  # present nil value from a missing key, so `(find {:a nil} :a)` yields
  # `[:a nil]` while `(find {:a 1} :b)` yields nil.
  #
  # A list/vector key follows PTC's flex-access value model: it is treated as
  # a get-in path, not an exact key, so `find` is consistent with `get`,
  # `contains?`, and seq `replace` (e.g. `(find {[:a] 1} [:a])` is nil, like
  # `(get {[:a] 1} [:a])`). Clojure would match the literal vector key here;
  # special-casing exact vector-key lookup in `find` alone would diverge from
  # the flex-access model, which takes precedence (see DIV-47 and the seq
  # `replace` known-limitation note in clojure-conformance-gaps).
  def find(nil, _key), do: nil

  def find(coll, key) when is_map(coll) and not is_struct(coll) do
    case FlexAccess.flex_fetch(coll, key) do
      {:ok, value} -> [key, value]
      :error -> nil
    end
  end

  def find(coll, key) when is_list(coll) do
    case FlexAccess.flex_fetch(coll, key) do
      {:ok, value} -> [key, value]
      :error -> nil
    end
  end

  # Sets and other non-associative collections (strings, etc.) raise in
  # Clojure ("find not supported on type ..."). Under the PTC value-model
  # policy this surfaces as a recoverable :type_error signal instead of an
  # uncatchable crash (DIV-48).
  def find(coll, _key) do
    raise "type_error: find: #{Helpers.describe_type(coll)} is not associative; " <>
            "find supports maps and vectors only"
  end

  # ── some ────────────────────────────────────────────────────────────

  def some(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :value)
    Enum.find_value(coll, fn {k, v} -> pred_fn.([k, v]) end)
  end

  def some(pred, coll) do
    Enum.find_value(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :value))
  end

  # ── every? ──────────────────────────────────────────────────────────

  def every?(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    Enum.all?(coll, fn {k, v} -> pred_fn.([k, v]) end)
  end

  def every?(pred, coll) do
    Enum.all?(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── not_any? ────────────────────────────────────────────────────────

  def not_any?(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    not Enum.any?(coll, fn {k, v} -> pred_fn.([k, v]) end)
  end

  def not_any?(pred, coll) do
    not Enum.any?(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── not_every? ────────────────────────────────────────────────────────

  def not_every?(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    not Enum.all?(coll, fn {k, v} -> pred_fn.([k, v]) end)
  end

  def not_every?(pred, coll) do
    not Enum.all?(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── take_while ──────────────────────────────────────────────────────

  # Map case: use Stream.map to preserve lazy early-stop semantics
  def take_while(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    coll |> Stream.map(fn {k, v} -> [k, v] end) |> Enum.take_while(pred_fn)
  end

  def take_while(pred, coll) do
    Enum.take_while(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end

  # ── drop_while ──────────────────────────────────────────────────────

  # Map case: use Stream.map to preserve lazy early-stop semantics
  def drop_while(pred, coll) when is_map(coll) and not is_struct(coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    coll |> Stream.map(fn {k, v} -> [k, v] end) |> Enum.drop_while(pred_fn)
  end

  def drop_while(pred, coll) do
    Enum.drop_while(Normalize.to_seq(coll), Normalize.normalize_pred(pred, :truthy))
  end
end
