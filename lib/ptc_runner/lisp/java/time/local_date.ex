defmodule PtcRunner.Lisp.Java.Time.LocalDate do
  @moduledoc """
  Native, bounded representation of `java.time.LocalDate`.

  The payload is Java's epoch-day identity. It covers the complete Java
  LocalDate range without depending on the host calendar's year limits.
  """

  alias PtcRunner.Lisp.Java.Condition
  alias PtcRunner.Lisp.Java.Primitive

  @enforce_keys [:epoch_day]
  defstruct [:epoch_day]

  @min_year -999_999_999
  @max_year 999_999_999
  @min_epoch_day -365_243_219_162
  @max_epoch_day 365_241_780_471
  @long_min -9_223_372_036_854_775_808
  @long_max 9_223_372_036_854_775_807

  @type t :: %__MODULE__{epoch_day: integer()}

  @spec new(integer()) :: {:ok, t()} | :error
  def new(epoch_day)
      when is_integer(epoch_day) and epoch_day >= @min_epoch_day and
             epoch_day <= @max_epoch_day,
      do: {:ok, %__MODULE__{epoch_day: epoch_day}}

  def new(_epoch_day), do: :error

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{epoch_day: epoch_day} = value),
    do: map_size(value) == 2 and match?({:ok, _date}, new(epoch_day))

  def valid?(_value), do: false

  @spec parse([String.t() | nil]) :: {:ok, t()} | {:error, Condition.t()}
  def parse([nil]), do: java_error(:null_pointer_exception, "LocalDate text is null")

  def parse([text]) when is_binary(text) do
    with {:ok, {year, month, day}} <- parse_date(text, @min_year, @max_year),
         {:ok, date} <- year |> epoch_day(month, day) |> new() do
      {:ok, date}
    else
      _invalid -> java_error(:date_time_parse_exception, "invalid Java LocalDate text")
    end
  end

  @spec to_epoch_day([t()]) :: {:ok, Primitive.t()}
  def to_epoch_day([%__MODULE__{epoch_day: epoch_day}]), do: Primitive.new(:long, epoch_day)

  @spec plus_days([t() | integer()]) :: {:ok, t()} | {:error, Condition.t()}
  def plus_days([%__MODULE__{epoch_day: epoch_day}, days]) do
    case checked_long(epoch_day + days) do
      {:ok, result} -> date_result(result)
      :error -> java_error(:arithmetic_exception, "LocalDate day arithmetic overflowed Java long")
    end
  end

  @spec minus_days([t() | integer()]) :: {:ok, t()} | {:error, Condition.t()}
  def minus_days([%__MODULE__{} = date, @long_min]) do
    with {:ok, intermediate} <- plus_days([date, @long_max]) do
      plus_days([intermediate, 1])
    end
  end

  def minus_days([%__MODULE__{epoch_day: epoch_day}, days]) do
    case checked_long(epoch_day - days) do
      {:ok, result} -> date_result(result)
      :error -> java_error(:arithmetic_exception, "LocalDate day arithmetic overflowed Java long")
    end
  end

  defp date_result(epoch_day) do
    case new(epoch_day) do
      {:ok, date} -> {:ok, date}
      :error -> java_error(:date_time_exception, "LocalDate exceeds the Java range")
    end
  end

  defp checked_long(value) when value >= @long_min and value <= @long_max, do: {:ok, value}
  defp checked_long(_value), do: :error

  @spec before?([t()]) :: {:ok, boolean()}
  def before?([%__MODULE__{epoch_day: left}, %__MODULE__{epoch_day: right}]),
    do: {:ok, left < right}

  @spec after?([t()]) :: {:ok, boolean()}
  def after?([%__MODULE__{epoch_day: left}, %__MODULE__{epoch_day: right}]),
    do: {:ok, left > right}

  @spec canonical(t()) :: String.t()
  def canonical(%__MODULE__{epoch_day: epoch_day}) do
    {year, month, day} = calendar_date(epoch_day)
    format_date(year, month, day)
  end

  @doc false
  @spec parse_date(String.t(), integer(), integer()) ::
          {:ok, {integer(), pos_integer(), pos_integer()}} | :error
  def parse_date(text, min_year, max_year) when is_binary(text) and byte_size(text) <= 17 do
    case Regex.run(~r/\A([+-]?)(\d+)-(\d{2})-(\d{2})\z/, text) do
      [_, sign, year_digits, month_digits, day_digits] ->
        with {:ok, year} <- parse_year(sign, year_digits),
             true <- year >= min_year and year <= max_year,
             month = String.to_integer(month_digits),
             day = String.to_integer(day_digits),
             true <- valid_date?(year, month, day) do
          {:ok, {year, month, day}}
        else
          _invalid -> :error
        end

      _no_match ->
        :error
    end
  end

  def parse_date(_text, _min_year, _max_year), do: :error

  @doc false
  @spec valid_date?(integer(), integer(), integer()) :: boolean()
  def valid_date?(year, month, day)
      when is_integer(year) and is_integer(month) and is_integer(day) and month in 1..12 do
    day >= 1 and day <= days_in_month(year, month)
  end

  def valid_date?(_year, _month, _day), do: false

  @doc false
  @spec epoch_day(integer(), pos_integer(), pos_integer()) :: integer()
  def epoch_day(year, month, day) do
    adjusted_year = if month <= 2, do: year - 1, else: year
    era = Integer.floor_div(adjusted_year, 400)
    year_of_era = adjusted_year - era * 400
    adjusted_month = month + if(month > 2, do: -3, else: 9)
    day_of_year = div(153 * adjusted_month + 2, 5) + day - 1
    day_of_era = year_of_era * 365 + div(year_of_era, 4) - div(year_of_era, 100) + day_of_year
    era * 146_097 + day_of_era - 719_468
  end

  @doc false
  @spec calendar_date(integer()) :: {integer(), pos_integer(), pos_integer()}
  def calendar_date(epoch_day) when is_integer(epoch_day) do
    shifted = epoch_day + 719_468
    era = Integer.floor_div(shifted, 146_097)
    day_of_era = shifted - era * 146_097

    year_of_era =
      div(
        day_of_era - div(day_of_era, 1_460) + div(day_of_era, 36_524) -
          div(day_of_era, 146_096),
        365
      )

    year = year_of_era + era * 400
    day_of_year = day_of_era - (365 * year_of_era + div(year_of_era, 4) - div(year_of_era, 100))
    month_part = div(5 * day_of_year + 2, 153)
    day = day_of_year - div(153 * month_part + 2, 5) + 1
    month = month_part + if(month_part < 10, do: 3, else: -9)
    {year + if(month <= 2, do: 1, else: 0), month, day}
  end

  @doc false
  @spec format_date(integer(), pos_integer(), pos_integer()) :: String.t()
  def format_date(year, month, day) do
    year_text = format_year(year)
    year_text <> "-" <> pad2(month) <> "-" <> pad2(day)
  end

  defp parse_year("", digits) when byte_size(digits) == 4,
    do: {:ok, String.to_integer(digits)}

  defp parse_year("+", digits) when byte_size(digits) in 5..10 do
    {:ok, String.to_integer(digits)}
  end

  defp parse_year("-", digits) when byte_size(digits) in 4..10 do
    year = String.to_integer(digits)
    if year > 0, do: {:ok, -year}, else: :error
  end

  defp parse_year(_sign, _digits), do: :error

  defp format_year(year) when year >= 0 and year <= 9_999,
    do: year |> Integer.to_string() |> String.pad_leading(4, "0")

  defp format_year(year) when year > 9_999, do: "+" <> Integer.to_string(year)

  defp format_year(year) do
    magnitude = year |> abs() |> Integer.to_string() |> String.pad_leading(4, "0")
    "-" <> magnitude
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp days_in_month(year, 2), do: if(leap_year?(year), do: 29, else: 28)
  defp days_in_month(_year, month) when month in [4, 6, 9, 11], do: 30
  defp days_in_month(_year, _month), do: 31

  defp leap_year?(year), do: rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0)

  defp java_error(exception, message) do
    {:error, Condition.new(:java_domain_error, nil, nil, message, %{java_exception: exception})}
  end
end
