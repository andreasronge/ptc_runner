defmodule PtcRunner.Lisp.Runtime.JavaMathSemantics do
  @moduledoc """
  Pure numeric semantics shared by Java `Math` dispatch and the bare PTC
  `pow`/`sqrt` helpers.

  The special-value table follows `java.lang.Math` while representing NaN and
  infinities with PTC-Lisp's recoverable signal atoms.
  """

  alias PtcRunner.Lisp.Runtime.SpecialValues

  @spec sqrt(number() | atom()) :: float() | atom()
  def sqrt(x) do
    cond do
      SpecialValues.nan?(x) -> :nan
      SpecialValues.neg_infinite?(x) -> :nan
      SpecialValues.pos_infinite?(x) -> :infinity
      x < 0 -> :nan
      true -> :math.sqrt(x)
    end
  end

  @spec pow(number() | atom(), number() | atom()) :: float() | atom()
  def pow(x, y), do: do_pow(pow_coerce(x), pow_coerce(y))

  defp pow_coerce(n) when is_integer(n) do
    n * 1.0
  rescue
    ArithmeticError -> if n > 0, do: :infinity, else: :negative_infinity
  end

  defp pow_coerce(n), do: n

  defp do_pow(_x, y) when y == 0, do: 1.0

  defp do_pow(x, y) do
    cond do
      SpecialValues.nan?(y) -> :nan
      SpecialValues.nan?(x) -> :nan
      SpecialValues.infinite?(y) and abs_one?(x) -> :nan
      SpecialValues.pos_infinite?(y) -> pow_pos_inf_exp(x)
      SpecialValues.neg_infinite?(y) -> pow_neg_inf_exp(x)
      SpecialValues.pos_infinite?(x) -> pow_pos_inf_base(y)
      SpecialValues.neg_infinite?(x) -> pow_neg_inf_base(y)
      x == 0 and y < 0 -> pow_zero_base_neg_exp(x, y)
      x < 0 and not integer_valued?(y) -> :nan
      true -> pow_finite(x, y)
    end
  end

  defp pow_finite(x, y) do
    :math.pow(x, y)
  rescue
    ArithmeticError ->
      if x < 0 and odd_exponent?(y), do: :negative_infinity, else: :infinity
  end

  defp odd_exponent?(y) do
    yf = y * 1.0
    Kernel.trunc(yf) == yf and rem(Kernel.trunc(yf), 2) != 0
  end

  defp abs_one?(x), do: is_number(x) and Kernel.abs(x) == 1

  defp integer_valued?(y) when is_integer(y), do: true
  defp integer_valued?(y) when is_float(y), do: Kernel.trunc(y) == y
  defp integer_valued?(_y), do: false

  defp pow_zero_base_neg_exp(x, y) do
    if negative_zero?(x) and odd_exponent?(y),
      do: :negative_infinity,
      else: :infinity
  end

  defp negative_zero?(x), do: x === -0.0

  defp pow_pos_inf_base(y) when y > 0, do: :infinity
  defp pow_pos_inf_base(_y), do: 0.0

  defp pow_neg_inf_base(y) do
    odd? = odd_exponent?(y)

    cond do
      y > 0 and odd? -> :negative_infinity
      y > 0 -> :infinity
      odd? -> -0.0
      true -> 0.0
    end
  end

  defp pow_pos_inf_exp(x) when x in [:infinity, :negative_infinity], do: :infinity
  defp pow_pos_inf_exp(x) when Kernel.abs(x) > 1, do: :infinity
  defp pow_pos_inf_exp(x) when Kernel.abs(x) < 1, do: 0.0
  defp pow_pos_inf_exp(_x), do: :nan

  defp pow_neg_inf_exp(x) when x in [:infinity, :negative_infinity], do: 0.0
  defp pow_neg_inf_exp(x) when Kernel.abs(x) > 1, do: 0.0
  defp pow_neg_inf_exp(x) when Kernel.abs(x) < 1, do: :infinity
  defp pow_neg_inf_exp(_x), do: :nan
end
