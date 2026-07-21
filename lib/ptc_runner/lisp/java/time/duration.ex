defmodule PtcRunner.Lisp.Java.Time.Duration do
  @moduledoc """
  Native, bounded representation of `java.time.Duration`.

  The payload follows Java's normalized signed-seconds plus non-negative
  nanosecond-adjustment representation.
  """

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Time.Instant

  @enforce_keys [:seconds, :nano]
  defstruct [:seconds, :nano]

  @long_min -9_223_372_036_854_775_808
  @long_max 9_223_372_036_854_775_807
  @nanos_per_second 1_000_000_000
  @seconds_per_day 86_400
  @canonical_pattern ~r/\APT(?:(?<hours>[+-]?\d+)H)?(?:(?<minutes>[+-]?\d+)M)?(?:(?<seconds>[+-]?\d+)(?:\.(?<fraction>\d{1,9}))?S)?\z/

  @type t :: %__MODULE__{seconds: integer(), nano: non_neg_integer()}

  @spec new(integer(), integer()) :: {:ok, t()} | :error
  def new(seconds, nano)
      when is_integer(seconds) and seconds >= @long_min and seconds <= @long_max and
             is_integer(nano) and nano >= 0 and nano < @nanos_per_second,
      do: {:ok, %__MODULE__{seconds: seconds, nano: nano}}

  def new(_seconds, _nano), do: :error

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{seconds: seconds, nano: nano} = value),
    do: map_size(value) == 3 and match?({:ok, _duration}, new(seconds, nano))

  def valid?(_value), do: false

  @doc false
  @spec from_iso8601(String.t()) :: {:ok, t()} | :error
  def from_iso8601(text) when is_binary(text) and byte_size(text) <= 96 do
    with %{} = captures <- Regex.named_captures(@canonical_pattern, text),
         true <- duration_component_present?(captures),
         {:ok, hours} <- parse_component(captures["hours"]),
         {:ok, minutes} <- parse_component(captures["minutes"]),
         {:ok, seconds} <- parse_component(captures["seconds"]),
         {:ok, fraction} <- parse_fraction(captures["fraction"], captures["seconds"]),
         total_nanos =
           (hours * 3_600 + minutes * 60 + seconds) * @nanos_per_second + fraction,
         normalized_seconds = Integer.floor_div(total_nanos, @nanos_per_second),
         normalized_nanos = total_nanos - normalized_seconds * @nanos_per_second,
         {:ok, duration} <- new(normalized_seconds, normalized_nanos) do
      {:ok, duration}
    else
      _invalid -> :error
    end
  end

  def from_iso8601(_text), do: :error

  @spec between([Instant.t()]) :: {:ok, t()} | {:error, Condition.t()}
  def between([
        %Instant{epoch_second: start_second, nano: start_nano},
        %Instant{epoch_second: end_second, nano: end_nano}
      ]) do
    seconds = end_second - start_second
    nanos = end_nano - start_nano

    {normalized_seconds, normalized_nanos} =
      if nanos < 0,
        do: {seconds - 1, nanos + @nanos_per_second},
        else: {seconds, nanos}

    case new(normalized_seconds, normalized_nanos) do
      {:ok, duration} -> {:ok, duration}
      :error -> java_error(:arithmetic_exception, "Duration exceeds the Java range")
    end
  end

  @spec to_millis([t()]) :: {:ok, Primitive.t()} | {:error, Condition.t()}
  def to_millis([%__MODULE__{seconds: seconds, nano: nano}]) do
    milliseconds = div(seconds * @nanos_per_second + nano, 1_000_000)

    if milliseconds >= @long_min and milliseconds <= @long_max do
      Primitive.new(:long, milliseconds)
    else
      java_error(:arithmetic_exception, "Duration milliseconds overflow Java long")
    end
  end

  @spec to_days([t()]) :: {:ok, Primitive.t()}
  def to_days([%__MODULE__{seconds: seconds}]),
    do: Primitive.new(:long, div(seconds, @seconds_per_day))

  @spec canonical(t()) :: String.t()
  def canonical(%__MODULE__{seconds: 0, nano: 0}), do: "PT0S"

  def canonical(%__MODULE__{seconds: seconds, nano: nano}) do
    effective_seconds = if seconds < 0 and nano > 0, do: seconds + 1, else: seconds
    hours = div(effective_seconds, 3_600)
    minutes = div(rem(effective_seconds, 3_600), 60)
    second_part = rem(effective_seconds, 60)

    output =
      "PT"
      |> append_component(hours, "H")
      |> append_component(minutes, "M")

    if second_part == 0 and nano == 0 and output != "PT" do
      output
    else
      output <> seconds_text(seconds, second_part, nano) <> fraction(seconds, nano) <> "S"
    end
  end

  defp append_component(output, 0, _suffix), do: output
  defp append_component(output, value, suffix), do: output <> Integer.to_string(value) <> suffix

  defp seconds_text(seconds, 0, nano) when seconds < 0 and nano > 0, do: "-0"

  defp seconds_text(seconds, second_part, nano) when seconds < 0 and nano > 0,
    do: Integer.to_string(second_part)

  defp seconds_text(_seconds, second_part, _nano), do: Integer.to_string(second_part)

  defp fraction(_seconds, 0), do: ""

  defp fraction(seconds, nano) do
    adjusted = if seconds < 0, do: 2_000_000_000 - nano, else: 1_000_000_000 + nano

    adjusted
    |> Integer.to_string()
    |> String.slice(1, 9)
    |> String.trim_trailing("0")
    |> then(&("." <> &1))
  end

  defp duration_component_present?(captures) do
    Enum.any?(["hours", "minutes", "seconds"], &(captures[&1] not in [nil, ""]))
  end

  defp parse_component(value) when value in [nil, ""], do: {:ok, 0}

  defp parse_component(value) do
    digits = unsigned_digits(value)

    if byte_size(digits) in 1..19 do
      case Integer.parse(value) do
        {integer, ""} -> {:ok, integer}
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp unsigned_digits(<<sign, digits::binary>>) when sign in [?+, ?-], do: digits
  defp unsigned_digits(digits), do: digits

  defp parse_fraction(value, _seconds) when value in [nil, ""], do: {:ok, 0}

  defp parse_fraction(value, seconds) do
    nanos = value |> String.pad_trailing(9, "0") |> String.to_integer()
    if String.starts_with?(seconds, "-"), do: {:ok, -nanos}, else: {:ok, nanos}
  end

  defp java_error(exception, message) do
    {:error, Condition.new(:java_domain_error, nil, nil, message, %{java_exception: exception})}
  end
end
