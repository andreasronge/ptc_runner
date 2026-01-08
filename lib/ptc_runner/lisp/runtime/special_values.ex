defmodule PtcRunner.Lisp.Runtime.SpecialValues do
  @moduledoc """
  Unified handling for IEEE 754 special values (Infinity, NaN) in PTC-Lisp.
  """

  @infinity :infinity
  @negative_infinity :negative_infinity
  @nan :nan

  def nan?(x), do: x == @nan
  def infinite?(x), do: x == @infinity or x == @negative_infinity
  def pos_infinite?(x), do: x == @infinity
  def neg_infinite?(x), do: x == @negative_infinity

  def special?(x), do: nan?(x) or infinite?(x)

  @doc """
  Propagation rules: any NaN input results in NaN.
  """
  def any_nan?(args) when is_list(args), do: Enum.any?(args, &nan?/1)
  def any_nan?(x, y), do: nan?(x) or nan?(y)

  @doc """
  Check if any argument is infinite.
  """
  def any_infinite?(args) when is_list(args), do: Enum.any?(args, &infinite?/1)
  def any_infinite?(x, y), do: infinite?(x) or infinite?(y)
end
