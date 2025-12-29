defmodule PtcRunner.Lisp.Runtime do
  @moduledoc """
  Built-in functions for PTC-Lisp.

  Provides collection operations, map operations, arithmetic, and type predicates.
  """

  # ============================================================
  # Flexible Key Access Helper
  # ============================================================

  @doc """
  Flexible key access: try both atom and string versions of the key.
  Returns the value if found, nil if missing.
  Use this for simple lookups where you don't need to distinguish between nil values and missing keys.
  """
  def flex_get(%MapSet{}, _key), do: nil

  def flex_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  def flex_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        # Try converting string to existing atom (safe - won't create new atoms)
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  def flex_get(map, key) when is_map(map), do: Map.get(map, key)
  def flex_get(nil, _key), do: nil

  # ============================================================
  # Flexible Key Fetch (Public API)
  # ============================================================

  @doc """
  Flexible key fetch: try both atom and string versions of the key.
  Returns {:ok, value} if found, :error if missing.
  Use this when you need to distinguish between nil values and missing keys.
  """
  def flex_fetch(%MapSet{}, _key), do: :error

  def flex_fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, _} = ok -> ok
      :error -> Map.fetch(map, to_string(key))
    end
  end

  def flex_fetch(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, _} = ok ->
        ok

      :error ->
        try do
          Map.fetch(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> :error
        end
    end
  end

  def flex_fetch(map, key) when is_map(map), do: Map.fetch(map, key)
  def flex_fetch(nil, _key), do: :error

  @doc """
  Flexible nested key access: try both atom and string versions at each level.
  """
  def flex_get_in(data, []), do: data
  def flex_get_in(nil, _path), do: nil

  def flex_get_in(data, [key | rest]) when is_map(data) do
    case flex_fetch(data, key) do
      {:ok, value} -> flex_get_in(value, rest)
      :error -> nil
    end
  end

  def flex_get_in(_data, _path), do: nil

  @doc """
  Flexible nested key insertion: creates intermediate maps as needed at each level.
  Aligns with Clojure's assoc-in behavior.
  """
  def flex_put_in(_data, [], v), do: v
  def flex_put_in(nil, path, v), do: flex_put_in(%{}, path, v)

  def flex_put_in(data, [key | rest], v) when is_map(data) do
    case rest do
      [] ->
        # Last key in path: put the value
        Map.put(data, key, v)

      _ ->
        # More path to traverse: get or create intermediate map
        case flex_fetch(data, key) do
          {:ok, nested} when is_map(nested) ->
            # Key exists with a map value: recurse
            nested_result = flex_put_in(nested, rest, v)
            Map.put(data, key, nested_result)

          {:ok, _} ->
            # Key exists with a non-map value: can't traverse further
            raise ArgumentError,
                  "could not put/update key #{inspect(key)} on a non-map value"

          :error ->
            # Key missing: create new intermediate map
            nested_result = flex_put_in(%{}, rest, v)
            Map.put(data, key, nested_result)
        end
    end
  end

  @doc """
  Flexible nested key update: creates intermediate maps as needed at each level.
  Aligns with Clojure's update-in behavior.
  """
  def flex_update_in(data, [], f), do: f.(data)
  def flex_update_in(nil, path, f), do: flex_update_in(%{}, path, f)

  def flex_update_in(data, [key | rest], f) when is_map(data) do
    case rest do
      [] ->
        # Last key in path: update the value at this key
        old_val = flex_get(data, key)
        new_val = f.(old_val)
        Map.put(data, key, new_val)

      _ ->
        # More path to traverse: get or create intermediate map
        case flex_fetch(data, key) do
          {:ok, nested} when is_map(nested) ->
            # Key exists with a map value: recurse
            nested_result = flex_update_in(nested, rest, f)
            Map.put(data, key, nested_result)

          {:ok, _} ->
            # Key exists with a non-map value: can't traverse further
            raise ArgumentError,
                  "could not put/update key #{inspect(key)} on a non-map value"

          :error ->
            # Key missing: create new intermediate map and update
            nested_result = flex_update_in(%{}, rest, f)
            Map.put(data, key, nested_result)
        end
    end
  end

  # ============================================================
  # Collection Operations
  # ============================================================

  def filter(pred, %MapSet{} = set), do: Enum.filter(set, pred)
  def filter(pred, coll) when is_list(coll), do: Enum.filter(coll, pred)

  def filter(pred, coll) when is_map(coll) do
    # When filtering a map, each entry is passed as [key, value] pair
    # Returns a list of [key, value] pairs (not a map) per Clojure seqable semantics
    coll
    |> Enum.filter(fn {k, v} -> pred.([k, v]) end)
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def remove(pred, %MapSet{} = set), do: Enum.reject(set, pred)
  def remove(pred, coll) when is_list(coll), do: Enum.reject(coll, pred)

  def remove(pred, coll) when is_map(coll) do
    # When removing from a map, each entry is passed as [key, value] pair
    # Returns a list of [key, value] pairs (not a map) per Clojure seqable semantics
    coll
    |> Enum.reject(fn {k, v} -> pred.([k, v]) end)
    |> Enum.map(fn {k, v} -> [k, v] end)
  end

  def find(pred, coll) when is_list(coll), do: Enum.find(coll, pred)

  def map(f, coll) when is_list(coll), do: Enum.map(coll, f)

  def map(f, %MapSet{} = set), do: Enum.map(set, f)

  def map(f, coll) when is_map(coll) do
    # When mapping over a map, each entry is passed as [key, value] pair
    Enum.map(coll, fn {k, v} -> f.([k, v]) end)
  end

  def mapv(f, coll) when is_list(coll), do: Enum.map(coll, f)

  def mapv(f, %MapSet{} = set), do: Enum.map(set, f)

  def mapv(f, coll) when is_map(coll), do: Enum.map(coll, fn {k, v} -> f.([k, v]) end)
  def pluck(key, coll) when is_list(coll), do: Enum.map(coll, &flex_get(&1, key))

  def sort(coll) when is_list(coll), do: Enum.sort(coll)

  # sort_by with 2 args: (keyfn/key, coll)
  def sort_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    Enum.sort_by(coll, keyfn)
  end

  def sort_by(key, coll) when is_list(coll) and (is_atom(key) or is_binary(key)) do
    Enum.sort_by(coll, &flex_get(&1, key))
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
    Enum.sort_by(coll, &flex_get(&1, key), comp)
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
  def take(n, coll) when is_list(coll), do: Enum.take(coll, n)
  def drop(n, coll) when is_list(coll), do: Enum.drop(coll, n)
  def take_while(pred, coll) when is_list(coll), do: Enum.take_while(coll, pred)
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
  def reduce(f, coll) when is_list(coll) do
    case coll do
      [] -> nil
      [h | t] -> Enum.reduce(t, h, f)
    end
  end

  # reduce with 3 args: (reduce f init coll)
  def reduce(f, init, coll) when is_list(coll), do: Enum.reduce(coll, init, f)

  def sum_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    coll
    |> Enum.map(keyfn)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  def sum_by(key, coll) when is_list(coll) do
    coll
    |> Enum.map(&flex_get(&1, key))
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
    values = coll |> Enum.map(&flex_get(&1, key)) |> Enum.reject(&is_nil/1)

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
    case Enum.reject(coll, &is_nil(flex_get(&1, key))) do
      [] -> nil
      filtered -> Enum.min_by(filtered, &flex_get(&1, key))
    end
  end

  def max_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    case Enum.reject(coll, &is_nil(keyfn.(&1))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, keyfn)
    end
  end

  def max_by(key, coll) when is_list(coll) do
    case Enum.reject(coll, &is_nil(flex_get(&1, key))) do
      [] -> nil
      filtered -> Enum.max_by(filtered, &flex_get(&1, key))
    end
  end

  def group_by(keyfn, coll) when is_list(coll) and is_function(keyfn, 1) do
    Enum.group_by(coll, keyfn)
  end

  def group_by(key, coll) when is_list(coll), do: Enum.group_by(coll, &flex_get(&1, key))

  def some(pred, coll) when is_list(coll), do: Enum.find_value(coll, pred)
  def every?(pred, coll) when is_list(coll), do: Enum.all?(coll, pred)
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

  # ============================================================
  # Map Operations
  # ============================================================

  def get(m, k) when is_map(m), do: flex_get(m, k)
  def get(nil, _k), do: nil

  def get(m, k, default) when is_map(m) do
    cond do
      Map.has_key?(m, k) ->
        Map.get(m, k)

      is_atom(k) and Map.has_key?(m, to_string(k)) ->
        Map.get(m, to_string(k))

      is_binary(k) ->
        try do
          atom_key = String.to_existing_atom(k)
          if Map.has_key?(m, atom_key), do: Map.get(m, atom_key), else: default
        rescue
          ArgumentError -> default
        end

      true ->
        default
    end
  end

  def get(nil, _k, default), do: default

  def get_in(m, path) when is_map(m), do: flex_get_in(m, path)

  def get_in(m, path, default) when is_map(m) do
    case flex_get_in(m, path) do
      nil -> default
      val -> val
    end
  end

  def assoc(m, k, v), do: Map.put(m, k, v)
  def assoc_in(m, path, v), do: flex_put_in(m, path, v)

  def update(m, k, f) do
    old_val = Map.get(m, k)
    new_val = f.(old_val)
    Map.put(m, k, new_val)
  end

  def update_in(m, path, f), do: flex_update_in(m, path, f)
  def dissoc(m, k), do: Map.delete(m, k)
  def merge(m1, m2), do: Map.merge(m1, m2)

  def select_keys(m, ks) do
    Enum.reduce(ks, %{}, fn k, acc ->
      case flex_fetch(m, k) do
        {:ok, val} -> Map.put(acc, k, val)
        :error -> acc
      end
    end)
  end

  def keys(m), do: m |> Map.keys() |> Enum.sort()
  def vals(m), do: m |> Enum.sort_by(fn {k, _v} -> k end) |> Enum.map(fn {_k, v} -> v end)

  @doc """
  Convert map to a list of [key, value] pairs, sorted by key.
  """
  def entries(m) when is_map(m) do
    m |> Enum.sort_by(fn {k, _v} -> k end) |> Enum.map(fn {k, v} -> [k, v] end)
  end

  @doc """
  Apply a function to each value in a map, returning a new map with the same keys.
  Matches Clojure 1.11's update-vals signature: `(update-vals m f)`

  ## Examples

      iex> Runtime.update_vals(%{a: [1, 2], b: [3]}, &length/1)
      %{a: 2, b: 1}

      iex> Runtime.update_vals(%{}, &length/1)
      %{}
  """
  def update_vals(m, f) when is_map(m) and is_function(f, 1) do
    Map.new(m, fn {k, v} -> {k, f.(v)} end)
  end

  def update_vals(nil, _f), do: nil

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

  @doc """
  Identity function: returns its argument unchanged.
  Useful as a default function argument or for composition.
  """
  def identity(x), do: x

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  # ============================================================
  # String Manipulation
  # ============================================================

  @doc """
  Convert one or more values to string and concatenate.
  - (str) returns ""
  - (str "hello") returns "hello"
  - (str "a" "b") returns "ab"
  - (str 42) returns "42"
  - (str nil) returns "" (not "nil")
  - (str :keyword) returns ":keyword"
  - (str true) returns "true"

  Binary reducer used with :variadic binding type.
  """
  def str2(a, b), do: to_str(a) <> to_str(b)

  defp to_str(nil), do: ""
  defp to_str(s) when is_binary(s), do: s
  defp to_str(atom) when is_atom(atom), do: inspect(atom)
  defp to_str(x), do: inspect(x)

  @doc """
  Return substring starting at index (2-arity) or from start to end (3-arity).
  - (subs "hello" 1) returns "ello"
  - (subs "hello" 1 3) returns "el"
  - (subs "hello" 0 0) returns ""
  - Out of bounds returns truncated result
  - Negative indices are clamped to 0
  """
  def subs(s, start) when is_binary(s) and is_integer(start) do
    start = max(0, start)
    String.slice(s, start..-1//1)
  end

  def subs(s, start, end_idx) when is_binary(s) and is_integer(start) and is_integer(end_idx) do
    start = max(0, start)
    len = max(0, end_idx - start)
    String.slice(s, start, len)
  end

  @doc """
  Join a collection into a string with optional separator.
  - (join ["a" "b" "c"]) returns "abc"
  - (join ", " ["a" "b" "c"]) returns "a, b, c"
  - (join "-" [1 2 3]) returns "1-2-3"
  - (join ", " []) returns ""
  """
  def join(coll) when is_list(coll) do
    Enum.map_join(coll, &to_str/1)
  end

  def join(separator, coll) when is_binary(separator) and is_list(coll) do
    Enum.map_join(coll, separator, &to_str/1)
  end

  @doc """
  Split a string by separator.
  - (split "a,b,c" ",") returns ["a" "b" "c"]
  - (split "hello" "") returns ["h" "e" "l" "l" "o"]
  - (split "a,,b" ",") returns ["a" "" "b"]
  """
  def split(s, separator) when is_binary(s) and is_binary(separator) do
    if separator == "" do
      s |> String.graphemes()
    else
      String.split(s, separator)
    end
  end

  @doc """
  Trim leading and trailing whitespace.
  - (trim "  hello  ") returns "hello"
  - (trim "\n\t text \r\n") returns "text"
  """
  def trim(s) when is_binary(s) do
    String.trim(s)
  end

  @doc """
  Replace all occurrences of a pattern in a string.
  - (replace "hello" "l" "L") returns "heLLo"
  - (replace "aaa" "a" "b") returns "bbb"
  """
  def replace(s, pattern, replacement)
      when is_binary(s) and is_binary(pattern) and is_binary(replacement) do
    String.replace(s, pattern, replacement)
  end

  # ============================================================
  # String Parsing
  # ============================================================

  @doc """
  Parse string to integer. Returns nil on failure.
  Matches Clojure 1.11+ parse-long behavior.
  """
  def parse_long(nil), do: nil

  def parse_long(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def parse_long(_), do: nil

  @doc """
  Parse string to float. Returns nil on failure.
  Matches Clojure 1.11+ parse-double behavior.
  """
  def parse_double(nil), do: nil

  def parse_double(s) when is_binary(s) do
    case Float.parse(s) do
      {f, ""} -> f
      _ -> nil
    end
  end

  def parse_double(_), do: nil

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

  def set?(x), do: is_struct(x, MapSet)

  def map?(x), do: is_map(x) and not is_struct(x, MapSet)

  def coll?(x), do: is_list(x)

  @doc "Convert collection to set"
  def set(coll) when is_list(coll), do: MapSet.new(coll)
  def set(%MapSet{} = set), do: set

  # ============================================================
  # Numeric Predicates
  # ============================================================

  def zero?(x), do: x == 0
  def pos?(x), do: x > 0
  def neg?(x), do: x < 0
  def even?(x), do: rem(x, 2) == 0
  def odd?(x), do: rem(x, 2) != 0
end
