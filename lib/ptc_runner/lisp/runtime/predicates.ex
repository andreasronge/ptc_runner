defmodule PtcRunner.Lisp.Runtime.Predicates do
  @moduledoc """
  Type predicates, numeric predicates, and logic operations for PTC-Lisp runtime.

  Provides type checking functions (nil?, string?, map?, etc.) and numeric predicates
  (zero?, pos?, neg?, even?, odd?).
  """

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
