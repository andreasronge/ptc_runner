defmodule PtcRunner.Lisp.Runtime.Math do
  @moduledoc """
  Arithmetic operations for PTC-Lisp runtime.

  Provides basic math operations: addition, subtraction, multiplication, division,
  and utility functions like floor, ceil, round, etc.
  """

  def add(args), do: Enum.sum(args)

  def subtract([x]), do: -x
  def subtract([x | rest]), do: x - Enum.sum(rest)

  def multiply(args), do: Enum.reduce(args, 1, &*/2)
  def divide(x, y), do: x / y
  def mod(x, y), do: rem(x, y)
  def inc(x), do: x + 1
  def dec(x), do: x - 1
  def abs(x), do: Kernel.abs(x)
  def max(x, y), do: Kernel.max(x, y)
  def min(x, y), do: Kernel.min(x, y)
  def floor(x), do: Kernel.floor(x)
  def ceil(x), do: Kernel.ceil(x)
  def round(x), do: Kernel.round(x)
  def trunc(x), do: Kernel.trunc(x)
  def double(x) when is_number(x), do: x / 1
  def int(x) when is_number(x), do: Kernel.trunc(x)
  def sqrt(x), do: :math.sqrt(x)
  def pow(x, y), do: :math.pow(x, y)

  # Comparison (for direct use, not inside where)
  def not_eq(x, y), do: x != y
end
