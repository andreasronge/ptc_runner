defmodule PtcRunner.Lisp.Runtime.Math do
  @moduledoc """
  Arithmetic operations for PTC-Lisp runtime.

  Provides basic math operations: addition, subtraction, multiplication, division,
  and utility functions like floor, ceil, round, etc.
  """

  alias PtcRunner.Lisp.Runtime.SpecialValues

  def add(args) when is_list(args) do
    if SpecialValues.any_nan?(args) do
      :nan
    else
      # Check for mixed infinities: (+ Inf -Inf) -> NaN
      has_pos = Enum.any?(args, &SpecialValues.pos_infinite?/1)
      has_neg = Enum.any?(args, &SpecialValues.neg_infinite?/1)

      cond do
        has_pos and has_neg -> :nan
        has_pos -> :infinity
        has_neg -> :negative_infinity
        true -> Enum.sum(args)
      end
    end
  end

  def add(x, y), do: add([x, y])

  def subtract([x]) do
    case x do
      :nan -> :nan
      :infinity -> :negative_infinity
      :negative_infinity -> :infinity
      _ -> -x
    end
  end

  def subtract([x | rest]) do
    cond do
      SpecialValues.any_nan?([x | rest]) ->
        :nan

      SpecialValues.infinite?(x) and SpecialValues.any_infinite?(rest) ->
        # (+ Inf Inf) or (-Inf -Inf) is fine, but subtract is (x - rest)
        # So (+ Inf - rest_with_inf) is (+ Inf - Inf) -> NaN
        # and (-Inf - rest_with_inf) is (-Inf + Inf) -> NaN
        :nan

      SpecialValues.pos_infinite?(x) ->
        :infinity

      SpecialValues.neg_infinite?(x) ->
        :negative_infinity

      SpecialValues.any_infinite?(rest) ->
        # number - Inf -> -Inf
        # number - (-Inf) -> Inf
        if Enum.any?(rest, &SpecialValues.pos_infinite?/1),
          do: :negative_infinity,
          else: :infinity

      true ->
        x - Enum.sum(rest)
    end
  end

  def subtract(x, y), do: subtract([x, y])

  def multiply(args) when is_list(args) do
    cond do
      SpecialValues.any_nan?(args) ->
        :nan

      # 0 * Inf -> NaN
      Enum.any?(args, &(&1 == 0)) and SpecialValues.any_infinite?(args) ->
        :nan

      SpecialValues.any_infinite?(args) ->
        # Calculate sign
        neg_count =
          Enum.count(args, fn
            n when is_number(n) -> n < 0
            :negative_infinity -> true
            _ -> false
          end)

        if rem(neg_count, 2) == 0, do: :infinity, else: :negative_infinity

      true ->
        Enum.reduce(args, 1, &*/2)
    end
  end

  def multiply(x, y), do: multiply([x, y])

  def divide(x, y) do
    cond do
      SpecialValues.nan?(x) or SpecialValues.nan?(y) -> :nan
      x == 0 and y == 0 -> :nan
      y == 0 -> divide_by_zero(x)
      SpecialValues.infinite?(x) and SpecialValues.infinite?(y) -> :nan
      SpecialValues.infinite?(x) -> divide_infinite_by_number(x, y)
      SpecialValues.infinite?(y) -> 0.0
      true -> x / y
    end
  end

  defp divide_by_zero(x) when x > 0, do: :infinity
  defp divide_by_zero(x) when x < 0, do: :negative_infinity
  defp divide_by_zero(_), do: :nan

  defp divide_infinite_by_number(x, y) do
    neg = (is_number(y) and y < 0) or x == :negative_infinity
    if neg, do: :negative_infinity, else: :infinity
  end

  @doc """
  Remainder with truncated division (toward zero).

  The result has the same sign as the dividend (x).
  Matches Clojure's `rem` function.
  """
  def remainder(x, y) do
    cond do
      SpecialValues.special?(x) or SpecialValues.special?(y) -> :nan
      y == 0 -> raise ArithmeticError, "division by zero"
      is_float(x) or is_float(y) -> :math.fmod(x, y)
      true -> Kernel.rem(x, y)
    end
  end

  @doc """
  Modulus with floored division (toward negative infinity).

  The result has the same sign as the divisor (y).
  Matches Clojure's `mod` function.
  """
  def mod(x, y) do
    cond do
      SpecialValues.special?(x) or SpecialValues.special?(y) -> :nan
      y == 0 -> raise ArithmeticError, "division by zero"
      is_float(x) or is_float(y) -> floored_mod_float(x, y)
      true -> Integer.mod(x, y)
    end
  end

  @doc """
  Integer division (quotient), truncating toward zero.

  Matches Clojure's `quot` function.

  ## Examples

      iex> PtcRunner.Lisp.Runtime.Math.quot(7, 2)
      3

      iex> PtcRunner.Lisp.Runtime.Math.quot(-7, 2)
      -3

      iex> PtcRunner.Lisp.Runtime.Math.quot(7.5, 2)
      3
  """
  def quot(x, y) do
    cond do
      SpecialValues.special?(x) or SpecialValues.special?(y) -> :nan
      y == 0 -> raise ArithmeticError, "division by zero"
      is_integer(x) and is_integer(y) -> Kernel.div(x, y)
      true -> Kernel.trunc(x / y)
    end
  end

  defp floored_mod_float(x, y) do
    x - y * :math.floor(x / y)
  end

  def inc(x) do
    case x do
      :nan -> :nan
      :infinity -> :infinity
      :negative_infinity -> :negative_infinity
      _ -> x + 1
    end
  end

  def dec(x) do
    case x do
      :nan -> :nan
      :infinity -> :infinity
      :negative_infinity -> :negative_infinity
      _ -> x - 1
    end
  end

  def abs(x) do
    case x do
      :nan -> :nan
      :infinity -> :infinity
      :negative_infinity -> :infinity
      _ -> Kernel.abs(x)
    end
  end

  def max(x, y) do
    cond do
      SpecialValues.nan?(x) or SpecialValues.nan?(y) -> :nan
      compare(x, y) >= 0 -> x
      true -> y
    end
  end

  def min(x, y) do
    cond do
      SpecialValues.nan?(x) or SpecialValues.nan?(y) -> :nan
      compare(x, y) <= 0 -> x
      true -> y
    end
  end

  def floor(x) do
    if SpecialValues.special?(x), do: x, else: Kernel.floor(x)
  end

  def ceil(x) do
    if SpecialValues.special?(x), do: x, else: Kernel.ceil(x)
  end

  def round(x) do
    if SpecialValues.special?(x), do: x, else: Kernel.round(x)
  end

  def trunc(x) do
    if SpecialValues.special?(x), do: x, else: Kernel.trunc(x)
  end

  def double(x) do
    case x do
      :nan -> :nan
      :infinity -> :infinity
      :negative_infinity -> :negative_infinity
      n when is_number(n) -> n / 1
    end
  end

  # float/1 is an alias for double/1 for Clojure compatibility
  # (Clojure has both float and double, but Elixir floats are always 64-bit)
  def float(x), do: double(x)

  def int(x) do
    case x do
      :nan -> raise ArithmeticError, "cannot convert NaN to integer"
      :infinity -> raise ArithmeticError, "cannot convert Infinity to integer"
      :negative_infinity -> raise ArithmeticError, "cannot convert -Infinity to integer"
      n when is_number(n) -> Kernel.trunc(n)
    end
  end

  def sqrt(x) do
    cond do
      SpecialValues.nan?(x) -> :nan
      SpecialValues.neg_infinite?(x) -> :nan
      SpecialValues.pos_infinite?(x) -> :infinity
      x < 0 -> :nan
      true -> :math.sqrt(x)
    end
  end

  def pow(_x, 0), do: 1.0
  def pow(1, _y), do: 1.0

  def pow(x, y) do
    cond do
      SpecialValues.nan?(x) or SpecialValues.nan?(y) -> :nan
      SpecialValues.pos_infinite?(x) -> pow_pos_inf_base(y)
      SpecialValues.neg_infinite?(x) -> pow_neg_inf_base(y)
      SpecialValues.pos_infinite?(y) -> pow_pos_inf_exp(x)
      SpecialValues.neg_infinite?(y) -> pow_neg_inf_exp(x)
      true -> :math.pow(x, y)
    end
  end

  defp pow_pos_inf_base(y) when y > 0, do: :infinity
  defp pow_pos_inf_base(_y), do: 0.0

  defp pow_neg_inf_base(y) when y < 0, do: 0.0
  defp pow_neg_inf_base(y) when is_integer(y) and rem(y, 2) != 0, do: :negative_infinity
  defp pow_neg_inf_base(_y), do: :infinity

  defp pow_pos_inf_exp(x) when Kernel.abs(x) > 1, do: :infinity
  defp pow_pos_inf_exp(x) when Kernel.abs(x) < 1, do: 0.0
  defp pow_pos_inf_exp(_x), do: 1.0

  defp pow_neg_inf_exp(x) when Kernel.abs(x) > 1, do: 0.0
  defp pow_neg_inf_exp(x) when Kernel.abs(x) < 1, do: :infinity
  defp pow_neg_inf_exp(_x), do: 1.0

  # Comparison (for direct use, not inside where)
  def not_eq(x, y), do: not eq(x, y)

  def eq(x, y) do
    if SpecialValues.nan?(x) or SpecialValues.nan?(y), do: false, else: x == y
  end

  def lt(x, y) do
    cond do
      SpecialValues.nan?(x) or SpecialValues.nan?(y) -> false
      SpecialValues.neg_infinite?(x) -> not SpecialValues.neg_infinite?(y)
      SpecialValues.pos_infinite?(y) -> not SpecialValues.pos_infinite?(x)
      SpecialValues.pos_infinite?(x) -> false
      SpecialValues.neg_infinite?(y) -> false
      true -> x < y
    end
  end

  def gt(x, y), do: lt(y, x)

  def lte(x, y) do
    if SpecialValues.nan?(x) or SpecialValues.nan?(y), do: false, else: not gt(x, y)
  end

  def gte(x, y) do
    if SpecialValues.nan?(x) or SpecialValues.nan?(y), do: false, else: not lt(x, y)
  end

  def compare(x, y) do
    cond do
      SpecialValues.nan?(x) or SpecialValues.nan?(y) ->
        # Standard IEEE 754: comparison with NaN is false/unordered.
        # but compare/2 usually returns -1, 0, 1.
        # For sort consistency, we raise.
        raise "type_error: compare: unordered comparison with NaN"

      eq(x, y) ->
        0

      lt(x, y) ->
        -1

      true ->
        1
    end
  end
end
