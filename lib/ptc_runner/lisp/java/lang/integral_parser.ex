defmodule PtcRunner.Lisp.Java.Lang.IntegralParser do
  @moduledoc false

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Primitive

  @limits %{
    int: {-2_147_483_648, 2_147_483_647},
    long: {-9_223_372_036_854_775_808, 9_223_372_036_854_775_807}
  }

  # Java 21's String parsers call Character.digit(char, 10) one UTF-16 code
  # unit at a time. These are the BMP decimal-zero codepoints admitted by that
  # API; supplementary-plane decimal digits therefore remain invalid here too.
  @java_decimal_zeroes [
    0x0030,
    0x0660,
    0x06F0,
    0x07C0,
    0x0966,
    0x09E6,
    0x0A66,
    0x0AE6,
    0x0B66,
    0x0BE6,
    0x0C66,
    0x0CE6,
    0x0D66,
    0x0DE6,
    0x0E50,
    0x0ED0,
    0x0F20,
    0x1040,
    0x1090,
    0x17E0,
    0x1810,
    0x1946,
    0x19D0,
    0x1A80,
    0x1A90,
    0x1B50,
    0x1BB0,
    0x1C40,
    0x1C50,
    0xA620,
    0xA8D0,
    0xA900,
    0xA9D0,
    0xA9F0,
    0xAA50,
    0xABF0,
    0xFF10
  ]
  @java_decimal_digits Map.new(
                         for zero <- @java_decimal_zeroes,
                             digit <- 0..9,
                             do: {zero + digit, digit}
                       )

  @spec parse([String.t() | nil], Primitive.kind()) ::
          {:ok, Primitive.t()} | {:error, Condition.t()}
  def parse([value], kind) when kind in [:int, :long] do
    with {:ok, parsed} <- parse_integer(value, kind),
         {:ok, primitive} <- Primitive.new(kind, parsed) do
      {:ok, primitive}
    else
      _failure -> number_format_exception()
    end
  end

  defp parse_integer(value, kind) when is_binary(value) do
    with characters when is_list(characters) <- :unicode.characters_to_list(value),
         {:ok, sign, digits} <- split_sign(characters),
         {minimum, maximum} <- Map.fetch!(@limits, kind),
         limit = if(sign == -1, do: -minimum, else: maximum),
         {:ok, magnitude} <- parse_digits(digits, limit) do
      {:ok, sign * magnitude}
    else
      _invalid -> :error
    end
  end

  defp parse_integer(_value, _kind), do: :error

  defp split_sign([?- | digits]) when digits != [], do: {:ok, -1, digits}
  defp split_sign([?+ | digits]) when digits != [], do: {:ok, 1, digits}
  defp split_sign(digits) when digits != [], do: {:ok, 1, digits}
  defp split_sign(_characters), do: :error

  defp parse_digits(digits, limit) do
    Enum.reduce_while(digits, {:ok, 0}, fn codepoint, {:ok, accumulator} ->
      with {:ok, digit} <- Map.fetch(@java_decimal_digits, codepoint),
           true <- accumulator <= div(limit - digit, 10) do
        {:cont, {:ok, accumulator * 10 + digit}}
      else
        _invalid -> {:halt, :error}
      end
    end)
  end

  defp number_format_exception do
    {:error,
     Condition.new(
       :java_domain_error,
       nil,
       nil,
       "invalid Java integer string",
       %{java_exception: :number_format_exception}
     )}
  end
end
