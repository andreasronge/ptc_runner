defmodule PtcRunner.Lisp.Runtime.Interop do
  @moduledoc """
  Simulated Java interop for PTC-Lisp.
  """

  defmodule Duration do
    @moduledoc false
    defstruct [:milliseconds]
  end

  @millis_per_day 86_400_000
  @epoch_date ~D[1970-01-01]

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

  # Already-temporal arguments are a no-op (or the obvious upgrade): if the LLM
  # has a `%DateTime{}` from a tool result and writes `(java.util.Date. dt)`,
  # don't make it stringify-then-parse first. The internal representation is
  # `%DateTime{}` either way, so just return it (or upgrade Date/Time/NaiveDateTime
  # to a UTC DateTime so `.getTime` works downstream).
  def java_util_date(%DateTime{} = dt), do: dt

  def java_util_date(%NaiveDateTime{} = ndt),
    do: DateTime.from_naive!(ndt, "Etc/UTC")

  def java_util_date(%Date{} = d),
    do: DateTime.new!(d, ~T[00:00:00], "Etc/UTC")

  def java_util_date(%Time{}),
    do: raise("java.util.Date: cannot construct from a Time alone (no date component)")

  def java_util_date(other) do
    raise "java.util.Date: cannot construct from #{inspect(other)}"
  end

  defp parse_date_string(s) do
    with {:error, _} <- DateTime.from_iso8601(s),
         {:error, _} <- parse_iso8601_naive(s),
         {:error, _} <- parse_iso8601_date(s),
         {:error, _} <- parse_rfc2822(s) do
      {:error, "java.util.Date: cannot parse '#{s}'. Expected ISO-8601, RFC 2822, or timestamp."}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:ok, dt} -> {:ok, dt}
    end
  end

  # Offsetless ISO 8601 (e.g. "2026-05-03T09:14:00") — what
  # `NaiveDateTime.to_iso8601/1` emits and what the LLM gets from
  # `(str some-naive-datetime)` in PTC-Lisp. Treat as UTC so the
  # advertised round-trip `(java.util.Date. (str data/ndt))` works.
  defp parse_iso8601_naive(s) do
    case NaiveDateTime.from_iso8601(s) do
      {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
      error -> error
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

  def dot_to_epoch_day(%Date{} = date), do: Date.diff(date, @epoch_date)

  def dot_to_epoch_day(other) do
    raise ".toEpochDay: expected LocalDate, got #{type_name(other)}"
  end

  def dot_plus_days(%Date{} = date, days) when is_integer(days), do: Date.add(date, days)

  def dot_plus_days(%Date{}, days) do
    raise ".plusDays: expected integer days, got #{type_name(days)}"
  end

  def dot_plus_days(other, _days) do
    raise ".plusDays: expected LocalDate, got #{type_name(other)}"
  end

  def dot_minus_days(%Date{} = date, days) when is_integer(days), do: Date.add(date, -days)

  def dot_minus_days(%Date{}, days) do
    raise ".minusDays: expected integer days, got #{type_name(days)}"
  end

  def dot_minus_days(other, _days) do
    raise ".minusDays: expected LocalDate, got #{type_name(other)}"
  end

  def duration_between(%DateTime{} = start_dt, %DateTime{} = end_dt) do
    %Duration{milliseconds: DateTime.diff(end_dt, start_dt, :millisecond)}
  end

  def duration_between(%DateTime{}, end_dt) do
    raise "Duration/between: expected DateTime end argument, got #{type_name(end_dt)}"
  end

  def duration_between(start_dt, _end_dt) do
    raise "Duration/between: expected DateTime start argument, got #{type_name(start_dt)}"
  end

  def dot_to_millis(%Duration{milliseconds: milliseconds}), do: milliseconds

  def dot_to_millis(other) do
    raise ".toMillis: expected Duration, got #{type_name(other)}"
  end

  def dot_to_days(%Duration{milliseconds: milliseconds}), do: div(milliseconds, @millis_per_day)

  def dot_to_days(other) do
    raise ".toDays: expected Duration, got #{type_name(other)}"
  end

  @doc """
  Simulates System/currentTimeMillis.
  """
  def current_time_millis do
    System.system_time(:millisecond)
  end

  @doc """
  Parse an ISO-8601 temporal string. Backs the `parse` builtin (also
  reachable as `LocalDate/parse`).

  Dispatches on the string shape:

  - `"YYYY-MM-DD"` → `Date`
  - a string carrying a time component (`...T...`) → `DateTime`. An offset
    (`Z`, `+02:00`, …) is honoured; an offsetless `...T...` value is treated
    as UTC. `.isBefore` / `.isAfter` / `.getTime` work on the result.

  This is a deliberate divergence from Java's `LocalDate.parse`, which
  rejects anything with a time component — returning a `DateTime` is far more
  useful for an LLM that just wants to compare two timestamps.
  """
  def parse_temporal(nil) do
    raise "parse: cannot parse nil"
  end

  def parse_temporal(s) when is_binary(s) do
    if String.contains?(s, "T") do
      parse_iso8601_instant(s)
    else
      case Date.from_iso8601(s) do
        {:ok, date} -> date
        {:error, _} -> raise "parse: invalid ISO-8601 date '#{s}' (expected YYYY-MM-DD)"
      end
    end
  end

  def parse_temporal(other) do
    raise "parse: expected string, got #{inspect(other)}"
  end

  defp parse_iso8601_instant(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} ->
        dt

      {:error, :missing_offset} ->
        case NaiveDateTime.from_iso8601(s) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          {:error, _} -> raise "parse: invalid ISO-8601 date/time '#{s}'"
        end

      {:error, _} ->
        raise "parse: invalid ISO-8601 date/time '#{s}'"
    end
  end

  @doc """
  Simulates .indexOf method on strings.
  Returns the grapheme index of the first occurrence of substring, or -1 if not found.

  Delegates to `Runtime.String.index_of/2` and converts `nil` to `-1` for Java semantics.
  Uses grapheme indices (not byte offsets) for compatibility with `subs` and other
  PTC-Lisp string functions.
  """
  def dot_index_of(s, substring) when is_binary(s) and is_binary(substring) do
    PtcRunner.Lisp.Runtime.String.index_of(s, substring) || -1
  end

  def dot_index_of(s, _substring) do
    raise ".indexOf: expected string, got #{type_name(s)}"
  end

  @doc """
  Simulates .indexOf method on strings with a starting position.
  Delegates to `Runtime.String.index_of/3` and converts `nil` to `-1`.
  """
  def dot_index_of(s, substring, from)
      when is_binary(s) and is_binary(substring) and is_integer(from) do
    PtcRunner.Lisp.Runtime.String.index_of(s, substring, from) || -1
  end

  def dot_index_of(s, _substring, _from) do
    raise ".indexOf: expected string, got #{type_name(s)}"
  end

  @doc """
  Simulates .contains method on strings.
  Delegates to `String.contains?/2`.
  """
  def dot_contains(s, substring) when is_binary(s) and is_binary(substring) do
    String.contains?(s, substring)
  end

  def dot_contains(s, _substring) when not is_binary(s) do
    raise ".contains: expected string, got #{type_name(s)}"
  end

  def dot_contains(_s, substring) do
    raise ".contains: expected string argument, got #{type_name(substring)}"
  end

  @doc """
  Simulates .lastIndexOf method on strings.
  Delegates to `Runtime.String.last_index_of/2` and converts `nil` to `-1`.
  """
  def dot_last_index_of(s, substring) when is_binary(s) and is_binary(substring) do
    PtcRunner.Lisp.Runtime.String.last_index_of(s, substring) || -1
  end

  def dot_last_index_of(s, _substring) when not is_binary(s) do
    raise ".lastIndexOf: expected string, got #{type_name(s)}"
  end

  def dot_last_index_of(_s, substring) do
    raise ".lastIndexOf: expected string argument, got #{type_name(substring)}"
  end

  @doc """
  Simulates .toLowerCase method on strings.
  Delegates to `String.downcase/1`.
  """
  def dot_to_lower_case(s) when is_binary(s) do
    String.downcase(s)
  end

  def dot_to_lower_case(s) do
    raise ".toLowerCase: expected string, got #{type_name(s)}"
  end

  @doc """
  Simulates .length method on strings.
  Returns grapheme count (matches Java's `length()` for the BMP and the
  PTC-Lisp `count` builtin). Delegates to `String.length/1`.
  """
  def dot_length(s) when is_binary(s) do
    String.length(s)
  end

  def dot_length(s) do
    raise ".length: expected string, got #{type_name(s)}"
  end

  @doc """
  Simulates .substring method on strings.

  - `(.substring s start)` returns the suffix from grapheme index `start`.
  - `(.substring s start end)` returns graphemes in `[start, end)`.

  Indices are grapheme-based (matches `.indexOf` / `.length` semantics).
  """
  def dot_substring(s, start) when is_binary(s) and is_integer(start) do
    len = String.length(s)

    if start < 0 or start > len do
      raise ".substring: start index #{start} out of range for string of length #{len}"
    end

    String.slice(s, start..-1//1)
  end

  def dot_substring(s, _start) when not is_binary(s) do
    raise ".substring: expected string, got #{type_name(s)}"
  end

  def dot_substring(_s, start) do
    raise ".substring: expected integer start, got #{type_name(start)}"
  end

  def dot_substring(s, start, stop)
      when is_binary(s) and is_integer(start) and is_integer(stop) do
    len = String.length(s)

    cond do
      start < 0 ->
        raise ".substring: start index #{start} out of range for string of length #{len}"

      stop > len ->
        raise ".substring: end index #{stop} out of range for string of length #{len}"

      start > stop ->
        raise ".substring: start index #{start} out of range (greater than end index #{stop})"

      true ->
        String.slice(s, start, stop - start)
    end
  end

  def dot_substring(s, _start, _stop) when not is_binary(s) do
    raise ".substring: expected string, got #{type_name(s)}"
  end

  def dot_substring(_s, start, _stop) when not is_integer(start) do
    raise ".substring: expected integer start, got #{type_name(start)}"
  end

  def dot_substring(_s, _start, stop) do
    raise ".substring: expected integer end, got #{type_name(stop)}"
  end

  @doc """
  Simulates .toUpperCase method on strings.
  Delegates to `String.upcase/1`.
  """
  def dot_to_upper_case(s) when is_binary(s) do
    String.upcase(s)
  end

  def dot_to_upper_case(s) do
    raise ".toUpperCase: expected string, got #{type_name(s)}"
  end

  @doc """
  Simulates .startsWith method on strings.
  Delegates to `String.starts_with?/2`.
  """
  def dot_starts_with(s, prefix) when is_binary(s) and is_binary(prefix) do
    String.starts_with?(s, prefix)
  end

  def dot_starts_with(s, _prefix) when not is_binary(s) do
    raise ".startsWith: expected string, got #{type_name(s)}"
  end

  def dot_starts_with(_s, prefix) do
    raise ".startsWith: expected string argument, got #{type_name(prefix)}"
  end

  @doc """
  Simulates .endsWith method on strings.
  Delegates to `String.ends_with?/2`.
  """
  def dot_ends_with(s, suffix) when is_binary(s) and is_binary(suffix) do
    String.ends_with?(s, suffix)
  end

  def dot_ends_with(s, _suffix) when not is_binary(s) do
    raise ".endsWith: expected string, got #{type_name(s)}"
  end

  def dot_ends_with(_s, suffix) do
    raise ".endsWith: expected string argument, got #{type_name(suffix)}"
  end

  @doc """
  Simulates .isBefore method on Date and DateTime objects.
  Returns true if the first argument comes strictly before the second.
  Both arguments must be the same type (Date/Date or DateTime/DateTime).
  """
  def dot_is_before(%Date{} = a, %Date{} = b), do: Date.compare(a, b) == :lt
  def dot_is_before(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :lt

  def dot_is_before(%Date{}, %DateTime{}) do
    raise ".isBefore: cannot compare LocalDate with DateTime — use same types"
  end

  def dot_is_before(%DateTime{}, %Date{}) do
    raise ".isBefore: cannot compare DateTime with LocalDate — use same types"
  end

  def dot_is_before(%Date{}, b) do
    raise ".isBefore: expected LocalDate argument, got #{type_name(b)}"
  end

  def dot_is_before(%DateTime{}, b) do
    raise ".isBefore: expected DateTime argument, got #{type_name(b)}"
  end

  def dot_is_before(a, _b) do
    raise ".isBefore: expected LocalDate or DateTime, got #{type_name(a)}"
  end

  @doc """
  Simulates .isAfter method on Date and DateTime objects.
  Returns true if the first argument comes strictly after the second.
  Both arguments must be the same type (Date/Date or DateTime/DateTime).
  """
  def dot_is_after(%Date{} = a, %Date{} = b), do: Date.compare(a, b) == :gt
  def dot_is_after(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :gt

  def dot_is_after(%Date{}, %DateTime{}) do
    raise ".isAfter: cannot compare LocalDate with DateTime — use same types"
  end

  def dot_is_after(%DateTime{}, %Date{}) do
    raise ".isAfter: cannot compare DateTime with LocalDate — use same types"
  end

  def dot_is_after(%Date{}, b) do
    raise ".isAfter: expected LocalDate argument, got #{type_name(b)}"
  end

  def dot_is_after(%DateTime{}, b) do
    raise ".isAfter: expected DateTime argument, got #{type_name(b)}"
  end

  def dot_is_after(a, _b) do
    raise ".isAfter: expected LocalDate or DateTime, got #{type_name(a)}"
  end

  defp type_name(nil), do: "nil"
  defp type_name(x) when is_list(x), do: "list"
  defp type_name(%Duration{}), do: "Duration"
  defp type_name(%Date{}), do: "LocalDate"
  defp type_name(%DateTime{}), do: "DateTime"
  defp type_name(x) when is_map(x), do: "map"
  defp type_name(x) when is_integer(x), do: "integer"
  defp type_name(x) when is_float(x), do: "float"
  defp type_name(x) when is_binary(x), do: "string"
  defp type_name(_), do: "non-string"
end
