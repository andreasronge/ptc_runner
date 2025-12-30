defmodule PtcRunner.SubAgent.Signature.ParserHelpers do
  @moduledoc """
  Helper functions for signature parser AST building.
  """

  @doc """
  Concatenate identifier parts (first char + optional rest).
  """
  def concat_identifier([first, rest]) when is_binary(first) and is_binary(rest) do
    first <> rest
  end

  def concat_identifier([first]) when is_binary(first) do
    first
  end

  @doc """
  Build a type from primitive type keyword and optional suffix.
  """
  def build_type([type, {:optional}]) do
    {:optional, type}
  end

  def build_type([type]) do
    type
  end

  @doc """
  Build a list type wrapper.
  """
  def wrap_list([element_type]) do
    {:list, element_type}
  end

  @doc """
  Build a map field (key :type).
  """
  def build_map_field([name, type]) do
    {name, type}
  end

  @doc """
  Build a parameter (name :type).
  """
  def build_parameter([name, type]) do
    {name, type}
  end

  @doc """
  Flatten lists from repeat parsing.

  When parsing with repeat(), we get [first_result, [rest_result_1, rest_result_2, ...]]
  This returns [first_result, rest_result_1, rest_result_2, ...]
  """
  def flatten_list([first | rest]) when is_list(rest) do
    [first | Enum.flat_map(rest, &flatten_item/1)]
  end

  def flatten_list([first]), do: [first]
  def flatten_list(item), do: [item]

  defp flatten_item(item) when is_list(item), do: item
  defp flatten_item(item), do: [item]

  @doc """
  Build a map type wrapper.
  """
  def build_map_type([nil]) do
    {:map, []}
  end

  def build_map_type([fields]) when is_list(fields) do
    {:map, fields}
  end

  def build_map_type([]) do
    {:map, []}
  end

  @doc """
  Build full signature from parameters and return type.

  When optional(parsec(:parameters_list)) doesn't match,
  we get just [return_type]. When it does match, we get [params, return_type].
  """
  def build_full_signature([params, return_type]) when is_list(params) and params != [] do
    {:signature, params, return_type}
  end

  def build_full_signature([[], return_type]) do
    # When parameters_list matches but is empty: [[]]
    {:signature, [], return_type}
  end

  def build_full_signature([return_type]) do
    # When optional(parameters_list) doesn't match, we get just [return_type]
    {:signature, [], return_type}
  end

  @doc """
  Build shorthand signature (no input, just output).
  """
  def build_shorthand_signature([return_type]) do
    {:signature, [], return_type}
  end
end
