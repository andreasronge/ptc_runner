defmodule PtcRunner.Lisp.Runtime do
  @moduledoc """
  Built-in functions for PTC-Lisp.

  Provides collection operations, map operations, arithmetic, and type predicates.
  """

  # ============================================================
  # Flexible Key Access Helper
  # ============================================================

  # Try atom key first, fall back to string key
  defp flex_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp flex_get(map, key) when is_map(map), do: Map.get(map, key)
  defp flex_get(nil, _key), do: nil

  # ============================================================
  # Collection Operations
  # ============================================================

  def filter(pred, coll) when is_list(coll), do: Enum.filter(coll, pred)
  def remove(pred, coll) when is_list(coll), do: Enum.reject(coll, pred)
  def find(pred, coll) when is_list(coll), do: Enum.find(coll, pred)

  def map(f, coll) when is_list(coll), do: Enum.map(coll, f)

  def map(f, coll) when is_map(coll) do
    # When mapping over a map, each entry is passed as [key, value] pair
    Enum.map(coll, fn {k, v} -> f.([k, v]) end)
  end

  def mapv(f, coll) when is_list(coll), do: Enum.map(coll, f)
  def mapv(f, coll) when is_map(coll), do: Enum.map(coll, fn {k, v} -> f.([k, v]) end)
  def pluck(key, coll) when is_list(coll), do: Enum.map(coll, &flex_get(&1, key))

  def sort(coll) when is_list(coll), do: Enum.sort(coll)

  def sort_by(key, coll) when is_list(coll) and is_atom(key) do
    Enum.sort_by(coll, &flex_get(&1, key))
  end

  def sort_by(key, comp, coll) when is_list(coll) and is_atom(key) and is_function(comp) do
    Enum.sort_by(coll, &flex_get(&1, key), comp)
  end

  def reverse(coll) when is_list(coll), do: Enum.reverse(coll)

  def first(coll) when is_list(coll), do: List.first(coll)
  def last(coll) when is_list(coll), do: List.last(coll)
  def nth(coll, idx) when is_list(coll), do: Enum.at(coll, idx)
  def take(n, coll) when is_list(coll), do: Enum.take(coll, n)
  def drop(n, coll) when is_list(coll), do: Enum.drop(coll, n)
  def take_while(pred, coll) when is_list(coll), do: Enum.take_while(coll, pred)
  def drop_while(pred, coll) when is_list(coll), do: Enum.drop_while(coll, pred)
  def distinct(coll) when is_list(coll), do: Enum.uniq(coll)

  def concat2(a, b), do: Enum.concat(a || [], b || [])
  def into(to, from) when is_list(to), do: Enum.into(from, to)
  def flatten(coll) when is_list(coll), do: List.flatten(coll)
  def zip(c1, c2) when is_list(c1) and is_list(c2), do: Enum.zip(c1, c2)

  def interleave(c1, c2) when is_list(c1) and is_list(c2) do
    Enum.zip(c1, c2) |> Enum.flat_map(fn {a, b} -> [a, b] end)
  end

  def count(coll) when is_list(coll) or is_map(coll) or is_binary(coll) do
    Enum.count(coll)
  end

  def empty?(coll) when is_list(coll) or is_map(coll) or is_binary(coll) do
    Enum.empty?(coll)
  end

  def reduce(f, init, coll) when is_list(coll), do: Enum.reduce(coll, init, f)

  def sum_by(key, coll) when is_list(coll) do
    coll
    |> Enum.map(&flex_get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  def avg_by(key, coll) when is_list(coll) do
    values = coll |> Enum.map(&flex_get(&1, key)) |> Enum.reject(&is_nil/1)

    case values do
      [] -> nil
      vs -> Enum.sum(vs) / length(vs)
    end
  end

  def min_by(key, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(flex_get(&1, key))) do
      [] -> nil
      filtered -> Enum.min_by(filtered, &flex_get(&1, key))
    end
  end

  def max_by(key, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(flex_get(&1, key))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, &flex_get(&1, key))
    end
  end

  def group_by(key, coll) when is_list(coll), do: Enum.group_by(coll, &flex_get(&1, key))

  def some(pred, coll) when is_list(coll), do: Enum.any?(coll, pred)
  def every?(pred, coll) when is_list(coll), do: Enum.all?(coll, pred)
  def not_any?(pred, coll) when is_list(coll), do: not Enum.any?(coll, pred)
  def contains?(coll, key) when is_map(coll), do: Map.has_key?(coll, key)
  def contains?(coll, val) when is_list(coll), do: val in coll

  # ============================================================
  # Map Operations
  # ============================================================

  def get(m, k) when is_map(m), do: Map.get(m, k)
  def get(nil, _k), do: nil

  def get(m, k, default) when is_map(m), do: Map.get(m, k, default)
  def get(nil, _k, default), do: default

  def get_in(m, path) when is_map(m), do: Kernel.get_in(m, path)

  def get_in(m, path, default) when is_map(m) do
    case Kernel.get_in(m, path) do
      nil -> default
      val -> val
    end
  end

  def assoc(m, k, v), do: Map.put(m, k, v)
  def assoc_in(m, path, v), do: put_in(m, path, v)
  def update(m, k, f), do: Map.update!(m, k, f)
  def update_in(m, path, f), do: Kernel.update_in(m, path, f)
  def dissoc(m, k), do: Map.delete(m, k)
  def merge(m1, m2), do: Map.merge(m1, m2)
  def select_keys(m, ks), do: Map.take(m, ks)
  def keys(m), do: Map.keys(m)
  def vals(m), do: Map.values(m)

  # ============================================================
  # Arithmetic
  # ============================================================

  def add(args), do: Enum.sum(args)

  def subtract([x]), do: -x
  def subtract([x | rest]), do: x - Enum.sum(rest)

  def multiply(args), do: Enum.reduce(args, 1, &*/2)
  def divide(x, y), do: x / y
  def mod(x, y), do: rem(x, y)
  def inc(x), do: x + 1
  def dec(x), do: x - 1
  def abs(x), do: Kernel.abs(x)
  def max(args), do: Enum.max(args)
  def min(args), do: Enum.min(args)

  # ============================================================
  # Comparison (for direct use, not inside where)
  # ============================================================

  def not_eq(x, y), do: x != y

  # ============================================================
  # Logic
  # ============================================================

  def not_(x), do: not truthy?(x)

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  # ============================================================
  # Type Predicates
  # ============================================================

  def nil?(x), do: is_nil(x)
  def some?(x), do: not is_nil(x)
  def boolean?(x), do: is_boolean(x)
  def number?(x), do: is_number(x)
  def string?(x), do: is_binary(x)
  def keyword?(x), do: is_atom(x) and not is_nil(x) and not is_boolean(x)
  def vector?(x), do: is_list(x)
  def map?(x), do: is_map(x)
  def coll?(x), do: is_list(x)

  # ============================================================
  # Numeric Predicates
  # ============================================================

  def zero?(x), do: x == 0
  def pos?(x), do: x > 0
  def neg?(x), do: x < 0
  def even?(x), do: rem(x, 2) == 0
  def odd?(x), do: rem(x, 2) != 0
end
