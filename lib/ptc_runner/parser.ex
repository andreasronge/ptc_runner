defmodule PtcRunner.Parser do
  @moduledoc """
  Parses JSON strings or maps into AST representation.

  Accepts JSON strings or already-parsed maps and returns
  either the parsed result or a descriptive error.
  """

  @doc """
  Parses JSON string or map into AST.

  Expects input to be wrapped in a `{"program": ...}` format.
  Extracts the program field and returns it.

  ## Arguments
    - input: Either a JSON string or an already-parsed map

  ## Returns
    - `{:ok, map}` on success (the unwrapped program)
    - `{:error, {:parse_error, message}}` on parse error
  """
  @spec parse(String.t() | map()) :: {:ok, map()} | {:error, {:parse_error, String.t()}}
  def parse(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, %{"program" => program}} when is_map(program) -> {:ok, program}
      {:ok, %{"program" => _}} -> {:error, {:parse_error, "program must be a map"}}
      {:ok, _} -> {:error, {:parse_error, "Missing required field 'program'"}}
      {:error, reason} -> {:error, {:parse_error, "JSON decode error: #{inspect(reason)}"}}
    end
  end

  def parse(%{"program" => program}) when is_map(program), do: {:ok, program}
  def parse(%{"program" => _}), do: {:error, {:parse_error, "program must be a map"}}

  def parse(input) when is_map(input),
    do: {:error, {:parse_error, "Missing required field 'program'"}}

  def parse(input) do
    {:error, {:parse_error, "Input must be a string or map, got #{inspect(input)}"}}
  end
end
