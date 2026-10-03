defmodule PtcRunner.Lisp.Runtime.Regex do
  @moduledoc """
  Minimal, safe Regex support for PTC-Lisp.
  Uses Erlang's :re with uniform match and recursion limits for ReDoS protection.
  Inputs must be valid UTF-8 and are truncated to a complete codepoint within
  32,768 bytes. Invalid inputs and limit failures raise exceptions that the
  interpreter converts to recoverable signals.
  """

  alias PtcRunner.Lisp.Runtime.String, as: RuntimeString

  @match_limit 100_000
  @recursion_limit 1_000
  @max_input_bytes 32_768
  @max_pattern_bytes 256

  @doc """
  Compile a string into a regex.
  Returns opaque {:re_mp, mp, anchored_mp, source} tuple.
  Both normal and anchored versions are pre-compiled for performance and safety.
  Source patterns are limited to 256 bytes and use Unicode character classes.
  Additional compile options support case-insensitive grep matching.
  """
  def re_pattern(s, options \\ []) when is_binary(s) do
    if byte_size(s) > @max_pattern_bytes do
      raise ArgumentError, "Regex pattern exceeds maximum length of #{@max_pattern_bytes} bytes"
    end

    mp = compile!(s, options)
    anchored_mp = compile!("\\A(?:#{s})\\z", options)
    {:re_mp, mp, anchored_mp, s}
  end

  defp compile!(source, options) do
    case :re.compile(source, [:unicode, :ucp | options]) do
      {:ok, mp} ->
        mp

      {:error, {reason, pos}} ->
        raise ArgumentError, "Invalid regex at position #{pos}: #{List.to_string(reason)}"
    end
  end

  @doc """
  Find first match of regex in string.
  Returns string if no groups, or vector of [full match, group1, ...] if groups.
  """
  def re_find({:re_mp, mp, _, _}, s) when is_binary(s) do
    run_safe(s, mp, [], fn _input, result -> first_match(result) end)
  end

  @doc """
  Returns match if regex matches the entire truncated string.
  """
  def re_matches({:re_mp, _, anchored_mp, _}, s) when is_binary(s) do
    run_safe(s, anchored_mp, [], fn _input, result -> first_match(result) end)
  end

  @run_limits [match_limit: @match_limit, match_limit_recursion: @recursion_limit]

  # split/replace reject :report_errors. Preflight the same global scan before
  # invoking them, and keep the limits on their second scan as well.
  defp run_safe(s, mp, options, finish) do
    input = truncate_input(s)

    result =
      :re.run(input, mp, [:report_errors, {:capture, :all, :binary}] ++ options ++ @run_limits)

    case result do
      {:error, :match_limit} ->
        raise RuntimeError, "Regex complexity limit exceeded (ReDoS protection)"

      {:error, :match_limit_recursion} ->
        raise RuntimeError, "Regex recursion limit exceeded"

      {:error, reason} ->
        raise RuntimeError, "Regex execution error: #{inspect(reason)}"

      result ->
        finish.(input, result)
    end
  end

  defp truncate_input(s) do
    unless String.valid?(s) do
      raise ArgumentError, "Regex input must be valid UTF-8"
    end

    if byte_size(s) > @max_input_bytes do
      binary_part(s, 0, codepoint_boundary(s, @max_input_bytes))
    else
      s
    end
  end

  # The original string is valid, so a continuation byte at the cut means
  # the preceding codepoint is incomplete. Back off at most three bytes.
  defp codepoint_boundary(s, offset) do
    if :binary.at(s, offset) in 0x80..0xBF do
      codepoint_boundary(s, offset - 1)
    else
      offset
    end
  end

  defp first_match(:nomatch), do: nil
  defp first_match({:match, matches}), do: unwrap(matches)
  defp unwrap([full]), do: full
  defp unwrap(matches) when is_list(matches), do: matches

  @doc """
  Split the bounded UTF-8 input by regex pattern, reporting limit failures.
  Returns list of substrings, including captured delimiters.
  """
  def re_split({:re_mp, mp, _, _}, s) when is_binary(s) do
    run_safe(s, mp, [:global], fn input, _result ->
      :re.split(input, mp, @run_limits)
    end)
  end

  @doc """
  Replace all matches in the bounded UTF-8 input, reporting limit failures.
  Replacement syntax follows Erlang's `:re.replace/4`.
  """
  def re_replace({:re_mp, mp, _, _}, s, replacement)
      when is_binary(s) and is_binary(replacement) do
    run_safe(s, mp, [:global], fn input, _result ->
      :re.replace(input, mp, replacement, [:global, {:return, :binary} | @run_limits])
    end)
  end

  @doc """
  Find all matches of regex in string.
  Returns list of matches (empty list if no matches).
  """
  def re_seq({:re_mp, mp, _, _}, s) when is_binary(s) do
    run_safe(s, mp, [:global], fn
      _input, :nomatch -> []
      _input, {:match, matches} -> Enum.map(matches, &unwrap/1)
    end)
  end

  # ============================================================
  # Extract Functions - Simplified regex capture group extraction
  # ============================================================

  @doc """
  Extract a capture group from a regex match.

  - `(extract "ID:(\\d+)" "ID:42")` => "42" (group 1)
  - `(extract "ID:(\\d+)" "ID:42" 0)` => "ID:42" (full match)
  - `(extract regex string 2)` => group 2

  Accepts both string patterns and compiled regex objects.
  """
  def extract(pattern, string) when is_binary(string) do
    extract(pattern, string, 1)
  end

  def extract(pattern, string, group) when is_binary(string) and is_integer(group) do
    # Accept both string patterns and compiled regex
    re = if is_binary(pattern), do: re_pattern(pattern), else: pattern

    case re_find(re, string) do
      nil -> nil
      result when is_binary(result) -> if group == 0, do: result, else: nil
      result when is_list(result) -> Enum.at(result, group)
    end
  end

  @doc """
  Extract a capture group and parse as integer.

  2-arity: extracts group 1, returns nil on failure
  - `(extract-int "age=(\\d+)" "age=25")` => 25

  4-arity: extracts specified group with default value
  - `(extract-int "age=(\\d+)" "no match" 1 0)` => 0 (group 1, default 0)
  - `(extract-int "x=(\\d+) y=(\\d+)" s 2 0)` => group 2 with default 0

  Accepts both string patterns and compiled regex objects.
  """
  def extract_int(pattern, string) when is_binary(string) do
    extract_int(pattern, string, 1, nil)
  end

  def extract_int(pattern, string, group) when is_binary(string) and is_integer(group) do
    extract_int(pattern, string, group, nil)
  end

  def extract_int(pattern, string, group, default) when is_binary(string) and is_integer(group) do
    case extract(pattern, string, group) do
      nil -> default
      s -> RuntimeString.parse_long(s) || default
    end
  end
end
