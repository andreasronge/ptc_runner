defmodule PtcRunner.Lisp.Runtime.Regex do
  @moduledoc """
  Minimal, safe Regex support for PTC-Lisp.
  Uses Erlang's :re directly with match limits for ReDoS protection.
  """

  @match_limit 100_000
  @recursion_limit 1_000
  @max_input_bytes 32_768
  @max_pattern_bytes 256

  @doc """
  Compile a string into a regex.
  Returns opaque {:re_mp, mp, anchored_mp, source} tuple.
  Both normal and anchored versions are pre-compiled for performance and safety.
  """
  def re_pattern(s) when is_binary(s) do
    if byte_size(s) > @max_pattern_bytes do
      raise ArgumentError, "Regex pattern exceeds maximum length of #{@max_pattern_bytes} bytes"
    end

    case :re.compile(s, [:unicode, :ucp]) do
      {:ok, mp} ->
        # Pre-compile anchored version for re-matches to avoid runtime overhead and limit bypass
        anchored_source = "\\A(?:#{s})\\z"

        case :re.compile(anchored_source, [:unicode, :ucp]) do
          {:ok, anchored_mp} ->
            {:re_mp, mp, anchored_mp, s}

          {:error, {reason, _}} ->
            # This should rarely happen if 's' is valid
            raise ArgumentError, "Failed to anchor regex: #{List.to_string(reason)}"
        end

      {:error, {reason, pos}} ->
        raise ArgumentError, "Invalid regex at position #{pos}: #{List.to_string(reason)}"
    end
  end

  @doc """
  Find first match of regex in string.
  Returns string if no groups, or vector of [full match, group1, ...] if groups.
  """
  def re_find({:re_mp, mp, _, _}, s) when is_binary(s) do
    s
    |> truncate_input()
    |> run_safe(mp)
  end

  @doc """
  Returns match if regex matches the entire string.
  """
  def re_matches({:re_mp, _, anchored_mp, _}, s) when is_binary(s) do
    s
    |> truncate_input()
    |> run_safe(anchored_mp)
  end

  defp run_safe(input, mp) do
    opts = [
      :report_errors,
      {:match_limit, @match_limit},
      {:match_limit_recursion, @recursion_limit},
      {:capture, :all, :binary}
    ]

    case :re.run(input, mp, opts) do
      {:match, matches} ->
        unwrap(matches)

      :nomatch ->
        nil

      {:error, :match_limit} ->
        raise RuntimeError, "Regex complexity limit exceeded (ReDoS protection)"

      {:error, :match_limit_recursion} ->
        raise RuntimeError, "Regex recursion limit exceeded"

      {:error, reason} ->
        raise RuntimeError, "Regex execution error: #{inspect(reason)}"
    end
  end

  defp truncate_input(s) do
    if byte_size(s) > @max_input_bytes do
      binary_part(s, 0, @max_input_bytes)
    else
      s
    end
  end

  defp unwrap([full]), do: full
  defp unwrap(matches) when is_list(matches), do: matches

  @doc """
  Split string by regex pattern.
  Returns list of substrings.

  ## Examples
      (re-split (re-pattern "\\s+") "a  b   c") => ["a" "b" "c"]
      (re-split (re-pattern ",") "a,b,c") => ["a" "b" "c"]
  """
  def re_split({:re_mp, mp, _, _}, s) when is_binary(s) do
    input = truncate_input(s)

    opts = [
      {:match_limit, @match_limit},
      {:match_limit_recursion, @recursion_limit}
    ]

    case :re.split(input, mp, opts) do
      parts when is_list(parts) ->
        parts

      {:error, :match_limit} ->
        raise RuntimeError, "Regex complexity limit exceeded (ReDoS protection)"

      {:error, :match_limit_recursion} ->
        raise RuntimeError, "Regex recursion limit exceeded"

      {:error, reason} ->
        raise RuntimeError, "Regex execution error: #{inspect(reason)}"
    end
  end
end
