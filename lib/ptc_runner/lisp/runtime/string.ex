defmodule PtcRunner.Lisp.Runtime.String do
  @moduledoc """
  String manipulation and parsing operations for PTC-Lisp runtime.

  Provides string concatenation, substring, join, split, and parsing functions.
  """

  @doc """
  Convert one or more values to string and concatenate.
  - (str) returns ""
  - (str "hello") returns "hello"
  - (str "a" "b") returns "ab"
  - (str 42) returns "42"
  - (str nil) returns "" (not "nil")
  - (str :keyword) returns ":keyword"
  - (str true) returns "true"

  Binary reducer used with :variadic binding type.
  """
  def str2(a, b), do: to_str(a) <> to_str(b)

  defp to_str(nil), do: ""
  defp to_str(s) when is_binary(s), do: s
  defp to_str(:infinity), do: "Infinity"
  defp to_str(:negative_infinity), do: "-Infinity"
  defp to_str(:nan), do: "NaN"
  defp to_str(atom) when is_atom(atom), do: inspect(atom)
  defp to_str(x), do: inspect(x)

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
  Return lines matching the pattern (regex).
  String patterns are compiled as regex with BRE-to-PCRE translation
  (e.g. `\\|` becomes `|` for alternation).
  - (grep "error" text) returns lines containing "error"
  - (grep "error\\|warn" text) returns lines matching error or warn
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
  String patterns are compiled as regex with BRE-to-PCRE translation.
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

  # Translate BRE escapes to PCRE and compile as regex.
  # LLMs often write \| for alternation (BRE style) but PCRE treats \| as literal pipe.
  defp compile_grep_pattern(pattern) do
    alias PtcRunner.Lisp.Runtime.Regex, as: RuntimeRegex

    pattern
    |> bre_to_pcre()
    |> RuntimeRegex.re_pattern()
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
