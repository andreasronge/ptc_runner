defmodule PtcRunner.Lisp.Runtime.Collection.Transform do
  @moduledoc """
  Transformation operations for PTC-Lisp collections: map, mapv, mapcat,
  keep, map_indexed.

  Each function is collapsed from many type-dispatch clauses to 2-4 by
  delegating normalization to `Collection.Normalize`.
  """

  alias PtcRunner.Lisp.Keyword, as: LispKeyword
  alias PtcRunner.Lisp.Runtime.Callable
  alias PtcRunner.Lisp.Runtime.Collection.Normalize
  alias PtcRunner.Lisp.Runtime.FlexAccess

  # ── map/2 ───────────────────────────────────────────────────────────

  # Keyword on string: flex_get on graphemes always returns nil
  def map(f, coll) when is_atom(f) and is_binary(coll),
    do: Enum.map(Normalize.graphemes(coll), fn _ -> nil end)

  def map(%LispKeyword{}, coll) when is_binary(coll),
    do: Enum.map(Normalize.graphemes(coll), fn _ -> nil end)

  def map(f, coll) when is_map(coll) and not is_struct(coll) do
    keyfn = Normalize.normalize_keyfn(f)
    Enum.map(coll, fn {k, v} -> keyfn.([k, v]) end)
  end

  def map(f, coll) do
    Enum.map(Normalize.to_seq(coll), Normalize.normalize_keyfn(f))
  end

  # ── map/3, map/4 (multi-arity) ─────────────────────────────────────

  def map(_f, nil, _coll2), do: []
  def map(_f, _coll1, nil), do: []

  # Coerce each collection to a seq (string -> graphemes, map -> [k v] pairs)
  # so mixed seqable types zip element-wise — matching map/2, `pmap`, and
  # Clojure (GAP-S102). A non-seqable arg raises via to_seq, surfaced as a clean
  # type_error by the :multi_arity dispatch.
  def map(f, coll1, coll2) do
    Enum.zip_with(Normalize.to_seq(coll1), Normalize.to_seq(coll2), fn a, b ->
      Callable.call(f, [a, b])
    end)
  end

  def map(_f, nil, _c2, _c3), do: []
  def map(_f, _c1, nil, _c3), do: []
  def map(_f, _c1, _c2, nil), do: []

  def map(f, coll1, coll2, coll3) do
    [Normalize.to_seq(coll1), Normalize.to_seq(coll2), Normalize.to_seq(coll3)]
    |> Enum.zip_with(fn [a, b, c] -> Callable.call(f, [a, b, c]) end)
  end

  # ── mapv (delegates to map — identical in PTC-Lisp, no lazy seqs) ──

  def mapv(f, coll), do: map(f, coll)

  def mapv(_f, nil, _coll2), do: []
  def mapv(_f, _coll1, nil), do: []
  def mapv(f, coll1, coll2), do: map(f, coll1, coll2)

  def mapv(_f, nil, _c2, _c3), do: []
  def mapv(_f, _c1, nil, _c3), do: []
  def mapv(_f, _c1, _c2, nil), do: []
  def mapv(f, coll1, coll2, coll3), do: map(f, coll1, coll2, coll3)

  # ── mapcat ──────────────────────────────────────────────────────────

  # Keyword support: extract field values and flatten (special wrapping)
  def mapcat(key, coll) when is_list(coll) and is_atom(key) do
    Enum.flat_map(coll, fn item ->
      case FlexAccess.flex_get(item, key) do
        nil -> []
        val when is_list(val) -> val
        val -> [val]
      end
    end)
  end

  def mapcat(%LispKeyword{} = key, coll) when is_list(coll) do
    Enum.flat_map(coll, fn item ->
      case FlexAccess.flex_get(item, key) do
        nil -> []
        val when is_list(val) -> val
        val -> [val]
      end
    end)
  end

  def mapcat(f, coll) when is_map(coll) and not is_struct(coll) do
    Enum.flat_map(coll, fn {k, v} -> Callable.call(f, [[k, v]]) end)
  end

  def mapcat(_f, nil), do: []

  def mapcat(f, coll) do
    Enum.flat_map(Normalize.to_seq(coll), &Callable.call(f, [&1]))
  end

  # ── keep ────────────────────────────────────────────────────────────
  # Returns non-nil results of (f item). Unlike filter (original items)
  # or map (all results), keep returns f's results minus nils.

  # Keyword on string: always nil, so keep returns empty
  def keep(f, coll) when is_atom(f) and is_binary(coll), do: []
  def keep(%LispKeyword{}, coll) when is_binary(coll), do: []

  def keep(f, coll) when is_map(coll) and not is_struct(coll) do
    keyfn = Normalize.normalize_keyfn(f)

    Enum.reduce(coll, [], fn {k, v}, acc ->
      case keyfn.([k, v]) do
        nil -> acc
        result -> [result | acc]
      end
    end)
    |> Enum.reverse()
  end

  def keep(f, coll) do
    keyfn = Normalize.normalize_keyfn(f)

    Normalize.to_seq(coll)
    |> Enum.reduce([], fn item, acc ->
      case keyfn.(item) do
        nil -> acc
        result -> [result | acc]
      end
    end)
    |> Enum.reverse()
  end

  # ── map_indexed ─────────────────────────────────────────────────────

  def map_indexed(f, coll) when is_map(coll) and not is_struct(coll) do
    coll
    |> Enum.with_index()
    |> Enum.map(fn {{k, v}, idx} -> Callable.call(f, [idx, [k, v]]) end)
  end

  def map_indexed(f, coll) do
    Normalize.to_seq(coll)
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} -> Callable.call(f, [idx, item]) end)
  end

  # ── keep_indexed ────────────────────────────────────────────────────
  # Returns non-nil results of (f index item). Like keep but with index.

  def keep_indexed(f, coll) do
    Normalize.to_seq(coll)
    |> Enum.with_index()
    |> Enum.reduce([], fn {item, idx}, acc ->
      case Callable.call(f, [idx, item]) do
        nil -> acc
        result -> [result | acc]
      end
    end)
    |> Enum.reverse()
  end
end
