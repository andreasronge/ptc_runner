defmodule PtcRunner.Lisp.Java.Time.Instant do
  @moduledoc """
  Native, bounded representation of `java.time.Instant`.

  Instants retain Java's epoch-second plus nanosecond adjustment identity, so
  sub-microsecond precision is not lost to the host DateTime representation.
  """

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Time.LocalDate

  @enforce_keys [:epoch_second, :nano]
  defstruct [:epoch_second, :nano]

  @min_second -31_557_014_167_219_200
  @max_second 31_556_889_864_403_199
  @long_min -9_223_372_036_854_775_808
  @long_max 9_223_372_036_854_775_807
  @seconds_per_day 86_400
  @nanos_per_second 1_000_000_000

  @type t :: %__MODULE__{epoch_second: integer(), nano: non_neg_integer()}

  @spec new(integer(), integer()) :: {:ok, t()} | :error
  def new(epoch_second, nano)
      when is_integer(epoch_second) and epoch_second >= @min_second and
             epoch_second <= @max_second and is_integer(nano) and nano >= 0 and
             nano < @nanos_per_second,
      do: {:ok, %__MODULE__{epoch_second: epoch_second, nano: nano}}

  def new(_epoch_second, _nano), do: :error

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{epoch_second: epoch_second, nano: nano} = value),
    do: map_size(value) == 3 and match?({:ok, _instant}, new(epoch_second, nano))

  def valid?(_value), do: false

  @spec parse([String.t() | nil]) :: {:ok, t()} | {:error, Condition.t()}
  def parse([nil]), do: java_error(:null_pointer_exception, "Instant text is null")

  def parse([text]) when is_binary(text) do
    case parse_text(text) do
      {:ok, instant} -> {:ok, instant}
      :error -> java_error(:date_time_parse_exception, "invalid Java Instant text")
    end
  end

  @spec before?([t()]) :: {:ok, boolean()}
  def before?([%__MODULE__{} = left, %__MODULE__{} = right]),
    do: {:ok, compare(left, right) == :lt}

  @spec after?([t()]) :: {:ok, boolean()}
  def after?([%__MODULE__{} = left, %__MODULE__{} = right]),
    do: {:ok, compare(left, right) == :gt}

  @spec to_epoch_milli([t()]) :: {:ok, Primitive.t()} | {:error, Condition.t()}
  def to_epoch_milli([%__MODULE__{epoch_second: second, nano: nano}]) do
    milliseconds = second * 1_000 + div(nano, 1_000_000)

    if milliseconds >= @long_min and milliseconds <= @long_max do
      Primitive.new(:long, milliseconds)
    else
      java_error(:arithmetic_exception, "Instant epoch milliseconds overflow Java long")
    end
  end

  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = left, %__MODULE__{} = right) do
    cond do
      left.epoch_second < right.epoch_second -> :lt
      left.epoch_second > right.epoch_second -> :gt
      left.nano < right.nano -> :lt
      left.nano > right.nano -> :gt
      true -> :eq
    end
  end

  @spec canonical(t()) :: String.t()
  def canonical(%__MODULE__{epoch_second: epoch_second, nano: nano}) do
    epoch_day = Integer.floor_div(epoch_second, @seconds_per_day)
    second_of_day = epoch_second - epoch_day * @seconds_per_day
    {year, month, day} = LocalDate.calendar_date(epoch_day)
    hour = div(second_of_day, 3_600)
    minute = div(rem(second_of_day, 3_600), 60)
    second = rem(second_of_day, 60)

    LocalDate.format_date(year, month, day) <>
      "T" <>
      pad2(hour) <> ":" <> pad2(minute) <> ":" <> pad2(second) <> fraction(nano) <> "Z"
  end

  @doc false
  @spec from_epoch_millis(integer()) :: {:ok, t()} | :error
  def from_epoch_millis(milliseconds) when is_integer(milliseconds) do
    second = Integer.floor_div(milliseconds, 1_000)
    milli_adjustment = milliseconds - second * 1_000
    new(second, milli_adjustment * 1_000_000)
  end

  @doc false
  @spec to_datetime(t()) :: {:ok, DateTime.t()} | :error
  def to_datetime(%__MODULE__{epoch_second: epoch_second, nano: nano}) do
    epoch_day = Integer.floor_div(epoch_second, @seconds_per_day)
    second_of_day = epoch_second - epoch_day * @seconds_per_day
    {year, month, day} = LocalDate.calendar_date(epoch_day)

    with 0 <- rem(nano, 1_000),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <-
           Time.new(
             div(second_of_day, 3_600),
             div(rem(second_of_day, 3_600), 60),
             rem(second_of_day, 60),
             {div(nano, 1_000), 6}
           ),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _inexact_or_out_of_range -> :error
    end
  end

  defp parse_text(text) do
    regex =
      ~r/\A(.+)[Tt](\d{2}):(\d{2}):(\d{2})(?:\.(\d{0,9}))?([Zz]|[+-]\d{2}:\d{2}(?::\d{2})?)\z/

    case Regex.run(regex, text) do
      [_, date_text, hour_text, minute_text, second_text, fraction_text, offset_text] ->
        build_parsed(date_text, hour_text, minute_text, second_text, fraction_text, offset_text)

      [_, date_text, hour_text, minute_text, second_text, offset_text] ->
        build_parsed(date_text, hour_text, minute_text, second_text, nil, offset_text)

      _no_match ->
        :error
    end
  end

  defp build_parsed(date_text, hour_text, minute_text, second_text, fraction_text, offset_text) do
    with {:ok, {year, month, day}} <-
           LocalDate.parse_date(date_text, -1_000_000_000, 1_000_000_000),
         hour = String.to_integer(hour_text),
         minute = String.to_integer(minute_text),
         second = String.to_integer(second_text),
         nano = parse_fraction(fraction_text),
         true <- valid_time?(hour, minute, second, nano),
         {:ok, offset_seconds} <- parse_offset(offset_text),
         {normalized_hour, normalized_second, day_adjustment} <-
           normalize_time(hour, minute, second),
         local_second =
           (LocalDate.epoch_day(year, month, day) + day_adjustment) * @seconds_per_day +
             normalized_hour * 3_600 + minute * 60 + normalized_second,
         {:ok, instant} <- new(local_second - offset_seconds, nano) do
      {:ok, instant}
    else
      _invalid -> :error
    end
  end

  defp parse_offset(offset) when offset in ["Z", "z"], do: {:ok, 0}

  defp parse_offset(
         <<sign, hour_text::binary-size(2), ?:, minute_text::binary-size(2), rest::binary>>
       )
       when sign in [?+, ?-] do
    hour = String.to_integer(hour_text)
    minute = String.to_integer(minute_text)

    with {:ok, second} <- parse_offset_second(rest),
         true <- hour <= 18 and minute <= 59 and second <= 59,
         true <- hour < 18 or (minute == 0 and second == 0) do
      direction = if sign == ?+, do: 1, else: -1
      {:ok, direction * (hour * 3_600 + minute * 60 + second)}
    else
      _invalid -> :error
    end
  end

  defp parse_offset(_offset), do: :error

  defp parse_offset_second(""), do: {:ok, 0}

  defp parse_offset_second(<<?:, second_text::binary-size(2)>>),
    do: {:ok, String.to_integer(second_text)}

  defp parse_offset_second(_rest), do: :error

  defp valid_time?(24, 0, 0, 0), do: true
  defp valid_time?(23, 59, 60, nano) when nano >= 0 and nano < @nanos_per_second, do: true

  defp valid_time?(hour, minute, second, nano),
    do:
      hour in 0..23 and minute in 0..59 and second in 0..59 and nano >= 0 and
        nano < @nanos_per_second

  defp normalize_time(24, 0, 0), do: {0, 0, 1}
  defp normalize_time(23, 59, 60), do: {23, 59, 0}
  defp normalize_time(hour, _minute, second), do: {hour, second, 0}

  defp parse_fraction(nil), do: 0
  defp parse_fraction(""), do: 0

  defp parse_fraction(digits),
    do: digits |> String.pad_trailing(9, "0") |> String.to_integer()

  defp fraction(0), do: ""

  defp fraction(nano) do
    digits = nano |> Integer.to_string() |> String.pad_leading(9, "0")

    length =
      cond do
        rem(nano, 1_000_000) == 0 -> 3
        rem(nano, 1_000) == 0 -> 6
        true -> 9
      end

    "." <> binary_part(digits, 0, length)
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp java_error(exception, message) do
    {:error, Condition.new(:java_domain_error, nil, nil, message, %{java_exception: exception})}
  end
end
