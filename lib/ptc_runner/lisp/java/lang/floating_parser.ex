defmodule PtcRunner.Lisp.Java.Lang.FloatingParser do
  @moduledoc false

  import Bitwise

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Primitive

  @decimal_pattern ~r/\A(?<sign>[+-]?)(?:(?<integer>\d+)(?:\.(?<fraction>\d*))?|\.(?<leading_fraction>\d+))(?:[eE](?<exponent>[+-]?\d+))?[fFdD]?\z/
  @hex_pattern ~r/\A(?<sign>[+-]?)0[xX](?:(?:((?<integer>[0-9a-fA-F]+)(?:\.(?<fraction>[0-9a-fA-F]*))?))|(?:\.(?<leading_fraction>[0-9a-fA-F]+)))[pP](?<exponent>[+-]?\d+)[fFdD]?\z/

  @formats %{
    double: %{fraction_bits: 52, bias: 1023, min_normal: -1022, max_normal: 1023},
    float: %{fraction_bits: 23, bias: 127, min_normal: -126, max_normal: 127}
  }

  @spec parse([String.t() | nil], :double | :float) ::
          {:ok, Primitive.t()} | {:error, Condition.t()}
  def parse([nil], _kind), do: null_pointer_exception()

  def parse([value], kind) when is_binary(value) and kind in [:double, :float] do
    value
    |> trim_java_whitespace()
    |> parse_value(kind)
  end

  @spec constant(:infinity | :negative_infinity | :nan) :: {:ok, Primitive.t()}
  def constant(value), do: Primitive.new(:double, value)

  defp parse_value(value, kind) do
    case special_value(value) do
      {:ok, special} -> Primitive.new(kind, special)
      :error -> parse_finite(value, kind)
    end
  end

  defp parse_finite(value, kind) do
    with :error <- parse_decimal(value, kind),
         :error <- parse_hexadecimal(value, kind) do
      number_format_exception()
    else
      {:ok, number} -> Primitive.new(kind, number)
    end
  end

  defp special_value(value) when value in ["NaN", "+NaN", "-NaN"], do: {:ok, :nan}
  defp special_value(value) when value in ["Infinity", "+Infinity"], do: {:ok, :infinity}
  defp special_value("-Infinity"), do: {:ok, :negative_infinity}
  defp special_value(_value), do: :error

  defp parse_decimal(value, kind) do
    case Regex.named_captures(@decimal_pattern, value) do
      %{
        "sign" => sign,
        "integer" => integer_digits,
        "fraction" => fractional_digits,
        "leading_fraction" => leading_fractional_digits,
        "exponent" => exponent
      } ->
        integer_digits = integer_digits || ""

        fractional_digits =
          if integer_digits == "",
            do: leading_fractional_digits || "",
            else: fractional_digits || ""

        digits = integer_digits <> fractional_digits

        finite_from_decimal(
          sign,
          digits,
          exponent,
          byte_size(fractional_digits),
          kind
        )

      nil ->
        :error
    end
  end

  defp finite_from_decimal(sign, digits, exponent_text, fractional_count, kind) do
    significant_digits = String.trim_leading(digits, "0")

    if significant_digits == "" do
      {:ok, signed_zero(sign, kind)}
    else
      exponent_bound = fractional_count + byte_size(significant_digits) + 4_096
      exponent = parse_bounded_exponent(exponent_text, exponent_bound)
      decimal_exponent = exponent - fractional_count
      decimal_order = byte_size(significant_digits) + decimal_exponent - 1
      format = Map.fetch!(@formats, kind)

      cond do
        decimal_order > decimal_overflow_order(kind) ->
          {:ok, signed_special(sign, :infinity)}

        decimal_order < decimal_underflow_order(kind) ->
          {:ok, signed_zero(sign, kind)}

        true ->
          significand = String.to_integer(significant_digits)
          {numerator, denominator} = decimal_ratio(significand, decimal_exponent)
          {:ok, encode_ratio(numerator, denominator, sign, format, kind)}
      end
    end
  end

  defp decimal_overflow_order(:double), do: 308
  defp decimal_overflow_order(:float), do: 38
  defp decimal_underflow_order(:double), do: -325
  defp decimal_underflow_order(:float), do: -47

  defp decimal_ratio(significand, exponent) when exponent >= 0,
    do: {significand * Integer.pow(10, exponent), 1}

  defp decimal_ratio(significand, exponent),
    do: {significand, Integer.pow(10, -exponent)}

  defp parse_hexadecimal(value, kind) do
    case Regex.named_captures(@hex_pattern, value) do
      %{
        "sign" => sign,
        "integer" => integer_digits,
        "fraction" => fractional_digits,
        "leading_fraction" => leading_fractional_digits,
        "exponent" => exponent
      } ->
        integer_digits = integer_digits || ""

        fractional_digits =
          if integer_digits == "",
            do: leading_fractional_digits || "",
            else: fractional_digits || ""

        digits = integer_digits <> fractional_digits
        significand = String.to_integer(digits, 16)

        if significand == 0 do
          {:ok, signed_zero(sign, kind)}
        else
          format = Map.fetch!(@formats, kind)
          fractional_count = byte_size(fractional_digits)
          exponent_bound = 4 * (byte_size(digits) + fractional_count) + 4_096

          binary_exponent =
            parse_bounded_exponent(exponent, exponent_bound) - 4 * fractional_count

          binary_order = bit_length(significand) - 1 + binary_exponent

          cond do
            binary_order > format.max_normal + 1 ->
              {:ok, signed_special(sign, :infinity)}

            binary_order < format.min_normal - format.fraction_bits - 1 ->
              {:ok, signed_zero(sign, kind)}

            true ->
              {numerator, denominator} = binary_ratio(significand, binary_exponent)
              {:ok, encode_ratio(numerator, denominator, sign, format, kind)}
          end
        end

      nil ->
        :error
    end
  end

  defp binary_ratio(significand, exponent) when exponent >= 0,
    do: {significand <<< exponent, 1}

  defp binary_ratio(significand, exponent), do: {significand, 1 <<< -exponent}

  defp encode_ratio(numerator, denominator, sign, format, kind) do
    exponent = floor_log2_ratio(numerator, denominator)

    if exponent < format.min_normal do
      encode_subnormal(numerator, denominator, sign, format, kind)
    else
      encode_normal(numerator, denominator, sign, exponent, format, kind)
    end
  end

  defp encode_normal(numerator, denominator, sign, exponent, format, kind) do
    significand =
      round_scaled_ratio(numerator, denominator, format.fraction_bits - exponent)

    {significand, exponent} =
      if significand == 1 <<< (format.fraction_bits + 1) do
        {significand >>> 1, exponent + 1}
      else
        {significand, exponent}
      end

    if exponent > format.max_normal do
      signed_special(sign, :infinity)
    else
      exponent_field = exponent + format.bias
      fraction = significand - (1 <<< format.fraction_bits)
      decode_float(sign, exponent_field, fraction, format, kind)
    end
  end

  defp encode_subnormal(numerator, denominator, sign, format, kind) do
    scale = format.fraction_bits - format.min_normal
    fraction = round_scaled_ratio(numerator, denominator, scale)

    cond do
      fraction == 0 ->
        signed_zero(sign, kind)

      fraction >= 1 <<< format.fraction_bits ->
        decode_float(sign, 1, 0, format, kind)

      true ->
        decode_float(sign, 0, fraction, format, kind)
    end
  end

  defp round_scaled_ratio(numerator, denominator, scale) when scale >= 0,
    do: round_ratio(numerator <<< scale, denominator)

  defp round_scaled_ratio(numerator, denominator, scale),
    do: round_ratio(numerator, denominator <<< -scale)

  defp round_ratio(numerator, denominator) do
    quotient = div(numerator, denominator)
    remainder = rem(numerator, denominator)

    doubled_remainder = remainder * 2

    cond do
      doubled_remainder > denominator -> quotient + 1
      doubled_remainder == denominator and rem(quotient, 2) == 1 -> quotient + 1
      true -> quotient
    end
  end

  defp floor_log2_ratio(numerator, denominator) do
    candidate = bit_length(numerator) - bit_length(denominator)

    if ratio_below_power?(numerator, denominator, candidate),
      do: candidate - 1,
      else: candidate
  end

  defp ratio_below_power?(numerator, denominator, exponent) when exponent >= 0,
    do: numerator < denominator <<< exponent

  defp ratio_below_power?(numerator, denominator, exponent),
    do: numerator <<< -exponent < denominator

  defp bit_length(integer) do
    <<first, _rest::binary>> = encoded = :binary.encode_unsigned(integer)
    (byte_size(encoded) - 1) * 8 + byte_bit_length(first)
  end

  defp byte_bit_length(byte) when byte >= 128, do: 8
  defp byte_bit_length(byte) when byte >= 64, do: 7
  defp byte_bit_length(byte) when byte >= 32, do: 6
  defp byte_bit_length(byte) when byte >= 16, do: 5
  defp byte_bit_length(byte) when byte >= 8, do: 4
  defp byte_bit_length(byte) when byte >= 4, do: 3
  defp byte_bit_length(byte) when byte >= 2, do: 2
  defp byte_bit_length(_byte), do: 1

  defp decode_float(sign, exponent, fraction, %{fraction_bits: 52}, :double) do
    sign_bit = sign_bit(sign)
    <<value::float-64>> = <<sign_bit::1, exponent::11, fraction::52>>
    value
  end

  defp decode_float(sign, exponent, fraction, %{fraction_bits: 23}, :float) do
    sign_bit = sign_bit(sign)
    <<value::float-32>> = <<sign_bit::1, exponent::8, fraction::23>>
    value
  end

  defp signed_zero(sign, :double), do: decode_float(sign, 0, 0, @formats.double, :double)
  defp signed_zero(sign, :float), do: decode_float(sign, 0, 0, @formats.float, :float)

  defp signed_special("-", :infinity), do: :negative_infinity
  defp signed_special(_sign, special), do: special

  defp sign_bit("-"), do: 1
  defp sign_bit(_sign), do: 0

  defp parse_bounded_exponent(nil, _bound), do: 0
  defp parse_bounded_exponent("", _bound), do: 0

  defp parse_bounded_exponent(exponent, bound) do
    {sign, digits} =
      case exponent do
        "-" <> digits -> {-1, digits}
        "+" <> digits -> {1, digits}
        digits -> {1, digits}
      end

    significant_digits = String.trim_leading(digits, "0")

    sign * bounded_exponent_magnitude(significant_digits, bound)
  end

  defp bounded_exponent_magnitude("", _bound), do: 0

  defp bounded_exponent_magnitude(digits, bound) do
    bound_digits = Integer.to_string(bound)

    if byte_size(digits) > byte_size(bound_digits) or
         (byte_size(digits) == byte_size(bound_digits) and digits > bound_digits),
       do: bound + 1,
       else: String.to_integer(digits)
  end

  defp trim_java_whitespace(value), do: value |> trim_leading() |> trim_trailing()

  defp trim_leading(<<character, rest::binary>>) when character <= 0x20, do: trim_leading(rest)
  defp trim_leading(value), do: value

  defp trim_trailing(""), do: ""

  defp trim_trailing(value) do
    last_index = byte_size(value) - 1

    if :binary.at(value, last_index) <= 0x20,
      do: trim_trailing(binary_part(value, 0, last_index)),
      else: value
  end

  defp null_pointer_exception do
    {:error,
     Condition.new(
       :java_domain_error,
       nil,
       nil,
       "Java floating parser received null",
       %{java_exception: :null_pointer_exception}
     )}
  end

  defp number_format_exception do
    {:error,
     Condition.new(
       :java_domain_error,
       nil,
       nil,
       "invalid Java floating-point string",
       %{java_exception: :number_format_exception}
     )}
  end
end
