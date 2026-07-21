defmodule PtcRunner.Lisp.Java.Util.Date do
  @moduledoc """
  Native, bounded representation of legacy `java.util.Date`.

  The payload is exactly one signed Java `long` count of epoch milliseconds.
  No seconds/milliseconds heuristic or host DateTime identity is involved.
  The bounded string grammar admits only dates on or after Java's Gregorian
  cutover, avoiding the deprecated parser's hybrid Julian/Gregorian calendar.
  """

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Primitive
  alias PtcRunner.Lisp.Java.Time.Instant
  alias PtcRunner.Lisp.Java.Time.LocalDate

  @enforce_keys [:epoch_millis]
  defstruct [:epoch_millis]

  @long_min -9_223_372_036_854_775_808
  @long_max 9_223_372_036_854_775_807
  @gregorian_cutover {1582, 10, 15}

  @months %{
    "jan" => 1,
    "january" => 1,
    "feb" => 2,
    "february" => 2,
    "mar" => 3,
    "march" => 3,
    "apr" => 4,
    "april" => 4,
    "may" => 5,
    "jun" => 6,
    "june" => 6,
    "jul" => 7,
    "july" => 7,
    "aug" => 8,
    "august" => 8,
    "sep" => 9,
    "september" => 9,
    "oct" => 10,
    "october" => 10,
    "nov" => 11,
    "november" => 11,
    "dec" => 12,
    "december" => 12
  }

  @weekdays MapSet.new(
              ~w(sun sunday mon monday tue tuesday wed wednesday thu thursday fri friday sat saturday)
            )

  @zones %{
    "gmt" => 0,
    "ut" => 0,
    "utc" => 0,
    "est" => -5 * 3_600,
    "edt" => -4 * 3_600,
    "cst" => -6 * 3_600,
    "cdt" => -5 * 3_600,
    "mst" => -7 * 3_600,
    "mdt" => -6 * 3_600,
    "pst" => -8 * 3_600,
    "pdt" => -7 * 3_600
  }

  @type t :: %__MODULE__{epoch_millis: integer()}

  @spec new(integer()) :: {:ok, t()} | :error
  def new(epoch_millis)
      when is_integer(epoch_millis) and epoch_millis >= @long_min and epoch_millis <= @long_max,
      do: {:ok, %__MODULE__{epoch_millis: epoch_millis}}

  def new(_epoch_millis), do: :error

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{epoch_millis: epoch_millis} = value),
    do: map_size(value) == 2 and match?({:ok, _date}, new(epoch_millis))

  def valid?(_value), do: false

  @spec construct([] | [integer() | String.t() | nil]) :: {:ok, t()} | {:error, Condition.t()}
  def construct([]), do: new(Elixir.System.system_time(:millisecond))

  def construct([epoch_millis]) when is_integer(epoch_millis), do: new(epoch_millis)

  def construct([nil]), do: java_error(:illegal_argument_exception, "Date text is null")

  def construct([text]) when is_binary(text) do
    case parse_legacy(text) do
      {:ok, epoch_millis} -> new(epoch_millis)
      :error -> java_error(:illegal_argument_exception, "invalid legacy Java Date text")
    end
  end

  @spec get_time([t()]) :: {:ok, Primitive.t()}
  def get_time([%__MODULE__{epoch_millis: epoch_millis}]),
    do: Primitive.new(:long, epoch_millis)

  @spec before?([t()]) :: {:ok, boolean()}
  def before?([%__MODULE__{epoch_millis: left}, %__MODULE__{epoch_millis: right}]),
    do: {:ok, left < right}

  @spec after?([t()]) :: {:ok, boolean()}
  def after?([%__MODULE__{epoch_millis: left}, %__MODULE__{epoch_millis: right}]),
    do: {:ok, left > right}

  @spec canonical(t()) :: String.t()
  def canonical(%__MODULE__{epoch_millis: epoch_millis}) do
    {:ok, instant} = Instant.from_epoch_millis(epoch_millis)
    Instant.canonical(instant)
  end

  @doc false
  @spec to_datetime(t()) :: {:ok, DateTime.t()} | :error
  def to_datetime(%__MODULE__{epoch_millis: epoch_millis}) do
    with {:ok, instant} <- Instant.from_epoch_millis(epoch_millis) do
      Instant.to_datetime(instant)
    end
  end

  defp parse_legacy(text) do
    cleaned =
      text
      |> remove_comments()
      |> String.trim()
      |> String.replace(",", " ")
      |> String.replace(~r/\s+/, " ")

    with {:ok, date, rest} <- extract_date(cleaned),
         {:ok, {hour, minute, second}, rest} <- extract_time(rest),
         {:ok, offset_seconds} <- extract_zone(rest),
         {year, month, day} <- date,
         true <- {year, month, day} >= @gregorian_cutover,
         true <- LocalDate.valid_date?(year, month, day),
         true <- hour in 0..23 and minute in 0..59 and second in 0..59,
         epoch_second =
           LocalDate.epoch_day(year, month, day) * 86_400 + hour * 3_600 + minute * 60 +
             second - offset_seconds,
         epoch_millis = epoch_second * 1_000,
         true <- epoch_millis >= @long_min and epoch_millis <= @long_max do
      {:ok, epoch_millis}
    else
      _invalid -> :error
    end
  end

  defp extract_date(text) do
    text = strip_weekday(text)

    patterns = [
      ~r/\A([A-Za-z]+)\s+(\d{1,2})\s+(\d{4,9})\s*(.*)\z/,
      ~r/\A([A-Za-z]+)\s+(\d{1,2})\s+(\d{2}:\d{2}(?::\d{2})?)(?:\s+([A-Za-z]+|[+-]\d{1,4}))?\s+(\d{4,9})\z/,
      ~r/\A(\d{1,2})\s+([A-Za-z]+)\s+(\d{4,9})\s*(.*)\z/,
      ~r/\A(\d{1,2})\/(\d{1,2})\/(\d{4,9})\s*(.*)\z/
    ]

    case Enum.find_value(patterns, &date_match(&1, text)) do
      nil -> :error
      result -> result
    end
  end

  defp strip_weekday(text) do
    case String.split(text, " ", parts: 2) do
      [word, rest] -> if MapSet.member?(@weekdays, String.downcase(word)), do: rest, else: text
      [_word] -> text
    end
  end

  defp date_match(pattern, text) do
    case Regex.run(pattern, text) do
      [_, month_word, day, time, zone, year] ->
        case month_number(month_word) do
          {:ok, month} ->
            {:ok, {String.to_integer(year), month, String.to_integer(day)}, time <> " " <> zone}

          :error ->
            nil
        end

      [_, first, second, year, rest] ->
        cond do
          String.match?(first, ~r/\A\d+\z/) and String.match?(second, ~r/\A\d+\z/) ->
            {:ok, {String.to_integer(year), String.to_integer(first), String.to_integer(second)},
             rest}

          String.match?(first, ~r/\A\d+\z/) ->
            case month_number(second) do
              {:ok, month} ->
                {:ok, {String.to_integer(year), month, String.to_integer(first)}, rest}

              :error ->
                nil
            end

          true ->
            case month_number(first) do
              {:ok, month} ->
                {:ok, {String.to_integer(year), month, String.to_integer(second)}, rest}

              :error ->
                nil
            end
        end

      _no_match ->
        nil
    end
  end

  defp extract_time(text) do
    case Regex.run(~r/\A(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?\s*(.*)\z/, String.trim(text)) do
      [_, hour, minute, "", rest] ->
        {:ok, {String.to_integer(hour), String.to_integer(minute), 0}, rest}

      [_, hour, minute, second, rest] ->
        {:ok, {String.to_integer(hour), String.to_integer(minute), String.to_integer(second)},
         rest}

      [_, hour, minute, rest] ->
        {:ok, {String.to_integer(hour), String.to_integer(minute), 0}, rest}

      _no_time ->
        {:ok, {0, 0, 0}, text}
    end
  end

  defp extract_zone(text) do
    case String.downcase(String.trim(text)) do
      "" -> {:ok, 0}
      zone when is_map_key(@zones, zone) -> {:ok, Map.fetch!(@zones, zone)}
      offset -> parse_numeric_zone(offset)
    end
  end

  defp parse_numeric_zone(<<sign, digits::binary>>) when sign in [?+, ?-] do
    with true <- byte_size(digits) in 1..4,
         {number, ""} <- Integer.parse(digits),
         hours = if(number < 24, do: number, else: div(number, 100)),
         minutes = if(number < 24, do: 0, else: rem(number, 100)),
         true <- hours <= 23 and minutes <= 59 do
      direction = if sign == ?+, do: 1, else: -1
      {:ok, direction * (hours * 3_600 + minutes * 60)}
    else
      _invalid -> :error
    end
  end

  defp parse_numeric_zone(_zone), do: :error

  defp month_number(word) do
    Map.fetch(@months, String.downcase(word))
  end

  defp remove_comments(text), do: remove_comments(text, 0, [])

  defp remove_comments(<<>>, 0, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp remove_comments(<<>>, _depth, _acc), do: ""

  defp remove_comments(<<?(, rest::binary>>, depth, acc),
    do: remove_comments(rest, depth + 1, acc)

  defp remove_comments(<<?), rest::binary>>, depth, acc) when depth > 0,
    do: remove_comments(rest, depth - 1, acc)

  defp remove_comments(<<_byte, rest::binary>>, depth, acc) when depth > 0,
    do: remove_comments(rest, depth, acc)

  defp remove_comments(<<byte, rest::binary>>, 0, acc),
    do: remove_comments(rest, 0, [byte | acc])

  defp java_error(exception, message) do
    {:error, Condition.new(:java_domain_error, nil, nil, message, %{java_exception: exception})}
  end
end
