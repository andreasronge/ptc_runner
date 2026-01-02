defmodule PtcRunner.Lisp.Runtime.MapOps do
  @moduledoc """
  Map operations for PTC-Lisp runtime.

  Provides get, assoc, update, merge, and other map manipulation functions.
  """

  alias PtcRunner.Lisp.Runtime.FlexAccess

  def get(m, k) when is_map(m), do: FlexAccess.flex_get(m, k)
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

  def get_in(m, path) when is_map(m), do: FlexAccess.flex_get_in(m, path)

  def get_in(m, path, default) when is_map(m) do
    case FlexAccess.flex_get_in(m, path) do
      nil -> default
      val -> val
    end
  end

  def assoc(m, k, v), do: Map.put(m, k, v)
  def assoc_in(m, path, v), do: FlexAccess.flex_put_in(m, path, v)

  def update(m, k, f) do
    old_val = Map.get(m, k)
    new_val = f.(old_val)
    Map.put(m, k, new_val)
  end

  def update_in(m, path, f), do: FlexAccess.flex_update_in(m, path, f)
  def dissoc(m, k), do: Map.delete(m, k)
  def merge(m1, m2), do: Map.merge(m1, m2)

  def select_keys(m, ks) do
    Enum.reduce(ks, %{}, fn k, acc ->
      case FlexAccess.flex_fetch(m, k) do
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

      iex> PtcRunner.Lisp.Runtime.MapOps.update_vals(%{a: [1, 2], b: [3]}, &length/1)
      %{a: 2, b: 1}

      iex> PtcRunner.Lisp.Runtime.MapOps.update_vals(%{}, &length/1)
      %{}
  """
  def update_vals(m, f) when is_map(m) and is_function(f, 1) do
    Map.new(m, fn {k, v} -> {k, f.(v)} end)
  end

  def update_vals(nil, _f), do: nil
end
