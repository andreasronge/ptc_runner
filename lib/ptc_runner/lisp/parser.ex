defmodule PtcRunner.Lisp.Parser do
  @moduledoc """
  Parser entry point for PTC-Lisp.

  Delegates to the internal fast parser for the actual parse, adding pre-flight
  checks for unsupported syntax and unsupported-pattern error messages.

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
    case parse_with_position(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, {:parse_error, message, _position}} -> {:error, {:parse_error, message}}
    end
  end

  @doc false
  @spec parse_with_position(String.t()) ::
          {:ok, AST.t()} | {:error, {:parse_error, String.t(), non_neg_integer() | nil}}
  def parse_with_position(source) when is_binary(source) do
    # Check for unsupported syntax before parsing
    with :ok <- check_unsupported_syntax(source) do
      do_parse_with_position(source)
    end
  end

  defp check_unsupported_syntax(source) do
    case check_unsupported_patterns(source) do
      nil -> :ok
      message -> {:error, {:parse_error, message, nil}}
    end
  end

  defp do_parse_with_position(source) do
    case FastParser.parse_with_position(source) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, reason, position} ->
        {:error, {:parse_error, reason, position}}
    end
  rescue
    e in ArgumentError -> {:error, {:parse_error, e.message, nil}}
  end

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
