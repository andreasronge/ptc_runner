defmodule PtcRunner.Lisp.Runtime.String do
  @moduledoc """
  String manipulation and parsing operations for PTC-Lisp runtime.

  Provides string concatenation, substring, join, split, and parsing functions.
  """

  @doc """
  Convert zero or more values to string and concatenate.

  Used as a `:collect` binding for the `str` builtin.

  - `(str)` returns `""`
  - `(str 42)` returns `"42"`
  - `(str "a" "b")` returns `"ab"`
  - `(str nil)` returns `""` (not `"nil"`)
  - `(str :keyword)` returns `":keyword"`
  - `(str true)` returns `"true"`
  """
  def str_variadic(args), do: Enum.map_join(args, &to_str/1)

  def to_str(nil), do: ""
  def to_str(s) when is_binary(s), do: s
  def to_str(:infinity), do: "Infinity"
  def to_str(:negative_infinity), do: "-Infinity"
  def to_str(:nan), do: "NaN"
  def to_str(atom) when is_atom(atom), do: inspect(atom)
  def to_str(x), do: inspect(x)

  @doc """
  Return substring starting at index (2-arity) or from start to end (3-arity).
  - (subs "hello" 1) returns "ello"
  - (subs "hello" 1 3) returns "el"
  - (subs "hello" 0 0) returns ""
  - Out of bounds returns truncated result
  - Negative indices are clamped to 0
  """
  def subs(s, start) when is_binary(s) and is_integer(start) do
    start = max(0, start)
    String.slice(s, start..-1//1)
  end

  def subs(s, start, end_idx) when is_binary(s) and is_integer(start) and is_integer(end_idx) do
    start = max(0, start)
    len = max(0, end_idx - start)
    String.slice(s, start, len)
  end

  @doc """
  Join a collection into a string with optional separator.
  - (join ["a" "b" "c"]) returns "abc"
  - (join ", " ["a" "b" "c"]) returns "a, b, c"
  - (join "-" [1 2 3]) returns "1-2-3"
  - (join ", " []) returns ""
  """
  def join(coll) when is_list(coll) do
    Enum.map_join(coll, &to_str/1)
  end

  def join(separator, coll) when is_binary(separator) and is_list(coll) do
    Enum.map_join(coll, separator, &to_str/1)
  end

  @doc """
  Split a string by separator.
  - (split "a,b,c" ",") returns ["a" "b" "c"]
  - (split "hello" "") returns ["h" "e" "l" "l" "o"]
  - (split "a,,b" ",") returns ["a" "" "b"]
  """
  def split(s, "") when is_binary(s), do: String.graphemes(s)

  def split(s, separator) when is_binary(s) and is_binary(separator) do
    String.split(s, separator)
  end

  @doc """
  Split a string into a list of lines.
  - (split-lines "line1\nline2\r\nline3") returns ["line1" "line2" "line3"]
  - Does not return trailing empty lines.
  """
  def split_lines(s) when is_binary(s) do
    s
    |> String.split(~r/\r?\n/)
    |> drop_trailing_empty()
  end

  defp drop_trailing_empty(list) do
    list
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @doc """
  Trim leading and trailing whitespace.
  - (trim "  hello  ") returns "hello"
  - (trim "\n\t text \r\n") returns "text"
  """
  def trim(s) when is_binary(s) do
    String.trim(s)
  end

  @doc """
  Replace all occurrences of a pattern in a string.
  - (replace "hello" "l" "L") returns "heLLo"
  - (replace "aaa" "a" "b") returns "bbb"
  """
  def replace(s, pattern, replacement)
      when is_binary(s) and is_binary(pattern) and is_binary(replacement) do
    String.replace(s, pattern, replacement)
  end

  @doc """
  Convert string to uppercase.
  - (upcase "hello") returns "HELLO"
  - (upcase "") returns ""
  """
  def upcase(s) when is_binary(s) do
    String.upcase(s)
  end

  @doc """
  Convert string to lowercase.
  - (downcase "HELLO") returns "hello"
  - (downcase "") returns ""
  """
  def downcase(s) when is_binary(s) do
    String.downcase(s)
  end

  @doc """
  Check if string starts with prefix.
  - (starts-with? "hello" "he") returns true
  - (starts-with? "hello" "x") returns false
  - (starts-with? "hello" "") returns true
  """
  def starts_with?(s, prefix) when is_binary(s) and is_binary(prefix) do
    String.starts_with?(s, prefix)
  end

  @doc """
  Check if string ends with suffix.
  - (ends-with? "hello" "lo") returns true
  - (ends-with? "hello" "x") returns false
  - (ends-with? "hello" "") returns true
  """
  def ends_with?(s, suffix) when is_binary(s) and is_binary(suffix) do
    String.ends_with?(s, suffix)
  end

  @doc """
  Check if string contains substring.
  - (includes? "hello" "ll") returns true
  - (includes? "hello" "x") returns false
  - (includes? "hello" "") returns true
  """
  def includes?(s, substring) when is_binary(s) and is_binary(substring) do
    String.contains?(s, substring)
  end

  @doc """
  Return lines matching the pattern (case-insensitive regex).
  String patterns are compiled as regex with BRE-to-PCRE translation
  (e.g. `\\|` becomes `|` for alternation).
  Matching is case-insensitive by default.
  - (grep "error" text) returns lines containing "error", "Error", "ERROR", etc.
  - (grep "error\\|warn" text) returns lines matching error or warn (any case)
  - (grep "" "a\\nb") returns ["a", "b"] (empty pattern matches all)
  """
  def grep("", text) when is_binary(text) do
    split_lines(text)
  end

  def grep(pattern, text) when is_binary(pattern) and is_binary(text) do
    grep(compile_grep_pattern(pattern), text)
  end

  def grep({:re_mp, _, _, _} = re, text) when is_binary(text) do
    alias PtcRunner.Lisp.Runtime.Regex, as: RuntimeRegex

    text
    |> split_lines()
    |> Enum.filter(&(RuntimeRegex.re_find(re, &1) != nil))
  end

  @doc """
  Return lines matching the pattern with 1-based line numbers.
  String patterns are compiled as case-insensitive regex with BRE-to-PCRE translation.
  - (grep-n "error" text) returns [{:line 1 :text "error here"} ...]
  """
  def grep_n("", text) when is_binary(text) do
    text
    |> split_lines()
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} -> %{line: idx, text: line} end)
  end

  def grep_n(pattern, text) when is_binary(pattern) and is_binary(text) do
    grep_n(compile_grep_pattern(pattern), text)
  end

  def grep_n({:re_mp, _, _, _} = re, text) when is_binary(text) do
    alias PtcRunner.Lisp.Runtime.Regex, as: RuntimeRegex

    text
    |> split_lines()
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} -> RuntimeRegex.re_find(re, line) != nil end)
    |> Enum.map(fn {line, idx} -> %{line: idx, text: line} end)
  end

  # Translate BRE escapes to PCRE and compile as case-insensitive regex.
  # LLMs often write \| for alternation (BRE style) but PCRE treats \| as literal pipe.
  # Case-insensitive by default since grep is used for document search where case shouldn't matter.
  defp compile_grep_pattern(pattern) do
    pcre = bre_to_pcre(pattern)

    case :re.compile(pcre, [:unicode, :ucp, :caseless]) do
      {:ok, mp} ->
        {:re_mp, mp, nil, pcre}

      {:error, {reason, pos}} ->
        raise ArgumentError, "Invalid regex at position #{pos}: #{List.to_string(reason)}"
    end
  end

  # Convert common BRE escape sequences to PCRE equivalents.
  # BRE uses \| \( \) for special meaning; PCRE uses | ( ) unescaped.
  defp bre_to_pcre(pattern) do
    pattern
    |> String.replace("\\|", "|")
    |> String.replace("\\(", "(")
    |> String.replace("\\)", ")")
  end

  # ============================================================
  # String Index
  # ============================================================

  @doc """
  Return the index of the first occurrence of value in s, or nil if not found.
  Optionally starts searching from a given index.

  Uses grapheme indices (not byte offsets or UTF-16 code units) for consistency
  with `subs`, `count`, and other PTC-Lisp string functions.

  - (index-of "hello" "l") returns 2
  - (index-of "hello" "x") returns nil
  - (index-of "hello" "l" 3) returns 3
  - (index-of "hello" "" ) returns 0
  """
  def index_of(s, value) when is_binary(s) and is_binary(value) do
    if value == "" do
      0
    else
      case :binary.match(s, value) do
        {byte_offset, _len} -> byte_offset_to_grapheme_index(s, byte_offset)
        :nomatch -> nil
      end
    end
  end

  def index_of(s, value, from_index)
      when is_binary(s) and is_binary(value) and is_integer(from_index) do
    from_index = max(0, from_index)
    len = String.length(s)

    if value == "" do
      min(from_index, len)
    else
      if from_index >= len do
        nil
      else
        byte_start = grapheme_index_to_byte_offset(s, from_index)
        scope = {byte_start, byte_size(s) - byte_start}

        case :binary.match(s, value, scope: scope) do
          {byte_offset, _len} -> byte_offset_to_grapheme_index(s, byte_offset)
          :nomatch -> nil
        end
      end
    end
  end

  @doc """
  Return the index of the last occurrence of value in s, or nil if not found.
  Optionally searches backwards from a given index.

  Correctly handles overlapping matches: `(last-index-of "aaa" "aa")` returns 1.

  Uses grapheme indices (not byte offsets or UTF-16 code units) for consistency
  with `subs`, `count`, and other PTC-Lisp string functions.

  - (last-index-of "hello" "l") returns 3
  - (last-index-of "hello" "x") returns nil
  - (last-index-of "hello" "l" 2) returns 2
  - (last-index-of "hello" "") returns 5
  - (last-index-of "aaa" "aa") returns 1
  """
  def last_index_of(s, value) when is_binary(s) and is_binary(value) do
    if value == "" do
      String.length(s)
    else
      find_last_byte_offset(s, value, byte_size(s) - byte_size(value))
      |> maybe_byte_offset_to_grapheme(s)
    end
  end

  def last_index_of(s, value, from_index)
      when is_binary(s) and is_binary(value) and is_integer(from_index) do
    from_index = max(0, from_index)

    if value == "" do
      min(from_index, String.length(s))
    else
      # from_index is the last grapheme starting position to consider
      max_byte = grapheme_index_to_byte_offset(s, min(from_index, String.length(s)))
      start = min(max_byte, byte_size(s) - byte_size(value))

      find_last_byte_offset(s, value, start)
      |> maybe_byte_offset_to_grapheme(s)
    end
  end

  # Scan backwards byte-by-byte to find the last occurrence of value in s.
  # Handles overlapping matches correctly (unlike String.split).
  defp find_last_byte_offset(_s, _value, pos) when pos < 0, do: nil

  defp find_last_byte_offset(s, value, pos) do
    v_bytes = byte_size(value)

    if binary_part(s, pos, v_bytes) == value do
      pos
    else
      find_last_byte_offset(s, value, pos - 1)
    end
  end

  defp maybe_byte_offset_to_grapheme(nil, _s), do: nil

  defp maybe_byte_offset_to_grapheme(byte_offset, s),
    do: byte_offset_to_grapheme_index(s, byte_offset)

  defp byte_offset_to_grapheme_index(_s, 0), do: 0

  defp byte_offset_to_grapheme_index(s, byte_offset) do
    String.length(binary_part(s, 0, byte_offset))
  end

  defp grapheme_index_to_byte_offset(_s, 0), do: 0

  defp grapheme_index_to_byte_offset(s, grapheme_index) do
    byte_size(String.slice(s, 0, grapheme_index))
  end

  # ============================================================
  # String Parsing
  # ============================================================

  @doc """
  Parse string to integer. Returns nil on failure.
  Matches Clojure 1.11+ parse-long behavior.
  """
  def parse_long(nil), do: nil

  def parse_long(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def parse_long(_), do: nil

  @doc """
  Parse string to float. Returns nil on failure.
  Matches Clojure 1.11+ parse-double behavior.
  """
  def parse_double(nil), do: nil

  def parse_double(s) when is_binary(s) do
    case s do
      "Infinity" ->
        :infinity

      "+Infinity" ->
        :infinity

      "-Infinity" ->
        :negative_infinity

      "NaN" ->
        :nan

      _ ->
        case Float.parse(s) do
          {f, ""} -> f
          _ -> nil
        end
    end
  end

  def parse_double(_), do: nil
end
