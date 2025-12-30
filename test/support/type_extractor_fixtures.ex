defmodule PtcRunner.TypeExtractorFixtures do
  @moduledoc false
  # Test fixtures for TypeExtractor testing
  # This module is compiled with docs/specs so they can be extracted at runtime

  @doc "Get the current time"
  @spec get_time() :: String.t()
  def get_time, do: "2025-12-30"

  @doc "Add two integers"
  @spec add(integer(), integer()) :: integer()
  def add(a, b), do: a + b

  @doc "Search for items matching query"
  @spec search(String.t(), integer()) :: [map()]
  def search(_query, _limit), do: []

  @doc "Get user by ID"
  @spec get_user(integer()) :: %{id: integer(), name: String.t()}
  def get_user(_id), do: %{id: 1, name: "Alice"}

  @doc "Check if value is positive"
  @spec positive?(number()) :: boolean()
  def positive?(n), do: n > 0

  @spec no_doc_function(String.t()) :: atom()
  def no_doc_function(_), do: :ok

  @doc "Function with no spec"
  def no_spec_function(_), do: :ok

  def no_doc_no_spec(_), do: :ok

  @doc "Function with float return"
  @spec calculate(integer(), float()) :: float()
  def calculate(_a, _b), do: 1.0

  @doc "Function with list of integers"
  @spec get_numbers() :: [integer()]
  def get_numbers, do: [1, 2, 3]

  @doc "Function with any type"
  @spec dynamic(term()) :: any()
  def dynamic(x), do: x

  @doc "Function with DateTime"
  @spec get_datetime() :: DateTime.t()
  def get_datetime, do: DateTime.utc_now()

  @doc "Function with map type"
  @spec get_config() :: map()
  def get_config, do: %{}

  @doc """
  Multi-line documentation.

  This function does something important.
  It has multiple paragraphs.
  """
  @spec multi_line_doc(String.t()) :: :ok
  def multi_line_doc(_), do: :ok
end
