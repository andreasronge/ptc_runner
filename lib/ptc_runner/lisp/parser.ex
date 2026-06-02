defmodule PtcRunner.Lisp.Parser do
  @moduledoc """
  Parser entry point for PTC-Lisp.

  Delegates to the internal fast parser for the actual parse, adding pre-flight
  checks for unsupported syntax and helpful delimiter-balance and
  unsupported-pattern error messages.

  Transforms source code into AST nodes.
  """

  alias PtcRunner.Lisp.AST
  alias PtcRunner.Lisp.FastParser

  @doc """
  Parse PTC-Lisp source code into AST.

  Returns `{:ok, ast}` or `{:error, {:parse_error, message}}`.
  """
  @spec parse(String.t()) :: {:ok, AST.t()} | {:error, {:parse_error, String.t()}}
  def parse(source) when is_binary(source) do
    # Check for unsupported syntax before parsing
    with :ok <- check_unsupported_syntax(source) do
      do_parse(source)
    end
  end

  defp check_unsupported_syntax(source) do
    case check_unsupported_patterns(source) do
      nil -> :ok
      message -> {:error, {:parse_error, message}}
    end
  end

  defp do_parse(source) do
    case FastParser.parse(source) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, reason} ->
        improved_reason =
          check_unsupported_patterns(source) ||
            delimiter_error_or_reason(source, reason)

        {:error, {:parse_error, improved_reason}}
    end
  rescue
    e in ArgumentError -> {:error, {:parse_error, e.message}}
  end

  defp delimiter_error_or_reason(source, reason) do
    case check_delimiter_balance(source) do
      "syntax error: could not parse expression" -> reason
      msg -> msg
    end
  end

  # Check for unbalanced delimiters and return a helpful error message
  defp check_delimiter_balance(source) do
    {parens, brackets, braces} = count_delimiters(source)

    format_delimiter_error(parens, "parentheses", "(", ")") ||
      format_delimiter_error(brackets, "brackets", "[", "]") ||
      format_delimiter_error(braces, "braces", "{", "}") ||
      "syntax error: could not parse expression"
  end

  defp count_delimiters(source) do
    source
    |> String.graphemes()
    |> Enum.reduce({0, 0, 0}, fn char, {p, b, br} ->
      case char do
        "(" -> {p + 1, b, br}
        ")" -> {p - 1, b, br}
        "[" -> {p, b + 1, br}
        "]" -> {p, b - 1, br}
        "{" -> {p, b, br + 1}
        "}" -> {p, b, br - 1}
        _ -> {p, b, br}
      end
    end)
  end

  defp format_delimiter_error(count, name, open, _close) when count > 0 do
    "unbalanced #{name}: #{count} unclosed '#{open}'"
  end

  defp format_delimiter_error(count, name, _open, close) when count < 0 do
    "unbalanced #{name}: #{-count} extra '#{close}'"
  end

  defp format_delimiter_error(0, _name, _open, _close), do: nil

  # Check for unsupported syntax patterns and return a helpful error message
  defp check_unsupported_patterns(source) do
    # Remove string literals to avoid false positives (e.g., "user@example.com")
    source_without_strings = Regex.replace(~r/"(?:[^"\\]|\\.)*"/, source, "\"\"")
    # Also remove comments to avoid false positives
    source_clean = Regex.replace(~r/;[^\n]*/, source_without_strings, "")

    cond do
      # Reader discard macro: #_ (Clojure-specific, not supported)
      Regex.match?(~r/#_/, source_clean) ->
        "reader discard syntax (#_) is not supported. Use ; for comments"

      # Deref syntax: @atom
      Regex.match?(~r/@[a-zA-Z]/, source_clean) ->
        "deref syntax (@var) is not supported. Atoms and refs are not available"

      # Quoted symbols are supported. Quoted collections remain intentionally unsupported.
      Regex.match?(~r/(?<!#)'[\(\[\{]/, source_clean) ->
        "quoted collections are not supported; only quoted symbols like 'github are allowed"

      true ->
        nil
    end
  end
end
