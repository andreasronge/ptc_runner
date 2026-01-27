defmodule PtcRunner.Lisp.Runtime.Interop do
  @moduledoc """
  Simulated Java interop for PTC-Lisp.
  """

  @doc """
  Constructs a java.util.Date.
  If no args, returns now.
  If one arg (number or string), returns date accordingly.
  """
  def java_util_date do
    DateTime.utc_now()
  end

  def java_util_date(nil) do
    raise "java.util.Date: cannot construct from nil"
  end

  def java_util_date(ts) when is_integer(ts) do
    # Simple heuristic: if < 1 trillion, assume seconds (Unix epoch)
    # 1,000,000,000,000 ms is 2001-09-09T01:46:40.000Z
    # Also handle negative timestamps (pre-1970)
    abs_ts = abs(ts)
    unit = if abs_ts < 1_000_000_000_000, do: :second, else: :millisecond

    case DateTime.from_unix(ts, unit) do
      {:ok, dt} -> dt
      {:error, _} -> raise "java.util.Date: invalid timestamp #{ts}"
    end
  end

  def java_util_date(s) when is_binary(s) do
    case parse_date_string(s) do
      {:ok, dt} -> dt
      {:error, reason} -> raise reason
    end
  end

  def java_util_date(other) do
    raise "java.util.Date: cannot construct from #{inspect(other)}"
  end

  defp parse_date_string(s) do
    with {:error, _} <- DateTime.from_iso8601(s),
         {:error, _} <- parse_iso8601_date(s),
         {:error, _} <- parse_rfc2822(s) do
      {:error, "java.util.Date: cannot parse '#{s}'. Expected ISO-8601, RFC 2822, or timestamp."}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:ok, dt} -> {:ok, dt}
    end
  end

  # Handle "YYYY-MM-DD" style ISO dates
  defp parse_iso8601_date(s) do
    case Date.from_iso8601(s) do
      {:ok, date} ->
        {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}

      error ->
        error
    end
  end

  # RFC 2822 format: "Wed, 8 Jan 2026 14:30:00 +0000"
  # Timezone is truly optional (some headers omit it)
  defp parse_rfc2822(s) do
    regex =
      ~r/^(?:[A-Z][a-z]{2},\s+)?(\d{1,2})\s+([A-Z][a-z]{2})\s+(\d{4})\s+(\d{2}:\d{2}:\d{2})(?:\s+([+-]\d{4}|[A-Z]{1,3}))?$/

    case Regex.run(regex, s) do
      # With or without timezone (zone capture may be missing)
      [_ | captures] when length(captures) >= 4 ->
        [day, month_str, year, time_str | _] = captures

        with {:ok, month} <- month_to_int(month_str),
             {:ok, date} <- Date.new(String.to_integer(year), month, String.to_integer(day)),
             {:ok, time} <- Time.from_iso8601(time_str) do
          {:ok, DateTime.new!(date, time, "Etc/UTC")}
        else
          _ -> {:error, :invalid_format}
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp month_to_int("Jan"), do: {:ok, 1}
  defp month_to_int("Feb"), do: {:ok, 2}
  defp month_to_int("Mar"), do: {:ok, 3}
  defp month_to_int("Apr"), do: {:ok, 4}
  defp month_to_int("May"), do: {:ok, 5}
  defp month_to_int("Jun"), do: {:ok, 6}
  defp month_to_int("Jul"), do: {:ok, 7}
  defp month_to_int("Aug"), do: {:ok, 8}
  defp month_to_int("Sep"), do: {:ok, 9}
  defp month_to_int("Oct"), do: {:ok, 10}
  defp month_to_int("Nov"), do: {:ok, 11}
  defp month_to_int("Dec"), do: {:ok, 12}
  defp month_to_int(_), do: {:error, :invalid_month}

  @doc """
  Simulates .getTime method on java.util.Date.
  """
  def dot_get_time(nil) do
    raise ".getTime: expected DateTime, got nil"
  end

  def dot_get_time(%DateTime{} = dt) do
    DateTime.to_unix(dt, :millisecond)
  end

  def dot_get_time(other) do
    raise ".getTime: expected DateTime, got #{inspect(other)}"
  end

  @doc """
  Simulates System/currentTimeMillis.
  """
  def current_time_millis do
    System.system_time(:millisecond)
  end

  @doc """
  Simulates java.time.LocalDate/parse.
  Only supports ISO-8601 YYYY-MM-DD.
  """
  def local_date_parse(nil) do
    raise "LocalDate/parse: cannot parse nil"
  end

  def local_date_parse(s) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, date} ->
        date

      {:error, _} ->
        raise "LocalDate/parse: invalid date '#{s}'"
    end
  end

  def local_date_parse(other) do
    raise "LocalDate/parse: expected string, got #{inspect(other)}"
  end

  @doc """
  Simulates .indexOf method on strings.
  Returns the grapheme index of the first occurrence of substring, or -1 if not found.

  Uses grapheme indices (not byte offsets) for compatibility with `subs` and other
  PTC-Lisp string functions.
  """
  def dot_index_of(s, substring) when is_binary(s) and is_binary(substring) do
    # Empty substring always found at position 0 (Java semantics)
    if substring == "" do
      0
    else
      case String.split(s, substring, parts: 2) do
        [prefix, _rest] -> String.length(prefix)
        [_no_match] -> -1
      end
    end
  end

  def dot_index_of(s, _substring) do
    raise ".indexOf: expected string, got #{type_name(s)}"
  end

  @doc """
  Simulates .indexOf method on strings with a starting position.
  Returns the grapheme index of the first occurrence starting from `from`.
  """
  def dot_index_of(s, substring, from)
      when is_binary(s) and is_binary(substring) and is_integer(from) do
    from = max(0, from)
    len = String.length(s)

    # Java semantics: empty substring returns min(from, length)
    if substring == "" do
      min(from, len)
    else
      if from >= len do
        -1
      else
        suffix = String.slice(s, from..-1//1)

        case String.split(suffix, substring, parts: 2) do
          [prefix, _rest] -> from + String.length(prefix)
          [_no_match] -> -1
        end
      end
    end
  end

  def dot_index_of(s, _substring, _from) do
    raise ".indexOf: expected string, got #{type_name(s)}"
  end

  @doc """
  Simulates .lastIndexOf method on strings.
  Returns the grapheme index of the last occurrence of substring, or -1 if not found.
  """
  def dot_last_index_of(s, substring) when is_binary(s) and is_binary(substring) do
    # Java semantics: empty substring returns string length
    if substring == "" do
      String.length(s)
    else
      parts = String.split(s, substring)

      case parts do
        [_no_match] ->
          -1

        parts ->
          # Sum lengths of all parts except the last, plus (n-1) * substring_length
          # for the substrings between them
          all_but_last = Enum.take(parts, length(parts) - 1)
          prefix_lengths = Enum.map(all_but_last, &String.length/1)
          Enum.sum(prefix_lengths) + (length(all_but_last) - 1) * String.length(substring)
      end
    end
  end

  def dot_last_index_of(s, _substring) do
    raise ".lastIndexOf: expected string, got #{type_name(s)}"
  end

  defp type_name(nil), do: "nil"
  defp type_name(x) when is_list(x), do: "list"
  defp type_name(x) when is_map(x), do: "map"
  defp type_name(x) when is_integer(x), do: "integer"
  defp type_name(x) when is_float(x), do: "float"
  defp type_name(_), do: "non-string"
end
