defmodule PtcRunner.Lisp.Runtime.FlexAccess do
  @moduledoc """
  Flexible key access helpers for PTC-Lisp runtime.

  These helpers allow accessing map keys using either atom or string versions,
  providing seamless interoperability between different key formats.
  """

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

  def flex_get(nil, path) when is_list(path), do: nil
  def flex_get(map, path) when is_map(map) and is_list(path), do: flex_get_in(map, path)
  def flex_get(map, key) when is_map(map), do: Map.get(map, key)
  def flex_get(nil, _key), do: nil

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

  def flex_fetch(nil, path) when is_list(path), do: :error
  def flex_fetch(map, path) when is_map(map) and is_list(path), do: flex_fetch_in(map, path)
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
  Flexible nested key fetch: try both atom and string versions at each level.
  Returns {:ok, value} if found, :error if missing.
  """
  def flex_fetch_in(data, []), do: {:ok, data}
  def flex_fetch_in(nil, _path), do: :error

  def flex_fetch_in(data, [key | rest]) when is_map(data) do
    case flex_fetch(data, key) do
      {:ok, value} -> flex_fetch_in(value, rest)
      :error -> :error
    end
  end

  def flex_fetch_in(_data, _path), do: :error

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
end
