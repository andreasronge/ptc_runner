defmodule PtcRunner.Lisp.Runtime.Collection do
  @moduledoc """
  Collection operations for PTC-Lisp runtime.

  Provides filtering, mapping, sorting, and other collection manipulation functions.

  Selection operations (filter, remove, find, some, every?, not_any?,
  take_while, drop_while) are implemented in `Collection.Select`.

  Transformation operations (map, mapv, mapcat, keep, map_indexed, pluck)
  are implemented in `Collection.Transform`.
  """

  alias PtcRunner.Lisp.Eval.Helpers
  alias PtcRunner.Lisp.Runtime.Callable
  alias PtcRunner.Lisp.Runtime.Collection.Normalize
  alias PtcRunner.Lisp.Runtime.Collection.Select
  alias PtcRunner.Lisp.Runtime.Collection.Transform
  alias PtcRunner.Lisp.Runtime.FlexAccess

  # ============================================================
  # Selection operations (delegated to Collection.Select)
  # ============================================================

  defdelegate filter(pred, coll), to: Select
  defdelegate remove(pred, coll), to: Select
  defdelegate find(pred, coll), to: Select
  defdelegate some(pred, coll), to: Select
  defdelegate every?(pred, coll), to: Select
  defdelegate not_any?(pred, coll), to: Select
  defdelegate not_every?(pred, coll), to: Select
  defdelegate take_while(pred, coll), to: Select
  defdelegate drop_while(pred, coll), to: Select

  # ============================================================
  # Transformation operations (delegated to Collection.Transform)
  # ============================================================

  defdelegate map(f, coll), to: Transform
  defdelegate map(f, c1, c2), to: Transform
  defdelegate map(f, c1, c2, c3), to: Transform
  defdelegate mapv(f, coll), to: Transform
  defdelegate mapv(f, c1, c2), to: Transform
  defdelegate mapv(f, c1, c2, c3), to: Transform
  defdelegate mapcat(f, coll), to: Transform
  defdelegate keep(f, coll), to: Transform
  defdelegate keep_indexed(f, coll), to: Transform
  defdelegate map_indexed(f, coll), to: Transform
  defdelegate pluck(key, coll), to: Transform

  # ============================================================
  # Private helpers used by remaining operations
  # ============================================================

  defp wrap_comparator(:asc), do: :asc
  defp wrap_comparator(:desc), do: :desc

  defp wrap_comparator(comp) when is_function(comp, 2) do
    fn a, b ->
      case comp.(a, b) do
        n when is_integer(n) -> n <= 0
        bool -> bool
      end
    end
  end

  defp wrap_comparator(comp) when is_tuple(comp) do
    fn a, b ->
      case Callable.call(comp, [a, b]) do
        n when is_integer(n) -> n <= 0
        bool -> bool
      end
    end
  end

  defp wrap_comparator(other) do
    raise "type_error: invalid comparator: #{inspect(other)}. Expected :asc, :desc, or a function of 2 arguments."
  end

  defp validate_n(n, _name) when is_integer(n) and n > 0, do: :ok

  defp validate_n(n, name),
    do: raise("type_error: #{name}: n must be a positive integer, got #{inspect(n)}")

  defp validate_step(step, _name) when is_integer(step) and step > 0, do: :ok

  defp validate_step(step, name),
    do: raise("type_error: #{name}: step must be a positive integer, got #{inspect(step)}")

  # ============================================================
  # Sort operations
  # ============================================================

  def sort(coll) when is_list(coll), do: Enum.sort(coll)
  def sort(coll) when is_binary(coll), do: Enum.sort(Normalize.graphemes(coll))

  def sort(comp, coll) when is_list(coll) do
    Enum.sort(coll, wrap_comparator(comp))
  end

  def sort(comp, coll) when is_binary(coll) do
    Enum.sort(Normalize.graphemes(coll), wrap_comparator(comp))
  end

  def sort_by(_keyfn, nil), do: []

  # sort_by with 2 args: (keyfn/key, coll)
  def sort_by(key, coll)
      when is_list(coll) and (is_atom(key) or is_binary(key) or is_list(key)) do
    Enum.sort_by(coll, &FlexAccess.flex_get(&1, key))
  end

  def sort_by(keyfn, coll) when is_list(coll) do
    Enum.sort_by(coll, &Callable.call(keyfn, [&1]))
  end

  def sort_by(keyfn, coll) when is_binary(coll) do
    Enum.sort_by(Normalize.graphemes(coll), &Callable.call(keyfn, [&1]))
  end

  def sort_by(keyfn, %MapSet{} = set), do: sort_by(keyfn, MapSet.to_list(set))

  def sort_by(keyfn, coll) when is_map(coll) and not is_struct(coll) do
    coll
    |> Enum.sort_by(fn {k, v} -> Callable.call(keyfn, [[k, v]]) end)
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  # sort_by with 3 args: (keyfn/key, comparator, coll)
  def sort_by(key, comp, coll)
      when is_list(coll) and (is_atom(key) or is_binary(key) or is_list(key)) do
    Enum.sort_by(coll, &FlexAccess.flex_get(&1, key), wrap_comparator(comp))
  end

  def sort_by(keyfn, comp, coll) when is_list(coll) do
    Enum.sort_by(coll, &Callable.call(keyfn, [&1]), wrap_comparator(comp))
  end

  def sort_by(keyfn, comp, %MapSet{} = set), do: sort_by(keyfn, comp, MapSet.to_list(set))

  def sort_by(keyfn, comp, coll) when is_map(coll) and not is_struct(coll) do
    coll
    |> Enum.sort_by(fn {k, v} -> Callable.call(keyfn, [[k, v]]) end, wrap_comparator(comp))
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def reverse(coll) when is_list(coll), do: Enum.reverse(coll)
  def reverse(coll) when is_binary(coll), do: Enum.reverse(Normalize.graphemes(coll))

  # ============================================================
  # Access operations
  # ============================================================

  def first(nil), do: nil
  def first(coll) when is_list(coll), do: List.first(coll)
  def first(coll) when is_binary(coll), do: String.at(coll, 0)

  def second(nil), do: nil
  def second(coll) when is_list(coll), do: Enum.at(coll, 1)
  def second(coll) when is_binary(coll), do: String.at(coll, 1)

  def last(coll) when is_list(coll), do: List.last(coll)
  def last(coll) when is_binary(coll), do: String.at(coll, -1)

  def nth(coll, idx) when is_list(coll), do: Enum.at(coll, idx)
  def nth(coll, idx) when is_binary(coll), do: String.at(coll, idx)

  # rest - always returns list (empty list for empty/single-element collections)
  def rest(nil), do: []
  def rest(coll) when is_list(coll), do: Enum.drop(coll, 1)
  def rest(coll) when is_binary(coll), do: Enum.drop(Normalize.graphemes(coll), 1)

  # butlast - all but last element (empty list for empty/single-element collections)
  def butlast(nil), do: []
  def butlast(coll) when is_list(coll), do: Enum.drop(coll, -1)
  def butlast(coll) when is_binary(coll), do: Enum.drop(Normalize.graphemes(coll), -1)

  # take-last - returns last n items (n <= 0 returns [])
  def take_last(_n, nil), do: []
  def take_last(n, _coll) when n <= 0, do: []
  def take_last(n, coll) when is_list(coll), do: Enum.take(coll, -n)
  def take_last(n, coll) when is_binary(coll), do: Enum.take(Normalize.graphemes(coll), -n)

  def take_last(n, coll) when is_map(coll) and not is_struct(coll),
    do: take_last(n, Normalize.to_seq(coll))

  # drop-last - removes last n items (default 1, n <= 0 returns full collection)
  def drop_last(nil), do: []
  def drop_last(coll) when is_list(coll), do: Enum.drop(coll, -1)
  def drop_last(coll) when is_binary(coll), do: Enum.drop(Normalize.graphemes(coll), -1)

  def drop_last(coll) when is_map(coll) and not is_struct(coll),
    do: drop_last(Normalize.to_seq(coll))

  def drop_last(_n, nil), do: []
  def drop_last(n, coll) when n <= 0 and is_list(coll), do: coll
  def drop_last(n, coll) when n <= 0 and is_binary(coll), do: Normalize.graphemes(coll)
  def drop_last(n, coll) when is_list(coll), do: Enum.drop(coll, -n)
  def drop_last(n, coll) when is_binary(coll), do: Enum.drop(Normalize.graphemes(coll), -n)

  def drop_last(n, coll) when is_map(coll) and not is_struct(coll),
    do: drop_last(n, Normalize.to_seq(coll))

  # next - returns nil for empty/single-element collections
  def next(nil), do: nil

  def next(coll) when is_list(coll) do
    case Enum.drop(coll, 1) do
      [] -> nil
      tail -> tail
    end
  end

  def next(coll) when is_binary(coll) do
    case Enum.drop(Normalize.graphemes(coll), 1) do
      [] -> nil
      tail -> tail
    end
  end

  # Composed accessors for nested collections
  def ffirst(coll) when is_list(coll), do: first(first(coll))
  def fnext(coll) when is_list(coll), do: first(next(coll))
  def nfirst(coll) when is_list(coll), do: next(first(coll))
  def nnext(coll) when is_list(coll), do: next(next(coll))

  # ============================================================
  # Positional slice
  # ============================================================

  def take(n, coll) when is_list(coll), do: Enum.take(coll, n)
  def take(n, coll) when is_binary(coll), do: Enum.take(Normalize.graphemes(coll), n)

  def take(n, coll) when is_map(coll) and not is_struct(coll) do
    coll |> Enum.take(n) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def drop(n, coll) when is_list(coll), do: Enum.drop(coll, n)
  def drop(n, coll) when is_binary(coll), do: Enum.drop(Normalize.graphemes(coll), n)

  def drop(n, coll) when is_map(coll) and not is_struct(coll) do
    coll |> Enum.drop(n) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  # ============================================================
  # Distinct
  # ============================================================

  def distinct(coll) when is_list(coll), do: Enum.uniq(coll)
  def distinct(coll) when is_binary(coll), do: Enum.uniq(Normalize.graphemes(coll))
  def distinct(coll) when is_map(coll) and not is_struct(coll), do: Normalize.to_seq(coll)

  # ============================================================
  # Construction
  # ============================================================

  def concat2(a, b) do
    a = a || []
    b = b || []
    ensure_enumerable!(a, "concat")
    ensure_enumerable!(b, "concat")
    Enum.concat(a, b)
  end

  @doc """
  Returns a new seq with item prepended.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.cons(1, [2, 3])
      [1, 2, 3]

      iex> PtcRunner.Lisp.Runtime.Collection.cons(1, nil)
      [1]
  """
  def cons(x, nil), do: [x]
  def cons(x, coll) when is_list(coll), do: [x | coll]
  def cons(x, %MapSet{} = set), do: [x | MapSet.to_list(set)]
  def cons(x, coll) when is_map(coll), do: [x | Enum.map(coll, fn {k, v} -> [k, v] end)]
  def cons(x, coll) when is_binary(coll), do: [x | Normalize.graphemes(coll)]

  def conj(nil, x), do: [x]
  def conj(list, x) when is_list(list), do: list ++ [x]
  def conj(%MapSet{} = set, x), do: MapSet.put(set, x)
  def conj(map, [k, v]) when is_map(map) and not is_struct(map), do: Map.put(map, k, v)

  def into(%MapSet{} = to, from) when is_map(from) and not is_struct(from) do
    Enum.into(Enum.map(from, fn {k, v} -> [k, v] end), to)
  end

  def into(%MapSet{} = to, from) do
    Enum.into(from || [], to)
  end

  def into(to, from) when is_map(to) and not is_struct(to) do
    source =
      case from do
        nil ->
          []

        %MapSet{} ->
          Enum.map(from, &entry_to_tuple/1)

        m when is_map(m) ->
          m

        l when is_list(l) ->
          Enum.map(l, &entry_to_tuple/1)

        _ ->
          from |> Enum.to_list() |> Enum.map(&entry_to_tuple/1)
      end

    Enum.into(source, to)
  end

  def into(to, from) when is_list(to) and is_map(from) do
    to ++ Enum.map(from, fn {k, v} -> [k, v] end)
  end

  def into(to, from) when is_list(to) do
    to ++ Enum.to_list(from || [])
  end

  defp entry_to_tuple([k, v]), do: {k, v}

  defp entry_to_tuple(item) do
    raise "type_error: into: invalid map entry: #{inspect(item)}. Expected [key, value] vector."
  end

  def flatten(coll) when is_list(coll), do: List.flatten(coll)

  def zip(c1, c2) when is_list(c1) and is_list(c2) do
    Enum.zip_with(c1, c2, fn a, b -> [a, b] end)
  end

  def interleave(c1, c2) when is_list(c1) and is_list(c2) do
    Enum.zip(c1, c2) |> Enum.flat_map(fn {a, b} -> [a, b] end)
  end

  @doc """
  Returns a list with sep inserted between each element.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.interpose(", ", ["a", "b", "c"])
      ["a", ", ", "b", ", ", "c"]

      iex> PtcRunner.Lisp.Runtime.Collection.interpose(:x, [1])
      [1]

      iex> PtcRunner.Lisp.Runtime.Collection.interpose(:x, [])
      []

      iex> PtcRunner.Lisp.Runtime.Collection.interpose(:x, nil)
      []

      iex> PtcRunner.Lisp.Runtime.Collection.interpose(nil, [1, 2, 3])
      [1, nil, 2, nil, 3]
  """
  def interpose(_sep, nil), do: []
  def interpose(sep, coll) when is_list(coll), do: Enum.intersperse(coll, sep)

  # ============================================================
  # Partition
  # ============================================================

  def partition(n, coll) do
    validate_n(n, "partition")
    Enum.chunk_every(Normalize.to_seq(coll), n, n, :discard)
  end

  def partition(n, step, coll) do
    validate_n(n, "partition")
    validate_step(step, "partition")
    Enum.chunk_every(Normalize.to_seq(coll), n, step, :discard)
  end

  def partition(n, step, pad, coll) do
    validate_n(n, "partition")
    validate_step(step, "partition")
    Enum.chunk_every(Normalize.to_seq(coll), n, step, pad)
  end

  # ============================================================
  # Partition-all
  # ============================================================

  def partition_all(n, coll) do
    validate_n(n, "partition-all")
    Enum.chunk_every(Normalize.to_seq(coll), n)
  end

  def partition_all(n, step, coll) do
    validate_n(n, "partition-all")
    validate_step(step, "partition-all")
    Enum.chunk_every(Normalize.to_seq(coll), n, step)
  end

  # ============================================================
  # Split / Partition-by / Dedupe
  # ============================================================

  def split_at(n, coll) do
    seq = Normalize.to_seq(coll)
    clamped = max(n, 0)
    {left, right} = Enum.split(seq, clamped)
    [left, right]
  end

  # Keyword on string: keyword access on graphemes always nil → nothing passes
  def split_with(pred, coll) when is_atom(pred) and is_binary(coll),
    do: [[], Normalize.graphemes(coll)]

  def split_with(pred, coll) do
    pred_fn = Normalize.normalize_pred(pred, :truthy)
    {left, right} = Enum.split_while(Normalize.to_seq(coll), pred_fn)
    [left, right]
  end

  def partition_by(f, coll) do
    keyfn = Normalize.normalize_keyfn(f)
    Enum.chunk_by(Normalize.to_seq(coll), keyfn)
  end

  def dedupe(coll) do
    Normalize.to_seq(coll) |> Enum.dedup()
  end

  # ============================================================
  # Empty / Peek / Pop / Subvec
  # ============================================================

  @doc """
  Returns an empty collection of the same type, or nil for nil input.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.empty([1, 2, 3])
      []

      iex> PtcRunner.Lisp.Runtime.Collection.empty(%{a: 1})
      %{}
  """
  def empty(nil), do: nil
  def empty(coll) when is_list(coll), do: []
  def empty(%MapSet{}), do: MapSet.new()
  def empty(coll) when is_map(coll), do: %{}
  def empty(coll) when is_binary(coll), do: ""

  @doc """
  Returns the last element of a vector without removing it.
  Returns nil for nil or empty collections.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.peek([1, 2, 3])
      3

      iex> PtcRunner.Lisp.Runtime.Collection.peek([])
      nil
  """
  def peek(nil), do: nil
  def peek([]), do: nil
  def peek(coll) when is_list(coll), do: List.last(coll)

  @doc """
  Returns the collection without the last element.
  Returns nil for nil. Returns nil for empty collections.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.pop([1, 2, 3])
      [1, 2]

      iex> PtcRunner.Lisp.Runtime.Collection.pop([])
      nil
  """
  def pop(nil), do: nil
  def pop([]), do: nil
  def pop([_]), do: []
  def pop(coll) when is_list(coll), do: Enum.slice(coll, 0..(length(coll) - 2)//1)

  @doc """
  Returns a subvector from start (inclusive) to end (exclusive).
  Clamps indices to valid range.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.subvec([0, 1, 2, 3, 4], 1, 3)
      [1, 2]

      iex> PtcRunner.Lisp.Runtime.Collection.subvec([0, 1, 2, 3, 4], 2)
      [2, 3, 4]
  """
  def subvec(coll, start) when is_list(coll) and is_integer(start) do
    subvec(coll, start, length(coll))
  end

  def subvec(coll, start, end_idx)
      when is_list(coll) and is_integer(start) and is_integer(end_idx) do
    len = length(coll)
    s = start |> max(0) |> min(len)
    e = end_idx |> max(0) |> min(len)

    if s >= e, do: [], else: Enum.slice(coll, s..(e - 1)//1)
  end

  @doc """
  Like filter but always returns a vector. In PTC-Lisp, this is
  equivalent to filter since all sequences are vectors.
  """
  def filterv(pred, coll), do: Select.filter(pred, coll)

  # ============================================================
  # Count
  # ============================================================

  def count(%MapSet{} = set), do: MapSet.size(set)
  def count(coll) when is_binary(coll), do: String.length(coll)
  def count(coll) when is_list(coll) or is_map(coll), do: Enum.count(coll)

  def empty?(nil), do: true
  def empty?(%MapSet{} = set), do: MapSet.size(set) == 0
  def empty?(coll) when is_binary(coll), do: coll == ""
  def empty?(coll) when is_list(coll) or is_map(coll), do: Enum.empty?(coll)

  def not_empty(coll) do
    if seq(coll), do: coll, else: nil
  end

  def seq(coll) when is_list(coll) do
    case coll do
      [] -> nil
      _ -> coll
    end
  end

  def seq(s) when is_binary(s) do
    case s do
      "" -> nil
      _ -> Normalize.graphemes(s)
    end
  end

  def seq(%MapSet{} = set) do
    case MapSet.size(set) == 0 do
      true -> nil
      false -> MapSet.to_list(set)
    end
  end

  def seq(m) when is_map(m) do
    case Enum.empty?(m) do
      true -> nil
      false -> Enum.map(m, fn {k, v} -> [k, v] end)
    end
  end

  def seq(nil), do: nil

  # ============================================================
  # Reduce
  # ============================================================

  # reduce with 2 args: (reduce f coll) - uses first element as initial value
  def reduce(f, coll) when is_list(coll) do
    case coll do
      [] -> nil
      [h | t] -> Enum.reduce(t, h, fn elem, acc -> Callable.call(f, [acc, elem]) end)
    end
  end

  def reduce(f, %MapSet{} = set) do
    case MapSet.to_list(set) do
      [] -> nil
      [h | t] -> Enum.reduce(t, h, fn elem, acc -> Callable.call(f, [acc, elem]) end)
    end
  end

  def reduce(f, coll) when is_map(coll) do
    case Map.to_list(coll) do
      [] ->
        nil

      [{k, v} | t] ->
        Enum.reduce(t, [k, v], fn {nk, nv}, acc -> Callable.call(f, [acc, [nk, nv]]) end)
    end
  end

  def reduce(f, coll) when is_binary(coll) do
    case Normalize.graphemes(coll) do
      [] -> nil
      [h | t] -> Enum.reduce(t, h, fn elem, acc -> Callable.call(f, [acc, elem]) end)
    end
  end

  # reduce with 3 args: (reduce f init coll)
  def reduce(f, init, coll) when is_list(coll) do
    Enum.reduce(coll, init, fn elem, acc -> Callable.call(f, [acc, elem]) end)
  end

  def reduce(f, init, %MapSet{} = set) do
    Enum.reduce(set, init, fn elem, acc -> Callable.call(f, [acc, elem]) end)
  end

  def reduce(f, init, coll) when is_map(coll) do
    Enum.reduce(coll, init, fn {k, v}, acc -> Callable.call(f, [acc, [k, v]]) end)
  end

  def reduce(f, init, coll) when is_binary(coll) do
    Enum.reduce(Normalize.graphemes(coll), init, fn elem, acc -> Callable.call(f, [acc, elem]) end)
  end

  # ============================================================
  # Aggregation
  # ============================================================

  def sum(coll) when is_list(coll) do
    coll |> Enum.reject(&is_nil/1) |> Enum.sum()
  end

  def sum(nil), do: 0

  def avg(coll) when is_list(coll) do
    values = Enum.reject(coll, &is_nil/1)

    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  def avg(nil), do: nil

  # sum_by: atom or string keys
  def sum_by(key, coll) when is_list(coll) and (is_atom(key) or is_binary(key)) do
    coll
    |> Enum.map(&FlexAccess.flex_get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  # sum_by: vector path keys like [:nested :key]
  def sum_by(path, coll) when is_list(path) and is_list(coll) do
    coll
    |> Enum.map(&FlexAccess.flex_get_in(&1, path))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  # sum_by: function/builtin
  def sum_by(keyfn, coll) when is_list(coll) do
    coll
    |> Enum.map(&Callable.call(keyfn, [&1]))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  def sum_by(key, %MapSet{} = set), do: sum_by(key, MapSet.to_list(set))

  def sum_by(key, coll) when is_map(coll) and not is_struct(coll),
    do: sum_by(key, Normalize.to_seq(coll))

  def sum_by(_key, nil), do: 0

  # avg_by: atom or string keys
  def avg_by(key, coll) when is_list(coll) and (is_atom(key) or is_binary(key)) do
    values = coll |> Enum.map(&FlexAccess.flex_get(&1, key)) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  # avg_by: vector path keys
  def avg_by(path, coll) when is_list(path) and is_list(coll) do
    values = coll |> Enum.map(&FlexAccess.flex_get_in(&1, path)) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  # avg_by: function/builtin
  def avg_by(keyfn, coll) when is_list(coll) do
    values = coll |> Enum.map(&Callable.call(keyfn, [&1])) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  def avg_by(key, %MapSet{} = set), do: avg_by(key, MapSet.to_list(set))

  def avg_by(key, coll) when is_map(coll) and not is_struct(coll),
    do: avg_by(key, Normalize.to_seq(coll))

  def avg_by(_key, nil), do: nil

  # min_by: atom or string keys
  def min_by(key, coll) when is_list(coll) and (is_atom(key) or is_binary(key)) do
    case Enum.reject(coll, &is_nil(FlexAccess.flex_get(&1, key))) do
      [] -> nil
      filtered -> Enum.min_by(filtered, &FlexAccess.flex_get(&1, key))
    end
  end

  # min_by: vector path keys
  def min_by(path, coll) when is_list(path) and is_list(coll) do
    case Enum.reject(coll, &is_nil(FlexAccess.flex_get_in(&1, path))) do
      [] -> nil
      filtered -> Enum.min_by(filtered, &FlexAccess.flex_get_in(&1, path))
    end
  end

  # min_by: function/builtin
  def min_by(keyfn, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(Callable.call(keyfn, [&1]))) do
      [] -> nil
      filtered -> Enum.min_by(filtered, &Callable.call(keyfn, [&1]))
    end
  end

  def min_by(key, %MapSet{} = set), do: min_by(key, MapSet.to_list(set))

  def min_by(key, coll) when is_map(coll) and not is_struct(coll),
    do: min_by(key, Normalize.to_seq(coll))

  def min_by(_key, nil), do: nil

  # max_by: atom or string keys
  def max_by(key, coll) when is_list(coll) and (is_atom(key) or is_binary(key)) do
    case Enum.reject(coll, &is_nil(FlexAccess.flex_get(&1, key))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, &FlexAccess.flex_get(&1, key))
    end
  end

  # max_by: vector path keys
  def max_by(path, coll) when is_list(path) and is_list(coll) do
    case Enum.reject(coll, &is_nil(FlexAccess.flex_get_in(&1, path))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, &FlexAccess.flex_get_in(&1, path))
    end
  end

  # max_by: function/builtin
  def max_by(keyfn, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(Callable.call(keyfn, [&1]))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, &Callable.call(keyfn, [&1]))
    end
  end

  def max_by(key, %MapSet{} = set), do: max_by(key, MapSet.to_list(set))

  def max_by(key, coll) when is_map(coll) and not is_struct(coll),
    do: max_by(key, Normalize.to_seq(coll))

  def max_by(_key, nil), do: nil

  # distinct_by: atom or string keys
  def distinct_by(key, coll) when is_list(coll) and (is_atom(key) or is_binary(key)) do
    Enum.uniq_by(coll, &FlexAccess.flex_get(&1, key))
  end

  # distinct_by: vector path keys
  def distinct_by(path, coll) when is_list(path) and is_list(coll) do
    Enum.uniq_by(coll, &FlexAccess.flex_get_in(&1, path))
  end

  # distinct_by: function/builtin
  def distinct_by(keyfn, coll) when is_list(coll) do
    Enum.uniq_by(coll, &Callable.call(keyfn, [&1]))
  end

  def distinct_by(key, %MapSet{} = set), do: distinct_by(key, MapSet.to_list(set))

  def distinct_by(key, coll) when is_map(coll) and not is_struct(coll),
    do: distinct_by(key, Normalize.to_seq(coll))

  def distinct_by(_key, nil), do: []

  @doc """
  Returns the x for which (f x) is greatest. Matches Clojure's max-key.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.max_key_variadic([&String.length/1, "a", "abc", "ab"])
      "abc"
  """
  def max_key_variadic([_f]) do
    raise ArgumentError, "max-key requires at least 2 arguments (function and one value)"
  end

  def max_key_variadic([_f, x]), do: x

  def max_key_variadic([f | args]) when args != [] do
    Enum.max_by(args, &Callable.call(f, [&1]))
  end

  @doc """
  Returns the x for which (f x) is least. Matches Clojure's min-key.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.min_key_variadic([&String.length/1, "a", "abc", "ab"])
      "a"
  """
  def min_key_variadic([_f]) do
    raise ArgumentError, "min-key requires at least 2 arguments (function and one value)"
  end

  def min_key_variadic([_f, x]), do: x

  def min_key_variadic([f | args]) when args != [] do
    Enum.min_by(args, &Callable.call(f, [&1]))
  end

  @doc """
  Variadic version of max-by that supports both (max-by key coll)
  and (apply max-by key item1 item2 ...).
  """
  def max_by_variadic([key, coll])
      when is_list(coll) or is_map(coll) or is_struct(coll, MapSet) do
    max_by(key, coll)
  end

  def max_by_variadic([key | items]) when items != [] do
    max_by(key, items)
  end

  def max_by_variadic(_) do
    raise ArgumentError, "max-by requires at least a key and one value or collection"
  end

  @doc """
  Variadic version of min-by that supports both (min-by key coll)
  and (apply min-by key item1 item2 ...).
  """
  def min_by_variadic([key, coll])
      when is_list(coll) or is_map(coll) or is_struct(coll, MapSet) do
    min_by(key, coll)
  end

  def min_by_variadic([key | items]) when items != [] do
    min_by(key, items)
  end

  def min_by_variadic(_) do
    raise ArgumentError, "min-by requires at least a key and one value or collection"
  end

  # group_by: atom or string keys
  def group_by(key, coll) when is_list(coll) and (is_atom(key) or is_binary(key)),
    do: Enum.group_by(coll, &FlexAccess.flex_get(&1, key))

  # group_by: vector path keys
  def group_by(path, coll) when is_list(path) and is_list(coll),
    do: Enum.group_by(coll, &FlexAccess.flex_get_in(&1, path))

  # group_by: function/builtin
  def group_by(keyfn, coll) when is_list(coll) do
    Enum.group_by(coll, &Callable.call(keyfn, [&1]))
  end

  def group_by(key, %MapSet{} = set), do: group_by(key, MapSet.to_list(set))

  def group_by(key, coll) when is_map(coll) and not is_struct(coll),
    do: group_by(key, Normalize.to_seq(coll))

  def group_by(_key, nil), do: %{}

  def frequencies(coll) when is_list(coll), do: Enum.frequencies(coll)
  def frequencies(coll) when is_binary(coll), do: Enum.frequencies(Normalize.graphemes(coll))

  # ============================================================
  # Membership
  # ============================================================

  def contains?(%MapSet{} = set, val), do: MapSet.member?(set, val)

  def contains?(coll, key) when is_map(coll) do
    cond do
      Map.has_key?(coll, key) -> true
      is_atom(key) -> Map.has_key?(coll, to_string(key))
      is_binary(key) -> Map.has_key?(coll, String.to_existing_atom(key))
      true -> false
    end
  rescue
    ArgumentError -> false
  end

  def contains?(coll, val) when is_list(coll), do: val in coll

  # ============================================================
  # Range
  # ============================================================

  def range(end_val), do: range(0, end_val, 1)
  def range(start, end_val), do: range(start, end_val, 1)

  def range(start, end_val, step)
      when is_number(start) and is_number(end_val) and is_number(step) do
    if step == 0 do
      []
    else
      generate_range(start, end_val, step, [])
    end
  end

  def range(_, _, _), do: []

  defp generate_range(curr, end_val, step, acc) do
    if (step > 0 and curr < end_val) or (step < 0 and curr > end_val) do
      generate_range(curr + step, end_val, step, [curr | acc])
    else
      Enum.reverse(acc)
    end
  end

  # ============================================================
  # Set Operations
  # ============================================================

  def intersection(%MapSet{} = s1, %MapSet{} = s2), do: MapSet.intersection(s1, s2)
  def union(%MapSet{} = s1, %MapSet{} = s2), do: MapSet.union(s1, s2)
  def difference(%MapSet{} = s1, %MapSet{} = s2), do: MapSet.difference(s1, s2)

  # ============================================================
  # Combinatorial Operations
  # ============================================================

  @doc """
  Generate all n-combinations from a collection.

  Works with any seqable: lists, strings, maps.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.combinations([1, 2, 3, 4], 3)
      [[1, 2, 3], [1, 2, 4], [1, 3, 4], [2, 3, 4]]

      iex> PtcRunner.Lisp.Runtime.Collection.combinations([1, 2], 0)
      [[]]

      iex> PtcRunner.Lisp.Runtime.Collection.combinations([1, 2], 3)
      []
  """
  def combinations(coll, n) when is_integer(n) and n >= 0 do
    case seq(coll) do
      nil -> if n == 0, do: [[]], else: []
      list -> do_combinations(list, n)
    end
  end

  def combinations(_coll, _n), do: []

  defp do_combinations(_, 0), do: [[]]
  defp do_combinations([], _), do: []

  defp do_combinations([h | t], n) do
    with_h = Enum.map(do_combinations(t, n - 1), &[h | &1])
    without_h = do_combinations(t, n)
    with_h ++ without_h
  end

  # ============================================================
  # Tree Traversal
  # ============================================================

  @doc """
  Generic tree walker. Applies inner to each element of form, then applies outer to the result.

  For lists, walks each element. For maps, walks each [key, value] pair.
  For sets, walks each element and reconstructs the set.
  For scalars, just applies outer.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.walk(&Function.identity/1, &Function.identity/1, [1, 2, 3])
      [1, 2, 3]

      iex> PtcRunner.Lisp.Runtime.Collection.walk(&Function.identity/1, &Enum.sum/1, [1, 2, 3])
      6
  """
  def walk(inner, outer, form) when is_list(form) do
    Callable.call(outer, [Enum.map(form, &Callable.call(inner, [&1]))])
  end

  def walk(inner, outer, %MapSet{} = form) do
    walked = form |> Enum.map(&Callable.call(inner, [&1])) |> MapSet.new()
    Callable.call(outer, [walked])
  end

  def walk(inner, outer, form) when is_map(form) and not is_struct(form) do
    walked =
      Enum.map(form, fn {k, v} ->
        result = Callable.call(inner, [[k, v]])

        case result do
          [wk, wv] -> {wk, wv}
          other -> raise "walk: inner function must return [key, value], got: #{inspect(other)}"
        end
      end)

    Callable.call(outer, [Map.new(walked)])
  end

  def walk(_inner, outer, form), do: Callable.call(outer, [form])

  @doc """
  Transform a tree top-down by applying f to each node before recursing into children.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.prewalk(&Function.identity/1, [1, [2, 3]])
      [1, [2, 3]]
  """
  def prewalk(f, form) do
    walked = Callable.call(f, [form])
    walk(&prewalk(f, &1), &Function.identity/1, walked)
  end

  @doc """
  Transform a tree bottom-up by applying f to each node after recursing into children.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Collection.postwalk(&Function.identity/1, [1, [2, 3]])
      [1, [2, 3]]
  """
  def postwalk(f, form) do
    walked = walk(&postwalk(f, &1), &Function.identity/1, form)
    Callable.call(f, [walked])
  end

  @doc """
  Returns a depth-first lazy sequence of all nodes in a tree.

  branch? is a predicate that returns true if a node has children.
  children returns the children of a branch node.

  When branch? or children is a keyword, it is used to access that key from maps.
  For branch?, the result is checked for truthiness.

  ## Examples

      iex> tree = %{id: 1, children: [%{id: 2, children: []}, %{id: 3, children: []}]}
      iex> result = PtcRunner.Lisp.Runtime.Collection.tree_seq(
      ...>   fn node -> is_map(node) && Map.has_key?(node, :children) end,
      ...>   fn node -> Map.get(node, :children, []) end,
      ...>   tree
      ...> )
      iex> Enum.map(result, & &1.id)
      [1, 2, 3]
  """
  def tree_seq(branch?, children, root) do
    branch_fn = to_callable(branch?)
    children_fn = to_callable(children)
    tree_seq_acc(branch_fn, children_fn, root, []) |> Enum.reverse()
  end

  defp to_callable(key) when is_atom(key), do: fn item -> FlexAccess.flex_get(item, key) end
  defp to_callable(f), do: f

  defp tree_seq_acc(branch_fn, children_fn, node, acc) do
    acc = [node | acc]

    if call_fn(branch_fn, node) do
      kids = call_fn(children_fn, node) || []
      Enum.reduce(kids, acc, &tree_seq_acc(branch_fn, children_fn, &1, &2))
    else
      acc
    end
  end

  defp call_fn(f, arg) when is_function(f, 1), do: f.(arg)
  defp call_fn(f, arg), do: Callable.call(f, [arg])

  defp ensure_enumerable!(val, _fn_name) when is_list(val), do: :ok
  defp ensure_enumerable!(val, _fn_name) when is_map(val) and not is_struct(val), do: :ok

  defp ensure_enumerable!(val, fn_name) do
    if Enumerable.impl_for(val) do
      :ok
    else
      raise PtcRunner.Lisp.TypeError,
            "#{fn_name} expected collections, got #{Helpers.describe_type(val)} #{inspect(val)}"
    end
  end
end
