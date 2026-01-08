defmodule PtcRunner.Lisp.Runtime.Collection do
  @moduledoc """
  Collection operations for PTC-Lisp runtime.

  Provides filtering, mapping, sorting, and other collection manipulation functions.
  """

  alias PtcRunner.Lisp.Runtime.FlexAccess

  # Convert string to list of graphemes for sequence operations
  defp graphemes(s), do: String.graphemes(s)

  defp truthy_key_pred(key), do: fn item -> !!FlexAccess.flex_get(item, key) end

  # Set-as-predicate: returns element if member, nil if not (used with filter/some/etc)
  defp set_pred(set), do: fn item -> if MapSet.member?(set, item), do: item, else: nil end

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

  defp wrap_comparator(other) do
    raise "type_error: invalid comparator: #{inspect(other)}. Expected :asc, :desc, or a function of 2 arguments."
  end

  defp vector_arg_error(v, type) when is_list(v) do
    msg =
      case v do
        [_] ->
          "expected #{type}, got vector #{inspect(v)} - use #{inspect(List.first(v))} instead"

        _ ->
          "expected #{type}, got path #{inspect(v)} - paths require a function or data-extraction variant"
      end

    raise "type_error: #{msg}"
  end

  def filter(pred, %MapSet{} = set), do: Enum.filter(set, pred)

  def filter(key, coll) when is_list(coll) and is_atom(key) do
    Enum.filter(coll, truthy_key_pred(key))
  end

  def filter(key, _coll) when is_list(key), do: vector_arg_error(key, "predicate")

  def filter(%MapSet{} = set, coll) when is_list(coll) do
    Enum.filter(coll, set_pred(set))
  end

  def filter(%MapSet{} = set, coll) when is_binary(coll) do
    Enum.filter(graphemes(coll), set_pred(set))
  end

  def filter(pred, coll) when is_list(coll), do: Enum.filter(coll, pred)
  def filter(pred, coll) when is_binary(coll), do: Enum.filter(graphemes(coll), pred)

  def filter(pred, coll) when is_map(coll) do
    # When filtering a map, each entry is passed as [key, value] pair
    # Returns a list of [key, value] pairs (not a map) per Clojure seqable semantics
    coll
    |> Enum.filter(fn {k, v} -> pred.([k, v]) end)
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def remove(pred, %MapSet{} = set), do: Enum.reject(set, pred)

  def remove(key, coll) when is_list(coll) and is_atom(key) do
    Enum.reject(coll, truthy_key_pred(key))
  end

  def remove(key, _coll) when is_list(key), do: vector_arg_error(key, "predicate")

  def remove(%MapSet{} = set, coll) when is_list(coll) do
    Enum.reject(coll, set_pred(set))
  end

  def remove(%MapSet{} = set, coll) when is_binary(coll) do
    Enum.reject(graphemes(coll), set_pred(set))
  end

  def remove(pred, coll) when is_list(coll), do: Enum.reject(coll, pred)
  def remove(pred, coll) when is_binary(coll), do: Enum.reject(graphemes(coll), pred)

  def remove(pred, coll) when is_map(coll) do
    # When removing from a map, each entry is passed as [key, value] pair
    # Returns a list of [key, value] pairs (not a map) per Clojure seqable semantics
    coll
    |> Enum.reject(fn {k, v} -> pred.([k, v]) end)
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def find(key, coll) when is_list(coll) and is_atom(key) do
    Enum.find(coll, truthy_key_pred(key))
  end

  def find(key, _coll) when is_list(key), do: vector_arg_error(key, "predicate")

  def find(%MapSet{} = set, coll) when is_list(coll) do
    Enum.find(coll, fn item -> MapSet.member?(set, item) end)
  end

  def find(pred, coll) when is_list(coll), do: Enum.find(coll, pred)
  def find(pred, coll) when is_binary(coll), do: Enum.find(graphemes(coll), pred)

  def map(key, coll) when is_list(coll) and is_atom(key),
    do: Enum.map(coll, &FlexAccess.flex_get(&1, key))

  def map(key, _coll) when is_list(key), do: vector_arg_error(key, "function or key")

  def map(%MapSet{} = set, coll) when is_list(coll), do: Enum.map(coll, set_pred(set))

  def map(%MapSet{} = set, coll) when is_binary(coll),
    do: Enum.map(graphemes(coll), set_pred(set))

  def map(f, coll) when is_list(coll), do: Enum.map(coll, f)
  def map(f, coll) when is_binary(coll), do: Enum.map(graphemes(coll), f)

  def map(f, %MapSet{} = set), do: Enum.map(set, f)

  def map(f, coll) when is_function(f, 1) and is_map(coll) do
    # When mapping over a map, each entry is passed as [key, value] pair
    Enum.map(coll, fn {k, v} -> f.([k, v]) end)
  end

  def mapv(key, coll) when is_list(coll) and is_atom(key),
    do: Enum.map(coll, &FlexAccess.flex_get(&1, key))

  def mapv(key, _coll) when is_list(key), do: vector_arg_error(key, "function or key")

  def mapv(%MapSet{} = set, coll) when is_list(coll), do: Enum.map(coll, set_pred(set))

  def mapv(%MapSet{} = set, coll) when is_binary(coll),
    do: Enum.map(graphemes(coll), set_pred(set))

  def mapv(f, coll) when is_list(coll), do: Enum.map(coll, f)
  def mapv(f, coll) when is_binary(coll), do: Enum.map(graphemes(coll), f)

  def mapv(f, %MapSet{} = set), do: Enum.map(set, f)

  def mapv(f, coll) when is_function(f, 1) and is_map(coll) do
    Enum.map(coll, fn {k, v} -> f.([k, v]) end)
  end

  def map_indexed(f, coll) when is_list(coll) do
    with_index_map(coll, f)
  end

  def map_indexed(f, coll) when is_binary(coll) do
    with_index_map(graphemes(coll), f)
  end

  def map_indexed(f, %MapSet{} = set) do
    with_index_map(set, f)
  end

  def map_indexed(f, coll) when is_map(coll) do
    coll
    |> Enum.with_index()
    |> Enum.map(fn {{k, v}, idx} -> f.(idx, [k, v]) end)
  end

  defp with_index_map(enumerable, f) do
    enumerable |> Enum.with_index() |> Enum.map(fn {item, idx} -> f.(idx, item) end)
  end

  def pluck(_key, nil), do: []
  def pluck(key, coll) when is_list(coll), do: Enum.map(coll, &FlexAccess.flex_get(&1, key))

  def sort(coll) when is_list(coll), do: Enum.sort(coll)
  def sort(coll) when is_binary(coll), do: Enum.sort(graphemes(coll))

  def sort(comp, coll) when is_list(coll) do
    Enum.sort(coll, wrap_comparator(comp))
  end

  def sort(comp, coll) when is_binary(coll) do
    Enum.sort(graphemes(coll), wrap_comparator(comp))
  end

  def sort_by(_keyfn, nil), do: []

  # sort_by with 2 args: (keyfn/key, coll)
  def sort_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    Enum.sort_by(coll, keyfn)
  end

  def sort_by(keyfn, coll) when is_binary(coll) and is_function(keyfn, 1) do
    Enum.sort_by(graphemes(coll), keyfn)
  end

  def sort_by(key, coll)
      when is_list(coll) and (is_atom(key) or is_binary(key) or is_list(key)) do
    Enum.sort_by(coll, &FlexAccess.flex_get(&1, key))
  end

  def sort_by(keyfn, coll) when is_map(coll) and is_function(keyfn, 1) do
    # When sorting a map, each entry is passed as [key, value] pair
    # Returns a list of [key, value] pairs (not a map) to preserve sort order
    coll
    |> Enum.sort_by(fn {k, v} -> keyfn.([k, v]) end)
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  # sort_by with 3 args: (keyfn/key, comparator, coll)
  def sort_by(keyfn, comp, coll)
      when is_list(coll) and is_function(keyfn, 1) do
    Enum.sort_by(coll, keyfn, wrap_comparator(comp))
  end

  def sort_by(key, comp, coll)
      when is_list(coll) and (is_atom(key) or is_binary(key) or is_list(key)) do
    Enum.sort_by(coll, &FlexAccess.flex_get(&1, key), wrap_comparator(comp))
  end

  def sort_by(keyfn, comp, coll)
      when is_map(coll) and is_function(keyfn, 1) do
    # When sorting a map with custom comparator, each entry is passed as [key, value] pair
    # Returns a list of [key, value] pairs (not a map) to preserve sort order
    coll
    |> Enum.sort_by(fn {k, v} -> keyfn.([k, v]) end, wrap_comparator(comp))
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def reverse(coll) when is_list(coll), do: Enum.reverse(coll)
  def reverse(coll) when is_binary(coll), do: Enum.reverse(graphemes(coll))

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
  def rest(coll) when is_binary(coll), do: Enum.drop(graphemes(coll), 1)

  # next - returns nil for empty/single-element collections
  def next(nil), do: nil

  def next(coll) when is_list(coll) do
    case Enum.drop(coll, 1) do
      [] -> nil
      tail -> tail
    end
  end

  def next(coll) when is_binary(coll) do
    case Enum.drop(graphemes(coll), 1) do
      [] -> nil
      tail -> tail
    end
  end

  # Composed accessors for nested collections
  def ffirst(coll) when is_list(coll), do: first(first(coll))
  def fnext(coll) when is_list(coll), do: first(next(coll))
  def nfirst(coll) when is_list(coll), do: next(first(coll))
  def nnext(coll) when is_list(coll), do: next(next(coll))

  def take(n, coll) when is_list(coll), do: Enum.take(coll, n)
  def take(n, coll) when is_binary(coll), do: Enum.take(graphemes(coll), n)

  def drop(n, coll) when is_list(coll), do: Enum.drop(coll, n)
  def drop(n, coll) when is_binary(coll), do: Enum.drop(graphemes(coll), n)

  def take_while(key, coll) when is_list(coll) and is_atom(key) do
    Enum.take_while(coll, truthy_key_pred(key))
  end

  def take_while(key, _coll) when is_list(key), do: vector_arg_error(key, "predicate")

  def take_while(key, coll) when is_binary(coll) and is_atom(key) do
    Enum.take_while(graphemes(coll), truthy_key_pred(key))
  end

  def take_while(pred, coll) when is_list(coll), do: Enum.take_while(coll, pred)

  def take_while(pred, coll) when is_binary(coll),
    do: Enum.take_while(graphemes(coll), pred)

  def drop_while(key, coll) when is_list(coll) and is_atom(key) do
    Enum.drop_while(coll, truthy_key_pred(key))
  end

  def drop_while(key, _coll) when is_list(key), do: vector_arg_error(key, "predicate")

  def drop_while(pred, coll) when is_list(coll), do: Enum.drop_while(coll, pred)

  def drop_while(pred, coll) when is_binary(coll),
    do: Enum.drop_while(graphemes(coll), pred)

  def distinct(coll) when is_list(coll), do: Enum.uniq(coll)
  def distinct(coll) when is_binary(coll), do: Enum.uniq(graphemes(coll))

  def concat2(a, b), do: Enum.concat(a || [], b || [])

  def conj(nil, x), do: [x]
  def conj(list, x) when is_list(list), do: list ++ [x]
  def conj(%MapSet{} = set, x), do: MapSet.put(set, x)
  def conj(map, [k, v]) when is_map(map) and not is_struct(map), do: Map.put(map, k, v)

  def into(%MapSet{} = to, from) when is_map(from) and not is_struct(from) do
    # When collecting from a map to a set, convert entries to [key, value] pairs
    Enum.into(Enum.map(from, fn {k, v} -> [k, v] end), to)
  end

  def into(%MapSet{} = to, from) do
    # Handles nil from gracefully (Enum.into(nil, set) works)
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
    # When collecting from a map, each entry is converted to [key, value] pair
    # Use ++ instead of Enum.into to avoid deprecation warning for non-empty lists
    to ++ Enum.map(from, fn {k, v} -> [k, v] end)
  end

  def into(to, from) when is_list(to) do
    # Use ++ instead of Enum.into to avoid deprecation warning for non-empty lists
    to ++ Enum.to_list(from || [])
  end

  defp entry_to_tuple([k, v]), do: {k, v}

  defp entry_to_tuple(item) do
    raise "type_error: into: invalid map entry: #{inspect(item)}. Expected [key, value] vector."
  end

  def flatten(coll) when is_list(coll), do: List.flatten(coll)

  def zip(c1, c2) when is_list(c1) and is_list(c2) do
    # Return vectors [a, b] instead of tuples {a, b} for consistency with PTC-Lisp data model
    Enum.zip_with(c1, c2, fn a, b -> [a, b] end)
  end

  def interleave(c1, c2) when is_list(c1) and is_list(c2) do
    Enum.zip(c1, c2) |> Enum.flat_map(fn {a, b} -> [a, b] end)
  end

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
      _ -> graphemes(s)
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

  # reduce with 2 args: (reduce f coll) - uses first element as initial value
  # Clojure: (f acc elem), Elixir: fn elem, acc -> ... end
  def reduce(f, coll) when is_list(coll) do
    case coll do
      [] -> nil
      [h | t] -> Enum.reduce(t, h, fn elem, acc -> f.(acc, elem) end)
    end
  end

  def reduce(f, %MapSet{} = set) do
    case MapSet.to_list(set) do
      [] -> nil
      [h | t] -> Enum.reduce(t, h, fn elem, acc -> f.(acc, elem) end)
    end
  end

  def reduce(f, coll) when is_map(coll) do
    case Map.to_list(coll) do
      [] -> nil
      [{k, v} | t] -> Enum.reduce(t, [k, v], fn {nk, nv}, acc -> f.(acc, [nk, nv]) end)
    end
  end

  def reduce(f, coll) when is_binary(coll) do
    case graphemes(coll) do
      [] -> nil
      [h | t] -> Enum.reduce(t, h, fn elem, acc -> f.(acc, elem) end)
    end
  end

  # reduce with 3 args: (reduce f init coll)
  # Clojure: (f acc elem), Elixir: fn elem, acc -> ... end
  def reduce(f, init, coll) when is_list(coll) do
    Enum.reduce(coll, init, fn elem, acc -> f.(acc, elem) end)
  end

  def reduce(f, init, %MapSet{} = set) do
    Enum.reduce(set, init, fn elem, acc -> f.(acc, elem) end)
  end

  def reduce(f, init, coll) when is_map(coll) do
    Enum.reduce(coll, init, fn {k, v}, acc -> f.(acc, [k, v]) end)
  end

  def reduce(f, init, coll) when is_binary(coll) do
    Enum.reduce(graphemes(coll), init, fn elem, acc -> f.(acc, elem) end)
  end

  def sum_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    coll
    |> Enum.map(keyfn)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  def sum_by(key, coll) when is_list(coll) do
    coll
    |> Enum.map(&FlexAccess.flex_get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  def sum_by(_key, nil), do: 0

  def avg_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    values = coll |> Enum.map(keyfn) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  def avg_by(key, coll) when is_list(coll) do
    values = coll |> Enum.map(&FlexAccess.flex_get(&1, key)) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  def avg_by(_key, nil), do: nil

  def min_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    case Enum.reject(coll, &is_nil(keyfn.(&1))) do
      [] -> nil
      filtered -> Enum.min_by(filtered, keyfn)
    end
  end

  def min_by(key, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(FlexAccess.flex_get(&1, key))) do
      [] -> nil
      filtered -> Enum.min_by(filtered, &FlexAccess.flex_get(&1, key))
    end
  end

  def min_by(_key, nil), do: nil

  def max_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    case Enum.reject(coll, &is_nil(keyfn.(&1))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, keyfn)
    end
  end

  def max_by(key, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(FlexAccess.flex_get(&1, key))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, &FlexAccess.flex_get(&1, key))
    end
  end

  def max_by(_key, nil), do: nil

  def group_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    Enum.group_by(coll, keyfn)
  end

  def group_by(key, coll) when is_list(coll),
    do: Enum.group_by(coll, &FlexAccess.flex_get(&1, key))

  def group_by(_key, nil), do: %{}

  def frequencies(coll) when is_list(coll), do: Enum.frequencies(coll)
  def frequencies(coll) when is_binary(coll), do: Enum.frequencies(graphemes(coll))

  def some(key, coll) when is_list(coll) and is_atom(key) do
    Enum.find_value(coll, truthy_key_pred(key))
  end

  def some(key, _coll) when is_list(key), do: vector_arg_error(key, "predicate")

  def some(%MapSet{} = set, coll) when is_list(coll) do
    Enum.find_value(coll, set_pred(set))
  end

  def some(pred, coll) when is_list(coll), do: Enum.find_value(coll, pred)
  def some(pred, coll) when is_binary(coll), do: Enum.find_value(graphemes(coll), pred)

  def every?(key, coll) when is_list(coll) and is_atom(key) do
    Enum.all?(coll, truthy_key_pred(key))
  end

  def every?(key, _coll) when is_list(key), do: vector_arg_error(key, "predicate")

  def every?(%MapSet{} = set, coll) when is_list(coll) do
    Enum.all?(coll, set_pred(set))
  end

  def every?(pred, coll) when is_list(coll), do: Enum.all?(coll, pred)
  def every?(pred, coll) when is_binary(coll), do: Enum.all?(graphemes(coll), pred)

  def not_any?(key, coll) when is_list(coll) and is_atom(key) do
    not Enum.any?(coll, truthy_key_pred(key))
  end

  def not_any?(key, _coll) when is_list(key), do: vector_arg_error(key, "predicate")

  def not_any?(%MapSet{} = set, coll) when is_list(coll) do
    not Enum.any?(coll, set_pred(set))
  end

  def not_any?(pred, coll) when is_list(coll), do: not Enum.any?(coll, pred)
  def not_any?(pred, coll) when is_binary(coll), do: not Enum.any?(graphemes(coll), pred)

  def contains?(%MapSet{} = set, val), do: MapSet.member?(set, val)

  def contains?(coll, key) when is_map(coll) do
    # Check both atom and string versions of the key
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

  # Range implementation
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
end
