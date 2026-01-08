defmodule PtcRunner.Lisp.Runtime.MapOps do
  @moduledoc """
  Map operations for PTC-Lisp runtime.

  Provides get, assoc, update, merge, and other map manipulation functions.
  """

  alias PtcRunner.Lisp.ExecutionError
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

  @doc """
  Associate key-value pairs with a map.

  Supports both standard 3-arg form and variadic form with multiple pairs:
  - (assoc m k v)
  - (assoc m k1 v1 k2 v2 k3 v3)

  ## Examples

      iex> PtcRunner.Lisp.Runtime.MapOps.assoc_variadic([%{a: 1}, :b, 2])
      %{a: 1, b: 2}

      iex> PtcRunner.Lisp.Runtime.MapOps.assoc_variadic([%{}, :a, 1, :b, 2, :c, 3])
      %{a: 1, b: 2, c: 3}
  """
  def assoc_variadic([m | pairs]) when rem(length(pairs), 2) == 0 do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(m, fn [k, v], acc -> Map.put(acc, k, v) end)
  end

  def assoc_variadic(args) do
    raise ArgumentError, "assoc requires a map and key-value pairs, got #{length(args)} args"
  end

  # Keep the 3-arg version for direct calls
  def assoc(m, k, v), do: Map.put(m, k, v)
  def assoc_in(m, path, v), do: FlexAccess.flex_put_in(m, path, v)

  @doc """
  Update a value in a map by applying a function.

  Supports Clojure-style extra arguments that are passed to the function:
  - (update m k f) - calls (f old-val)
  - (update m k f arg1) - calls (f old-val arg1)
  - (update m k f arg1 arg2) - calls (f old-val arg1 arg2)

  ## Examples

      iex> PtcRunner.Lisp.Runtime.MapOps.update_variadic([%{n: 1}, :n, &Kernel.+/2, 5])
      %{n: 6}

      iex> PtcRunner.Lisp.Runtime.MapOps.update_variadic([%{n: nil}, :n, &PtcRunner.Lisp.Runtime.Predicates.fnil(&Kernel.+/2, 0), 5])
      %{n: 5}
  """
  def update_variadic([m, k, f]) do
    old_val = Map.get(m, k)
    new_val = apply_with_arity_check(f, [old_val], "update")
    Map.put(m, k, new_val)
  end

  def update_variadic([m, k, f | extra_args]) do
    old_val = Map.get(m, k)
    new_val = apply_with_arity_check(f, [old_val | extra_args], "update")
    Map.put(m, k, new_val)
  end

  # Keep 3-arg version for direct calls
  def update(m, k, f) do
    old_val = Map.get(m, k)
    new_val = apply_with_arity_check(f, [old_val], "update")
    Map.put(m, k, new_val)
  end

  @doc """
  Update a nested value in a map by applying a function.

  Supports Clojure-style extra arguments that are passed to the function:
  - (update-in m path f) - calls (f old-val)
  - (update-in m path f arg1) - calls (f old-val arg1)

  ## Examples

      iex> PtcRunner.Lisp.Runtime.MapOps.update_in_variadic([%{a: %{b: 1}}, [:a, :b], &Kernel.+/2, 5])
      %{a: %{b: 6}}
  """
  def update_in_variadic([m, path, f]) do
    FlexAccess.flex_update_in(m, path, fn old_val ->
      apply_with_arity_check(f, [old_val], "update-in")
    end)
  end

  def update_in_variadic([m, path, f | extra_args]) do
    FlexAccess.flex_update_in(m, path, fn old_val ->
      apply_with_arity_check(f, [old_val | extra_args], "update-in")
    end)
  end

  def update_in(m, path, f) do
    FlexAccess.flex_update_in(m, path, fn old_val ->
      apply_with_arity_check(f, [old_val], "update-in")
    end)
  end

  @doc """
  Remove keys from a map.

  Supports both 2-arg form and variadic form with multiple keys:
  - (dissoc m k)
  - (dissoc m k1 k2 k3)

  ## Examples

      iex> PtcRunner.Lisp.Runtime.MapOps.dissoc_variadic([%{a: 1, b: 2}, :a])
      %{b: 2}

      iex> PtcRunner.Lisp.Runtime.MapOps.dissoc_variadic([%{a: 1, b: 2, c: 3}, :a, :c])
      %{b: 2}
  """
  def dissoc_variadic([m | keys]) do
    Enum.reduce(keys, m, fn k, acc -> Map.delete(acc, k) end)
  end

  # Keep the 2-arg version for direct calls
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

  # Helper to apply a function with proper arity error handling
  defp apply_with_arity_check(f, args, context) do
    apply(f, args)
  rescue
    e in BadArityError ->
      # Extract arity info from the error
      expected = :erlang.fun_info(e.function, :arity) |> elem(1)
      got = length(args)

      msg =
        "#{context}: function expects #{expected} argument(s) but was called with #{got}. " <>
          arity_hint(expected, got, context)

      reraise ExecutionError.exception(reason: :arity_error, message: msg, data: nil),
              __STACKTRACE__
  end

  defp arity_hint(expected, got, context) when got > expected do
    extra = got - expected

    case extra do
      1 ->
        "The extra argument may have been intended as a default value, " <>
          "but #{context} passes extra args to the function. " <>
          "Use (or current-val default) inside the function, or wrap with fnil."

      _ ->
        "Extra arguments are passed to the function, not used as defaults."
    end
  end

  defp arity_hint(_, _, _), do: ""
end
