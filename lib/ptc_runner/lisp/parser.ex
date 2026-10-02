defmodule PtcRunner.Lisp.Parser do
  @moduledoc """
  Parser entry point for PTC-Lisp.

  Delegates to the internal fast parser, which reports unsupported reader syntax
  while consuming tokens. Strings and comments are handled in the same pass.

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
    case FastParser.parse_with_position(source) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, reason, position} ->
        {:error, {:parse_error, reason, position}}
    end
  rescue
    e in ArgumentError -> {:error, {:parse_error, e.message, nil}}
  end
end
