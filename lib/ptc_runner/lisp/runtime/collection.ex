defmodule PtcRunner.Lisp.Runtime.Collection do
  @moduledoc """
  Collection operations for PTC-Lisp runtime.

  Provides filtering, mapping, sorting, and other collection manipulation functions.
  """

  alias PtcRunner.Lisp.Runtime.FlexAccess

  defp truthy_key_pred(key), do: fn item -> !!FlexAccess.flex_get(item, key) end

  # Set-as-predicate: returns element if member, nil if not (used with filter/some/etc)
  defp set_pred(set), do: fn item -> if MapSet.member?(set, item), do: item, else: nil end

  def filter(pred, %MapSet{} = set), do: Enum.filter(set, pred)

  def filter(key, coll) when is_list(coll) and is_atom(key) do
    Enum.filter(coll, truthy_key_pred(key))
  end

  def filter(%MapSet{} = set, coll) when is_list(coll) do
    Enum.filter(coll, set_pred(set))
  end

  def filter(pred, coll) when is_list(coll), do: Enum.filter(coll, pred)

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

  def remove(%MapSet{} = set, coll) when is_list(coll) do
    Enum.reject(coll, set_pred(set))
  end

  def remove(pred, coll) when is_list(coll), do: Enum.reject(coll, pred)

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

  def find(%MapSet{} = set, coll) when is_list(coll) do
    Enum.find(coll, fn item -> MapSet.member?(set, item) end)
  end

  def find(pred, coll) when is_list(coll), do: Enum.find(coll, pred)

  def map(key, coll) when is_list(coll) and is_atom(key),
    do: Enum.map(coll, &FlexAccess.flex_get(&1, key))

  def map(f, coll) when is_list(coll), do: Enum.map(coll, f)

  def map(f, %MapSet{} = set), do: Enum.map(set, f)

  def map(f, coll) when is_map(coll) do
    # When mapping over a map, each entry is passed as [key, value] pair
    Enum.map(coll, fn {k, v} -> f.([k, v]) end)
  end

  def mapv(key, coll) when is_list(coll) and is_atom(key),
    do: Enum.map(coll, &FlexAccess.flex_get(&1, key))

  def mapv(f, coll) when is_list(coll), do: Enum.map(coll, f)

  def mapv(f, %MapSet{} = set), do: Enum.map(set, f)

  def mapv(f, coll) when is_map(coll), do: Enum.map(coll, fn {k, v} -> f.([k, v]) end)

  def pluck(key, coll) when is_list(coll), do: Enum.map(coll, &FlexAccess.flex_get(&1, key))

  def sort(coll) when is_list(coll), do: Enum.sort(coll)

  # sort_by with 2 args: (keyfn/key, coll)
  def sort_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    Enum.sort_by(coll, keyfn)
  end

  def sort_by(key, coll) when is_list(coll) and (is_atom(key) or is_binary(key)) do
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
      when is_list(coll) and is_function(keyfn, 1) and is_function(comp) do
    Enum.sort_by(coll, keyfn, comp)
  end

  def sort_by(key, comp, coll)
      when is_list(coll) and (is_atom(key) or is_binary(key)) and is_function(comp) do
    Enum.sort_by(coll, &FlexAccess.flex_get(&1, key), comp)
  end

  def sort_by(keyfn, comp, coll)
      when is_map(coll) and is_function(keyfn, 1) and is_function(comp) do
    # When sorting a map with custom comparator, each entry is passed as [key, value] pair
    # Returns a list of [key, value] pairs (not a map) to preserve sort order
    coll
    |> Enum.sort_by(fn {k, v} -> keyfn.([k, v]) end, comp)
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def reverse(coll) when is_list(coll), do: Enum.reverse(coll)

  def first(coll) when is_list(coll), do: List.first(coll)
  def second(coll) when is_list(coll), do: Enum.at(coll, 1)
  def last(coll) when is_list(coll), do: List.last(coll)
  def nth(coll, idx) when is_list(coll), do: Enum.at(coll, idx)

  # rest - always returns list (empty list for empty/single-element collections)
  def rest(coll) when is_list(coll), do: Enum.drop(coll, 1)

  # next - returns nil for empty/single-element collections
  def next(coll) when is_list(coll) do
    case Enum.drop(coll, 1) do
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
  def drop(n, coll) when is_list(coll), do: Enum.drop(coll, n)

  def take_while(key, coll) when is_list(coll) and is_atom(key) do
    Enum.take_while(coll, truthy_key_pred(key))
  end

  def take_while(pred, coll) when is_list(coll), do: Enum.take_while(coll, pred)

  def drop_while(key, coll) when is_list(coll) and is_atom(key) do
    Enum.drop_while(coll, truthy_key_pred(key))
  end

  def drop_while(pred, coll) when is_list(coll), do: Enum.drop_while(coll, pred)

  def distinct(coll) when is_list(coll), do: Enum.uniq(coll)

  def concat2(a, b), do: Enum.concat(a || [], b || [])

  def conj(nil, x), do: [x]
  def conj(list, x) when is_list(list), do: list ++ [x]
  def conj(%MapSet{} = set, x), do: MapSet.put(set, x)
  def conj(map, [k, v]) when is_map(map) and not is_struct(map), do: Map.put(map, k, v)

  def into(to, from) when is_list(to) and is_map(from) do
    # When collecting from a map, each entry is converted to [key, value] pair
    # Use ++ instead of Enum.into to avoid deprecation warning for non-empty lists
    to ++ Enum.map(from, fn {k, v} -> [k, v] end)
  end

  def into(to, from) when is_list(to) do
    # Use ++ instead of Enum.into to avoid deprecation warning for non-empty lists
    to ++ Enum.to_list(from)
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

  def count(coll) when is_list(coll) or is_map(coll) or is_binary(coll) do
    Enum.count(coll)
  end

  def empty?(%MapSet{} = set), do: MapSet.size(set) == 0

  def empty?(coll) when is_list(coll) or is_map(coll) or is_binary(coll) do
    Enum.empty?(coll)
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
      _ -> String.graphemes(s)
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

  # reduce with 3 args: (reduce f init coll)
  # Clojure: (f acc elem), Elixir: fn elem, acc -> ... end
  def reduce(f, init, coll) when is_list(coll) do
    Enum.reduce(coll, init, fn elem, acc -> f.(acc, elem) end)
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

  def group_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    Enum.group_by(coll, keyfn)
  end

  def group_by(key, coll) when is_list(coll),
    do: Enum.group_by(coll, &FlexAccess.flex_get(&1, key))

  def some(key, coll) when is_list(coll) and is_atom(key) do
    Enum.find_value(coll, truthy_key_pred(key))
  end

  def some(%MapSet{} = set, coll) when is_list(coll) do
    Enum.find_value(coll, set_pred(set))
  end

  def some(pred, coll) when is_list(coll), do: Enum.find_value(coll, pred)

  def every?(key, coll) when is_list(coll) and is_atom(key) do
    Enum.all?(coll, truthy_key_pred(key))
  end

  def every?(%MapSet{} = set, coll) when is_list(coll) do
    Enum.all?(coll, set_pred(set))
  end

  def every?(pred, coll) when is_list(coll), do: Enum.all?(coll, pred)

  def not_any?(key, coll) when is_list(coll) and is_atom(key) do
    not Enum.any?(coll, truthy_key_pred(key))
  end

  def not_any?(%MapSet{} = set, coll) when is_list(coll) do
    not Enum.any?(coll, set_pred(set))
  end

  def not_any?(pred, coll) when is_list(coll), do: not Enum.any?(coll, pred)

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
end
