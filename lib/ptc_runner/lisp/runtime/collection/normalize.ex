defmodule PtcRunner.Lisp.Runtime.Collection.Normalize do
  @moduledoc """
  Predicate and collection normalization helpers for collection operations.

  Collapses the combinatorial explosion of pred types x collection types
  into two reusable normalization functions.
  """

  alias PtcRunner.Lisp.Runtime.Callable
  alias PtcRunner.Lisp.Runtime.FlexAccess

  @doc "Convert string to list of graphemes."
  def graphemes(s), do: String.graphemes(s)

  @doc "Normalize any collection to a list. Maps become `[k, v]` pairs."
  def to_seq(nil), do: []
  def to_seq(coll) when is_list(coll), do: coll
  def to_seq(coll) when is_binary(coll), do: graphemes(coll)
  def to_seq(%MapSet{} = set), do: MapSet.to_list(set)

  def to_seq(m) when is_map(m) and not is_struct(m) do
    Enum.map(m, fn {k, v} -> [k, v] end)
  end

  def to_seq(other) do
    if Enumerable.impl_for(other) do
      Enum.to_list(other)
    else
      raise "type_error: invalid argument types for collection operation, got #{inspect(other)}"
    end
  end

  @doc """
  Normalize a predicate to a 1-arity function.

  Mode `:truthy` returns a boolean-coercing function (for filter, remove, find,
  every?, not_any?, take_while, drop_while).
  Mode `:value` returns a value-extracting function (for some, keep).
  """
  def normalize_pred(key, :truthy) when is_atom(key),
    do: fn item -> !!FlexAccess.flex_get(item, key) end

  def normalize_pred(key, :value) when is_atom(key),
    do: fn item -> FlexAccess.flex_get(item, key) end

  def normalize_pred(%MapSet{} = set, _mode),
    do: fn item -> if MapSet.member?(set, item), do: item, else: nil end

  def normalize_pred(key, _mode) when is_list(key),
    do: vector_arg_error(key, "predicate")

  def normalize_pred(pred, _mode),
    do: fn item -> Callable.call(pred, [item]) end

  @doc """
  Normalize a key/function to a 1-arity value-extracting function.

  Same as `normalize_pred/2` with `:value` mode but with a different
  vector error message ("function or key" vs "predicate").
  """
  def normalize_keyfn(key) when is_atom(key),
    do: fn item -> FlexAccess.flex_get(item, key) end

  def normalize_keyfn(%MapSet{} = set),
    do: fn item -> if MapSet.member?(set, item), do: item, else: nil end

  def normalize_keyfn(key) when is_list(key),
    do: vector_arg_error(key, "function or key")

  def normalize_keyfn(f),
    do: fn item -> Callable.call(f, [item]) end

  @doc "Raise a type error for vector used where predicate/function expected."
  def vector_arg_error(v, type) when is_list(v) do
    msg =
      case v do
        [_] ->
          "expected #{type}, got vector #{inspect(v)} - use #{inspect(List.first(v))} instead"

        _ ->
          "expected #{type}, got path #{inspect(v)} - paths require a function or data-extraction variant"
      end

    raise "type_error: #{msg}"
  end
end
