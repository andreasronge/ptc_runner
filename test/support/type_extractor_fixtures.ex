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

  @doc "Function with multiple specs"
  @spec filter_items(String.t()) :: [map()]
  @spec filter_items(String.t(), integer()) :: [map()]
  def filter_items(_query, _limit \\ 10), do: []

  # Custom type definitions for testing type expansion
  @type user :: %{id: integer(), name: String.t()}
  @type user_list :: [user()]
  @type nested_type :: %{user: user(), created_at: String.t()}

  @doc "Function using custom type"
  @spec get_custom_user(integer()) :: user()
  def get_custom_user(_id), do: %{id: 1, name: "Alice"}

  @doc "Function with nested custom type"
  @spec get_nested(integer()) :: nested_type()
  def get_nested(_id), do: %{user: %{id: 1, name: "Alice"}, created_at: "2025-12-30"}

  @doc "Function with list of custom types"
  @spec list_users() :: user_list()
  def list_users, do: []

  # Opaque type for testing
  @opaque secret :: binary()

  @doc "Function with opaque type"
  @spec get_secret() :: secret()
  def get_secret, do: "secret"

  # Deeply nested type for testing depth limit
  @type level1 :: %{data: level2()}
  @type level2 :: %{data: level3()}
  @type level3 :: %{data: level4()}
  @type level4 :: %{value: String.t()}

  @doc "Function with deeply nested type"
  @spec get_deep() :: level1()
  def get_deep, do: %{data: %{data: %{data: %{value: "deep"}}}}

  # Self-referential type for testing recursive fallback
  @type tree :: %{value: integer(), children: [tree()]}

  @doc "Function with self-referential type"
  @spec get_tree() :: tree()
  def get_tree, do: %{value: 1, children: []}
end
