defmodule PtcRunner.Lisp.Java.Lang.Math do
  @moduledoc """
  Closed implementations for the admitted `java.lang.Math` overloads.

  Inputs have already been selected and coerced by `Java.Dispatch`. Every
  numeric result is re-tagged with the primitive kind declared by the selected
  JVM descriptor so later Java calls can observe its overload identity.
  """

  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Runtime.JavaMathSemantics

  @int_min -2_147_483_648
  @int_max 2_147_483_647
  @long_min -9_223_372_036_854_775_808
  @long_max 9_223_372_036_854_775_807

  @spec abs_int([integer()]) :: {:ok, Primitive.t()}
  def abs_int([@int_min]), do: primitive(:int, @int_min)
  def abs_int([value]), do: primitive(:int, Kernel.abs(value))

  @spec abs_long([integer()]) :: {:ok, Primitive.t()}
  def abs_long([@long_min]), do: primitive(:long, @long_min)
  def abs_long([value]), do: primitive(:long, Kernel.abs(value))

  @spec abs_float([term()]) :: {:ok, Primitive.t()}
  def abs_float([value]), do: primitive(:float, abs_floating(value))

  @spec abs_double([term()]) :: {:ok, Primitive.t()}
  def abs_double([value]), do: primitive(:double, abs_floating(value))

  @spec ceil_double([term()]) :: {:ok, Primitive.t()}
  def ceil_double([value]), do: primitive(:double, directed_round(value, :ceil))

  @spec floor_double([term()]) :: {:ok, Primitive.t()}
  def floor_double([value]), do: primitive(:double, directed_round(value, :floor))

  @spec max_int([integer()]) :: {:ok, Primitive.t()}
  def max_int([left, right]), do: primitive(:int, Kernel.max(left, right))

  @spec max_long([integer()]) :: {:ok, Primitive.t()}
  def max_long([left, right]), do: primitive(:long, Kernel.max(left, right))

  @spec max_float([term()]) :: {:ok, Primitive.t()}
  def max_float([left, right]), do: primitive(:float, max_floating(left, right))

  @spec max_double([term()]) :: {:ok, Primitive.t()}
  def max_double([left, right]), do: primitive(:double, max_floating(left, right))

  @spec min_int([integer()]) :: {:ok, Primitive.t()}
  def min_int([left, right]), do: primitive(:int, Kernel.min(left, right))

  @spec min_long([integer()]) :: {:ok, Primitive.t()}
  def min_long([left, right]), do: primitive(:long, Kernel.min(left, right))

  @spec min_float([term()]) :: {:ok, Primitive.t()}
  def min_float([left, right]), do: primitive(:float, min_floating(left, right))

  @spec min_double([term()]) :: {:ok, Primitive.t()}
  def min_double([left, right]), do: primitive(:double, min_floating(left, right))

  @spec pow_double([term()]) :: {:ok, Primitive.t()}
  def pow_double([base, exponent]),
    do: primitive(:double, JavaMathSemantics.pow(base, exponent))

  @spec round_float([term()]) :: {:ok, Primitive.t()}
  def round_float([value]), do: primitive(:int, round_and_saturate(value, @int_min, @int_max))

  @spec round_double([term()]) :: {:ok, Primitive.t()}
  def round_double([value]),
    do: primitive(:long, round_and_saturate(value, @long_min, @long_max))

  @spec sqrt_double([term()]) :: {:ok, Primitive.t()}
  def sqrt_double([value]), do: primitive(:double, JavaMathSemantics.sqrt(value))

  defp abs_floating(:nan), do: :nan
  defp abs_floating(value) when value in [:infinity, :negative_infinity], do: :infinity
  defp abs_floating(value), do: Kernel.abs(value)

  defp directed_round(value, _direction)
       when value in [:nan, :infinity, :negative_infinity],
       do: value

  defp directed_round(value, direction), do: apply(:math, direction, [value])

  defp max_floating(:nan, _right), do: :nan
  defp max_floating(_left, :nan), do: :nan
  defp max_floating(:infinity, _right), do: :infinity
  defp max_floating(_left, :infinity), do: :infinity
  defp max_floating(:negative_infinity, right), do: right
  defp max_floating(left, :negative_infinity), do: left

  defp max_floating(left, right) when left == 0 and right == 0 do
    if negative_zero?(left) and negative_zero?(right), do: -0.0, else: 0.0
  end

  defp max_floating(left, right), do: Kernel.max(left, right)

  defp min_floating(:nan, _right), do: :nan
  defp min_floating(_left, :nan), do: :nan
  defp min_floating(:negative_infinity, _right), do: :negative_infinity
  defp min_floating(_left, :negative_infinity), do: :negative_infinity
  defp min_floating(:infinity, right), do: right
  defp min_floating(left, :infinity), do: left

  defp min_floating(left, right) when left == 0 and right == 0 do
    if negative_zero?(left) or negative_zero?(right), do: -0.0, else: 0.0
  end

  defp min_floating(left, right), do: Kernel.min(left, right)

  defp round_and_saturate(:nan, _minimum, _maximum), do: 0
  defp round_and_saturate(:infinity, _minimum, maximum), do: maximum
  defp round_and_saturate(:negative_infinity, minimum, _maximum), do: minimum

  defp round_and_saturate(value, minimum, maximum) do
    value
    |> round_finite()
    |> Kernel.max(minimum)
    |> Kernel.min(maximum)
  end

  # Adding 0.5 first can round an already-integral large double to its next
  # representable value. Split at the integral part so this implements Java's
  # mathematical floor(value + 0.5) rule without that lossy intermediate.
  defp round_finite(value) do
    integral = Kernel.trunc(value)
    fraction = value - integral

    cond do
      fraction >= 0.5 -> integral + 1
      fraction < -0.5 -> integral - 1
      true -> integral
    end
  end

  defp negative_zero?(value) when is_float(value), do: <<value::float-64>> == <<1::1, 0::63>>
  defp negative_zero?(_value), do: false

  defp primitive(kind, value), do: Primitive.new(kind, value)
end
