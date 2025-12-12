defmodule PtcRunner.Json.Operations.Helpers do
  @moduledoc """
  Helper functions for JSON DSL operations.

  Provides shared utilities for membership checks and other common operations.
  """

  @doc """
  Checks if a value is a member of a collection (list or map).

  For lists, checks if the value is in the list using the `in` operator.
  For maps, checks if the value is a key in the map.
  Returns false for other types.

  ## Examples

      iex> PtcRunner.Json.Operations.Helpers.member_of?("apple", ["apple", "banana"])
      true

      iex> PtcRunner.Json.Operations.Helpers.member_of?("grape", ["apple", "banana"])
      false

      iex> PtcRunner.Json.Operations.Helpers.member_of?("name", %{"name" => "John", "age" => 30})
      true

      iex> PtcRunner.Json.Operations.Helpers.member_of?("email", %{"name" => "John"})
      false

      iex> PtcRunner.Json.Operations.Helpers.member_of?("value", "not a collection")
      false
  """
  @spec member_of?(any(), any()) :: boolean()
  def member_of?(value, collection) when is_list(collection), do: value in collection
  def member_of?(value, collection) when is_map(collection), do: Map.has_key?(collection, value)
  def member_of?(_value, _collection), do: false
end
