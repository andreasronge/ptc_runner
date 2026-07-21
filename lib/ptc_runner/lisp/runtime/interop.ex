defmodule PtcRunner.Lisp.Runtime.Interop do
  @moduledoc """
  Simulated Java interop for PTC-Lisp.
  """

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

  `.substring` is a Java-shaped method, so finite numeric indexes are coerced to
  the Java `int` parameter by truncating toward zero — `(.substring "abcd" 1.0)`
  and `(.substring "abcd" 1.9)` both behave like `1`. Non-finite floats (NaN,
  Infinity) are PTC-Lisp signal atoms rather than `is_float` values, so they fall
  through to the type-error clauses below.
  """
  def dot_substring(s, start) when is_binary(s) and is_float(start) do
    dot_substring(s, trunc(start))
  end

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
    raise ".substring: expected numeric start, got #{type_name(start)}"
  end

  def dot_substring(s, start, stop)
      when is_binary(s) and (is_float(start) or is_float(stop)) and
             is_number(start) and is_number(stop) do
    dot_substring(s, trunc(start), trunc(stop))
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

  def dot_substring(_s, start, _stop) when not is_number(start) do
    raise ".substring: expected numeric start, got #{type_name(start)}"
  end

  def dot_substring(_s, _start, stop) do
    raise ".substring: expected numeric stop, got #{type_name(stop)}"
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

  defp type_name(nil), do: "nil"
  defp type_name(x) when is_list(x), do: "list"
  defp type_name(x) when is_map(x), do: "map"
  defp type_name(x) when is_integer(x), do: "integer"
  defp type_name(x) when is_float(x), do: "float"
  defp type_name(x) when is_binary(x), do: "string"
  defp type_name(_), do: "non-string"
end
