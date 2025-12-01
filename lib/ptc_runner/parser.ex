defmodule PtcRunner.Parser do
  @moduledoc """
  Parses JSON strings or maps into AST representation.

  Accepts JSON strings or already-parsed maps and returns
  either the parsed result or a descriptive error.
  """

  @doc """
  Parses JSON string or map into AST.

  ## Arguments
    - input: Either a JSON string or an already-parsed map

  ## Returns
    - `{:ok, map}` on success
    - `{:error, {:parse_error, message}}` on JSON parse error
  """
  @spec parse(String.t() | map()) :: {:ok, map()} | {:error, {:parse_error, String.t()}}
  def parse(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:parse_error, "JSON decode error: #{inspect(reason)}"}}
    end
  end

  def parse(input) when is_map(input) do
    {:ok, input}
  end

  def parse(input) do
    {:error, {:parse_error, "Input must be a string or map, got #{inspect(input)}"}}
  end
end
