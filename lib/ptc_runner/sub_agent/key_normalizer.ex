defmodule PtcRunner.SubAgent.KeyNormalizer do
  @moduledoc """
  Normalizes map keys from hyphens to underscores at the tool boundary.

  PTC-Lisp uses Clojure conventions where LLMs naturally write hyphenated keywords
  (e.g., `:was-improved`). Elixir/JSON conventions use underscores. This module
  provides key normalization at the boundary between the two.
  """

  @doc """
  Recursively normalize map keys from hyphens to underscores.

  Converts Clojure-style `:was-improved` to Elixir-style `"was_improved"`.
  Works recursively on nested maps and lists.

  ## Examples

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_keys(%{"was-improved" => true})
      %{"was_improved" => true}

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_keys(%{nested: %{"foo-bar" => 1}})
      %{"nested" => %{"foo_bar" => 1}}

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_keys([%{"list-item" => 1}])
      [%{"list_item" => 1}]

  """
  @spec normalize_keys(term()) :: term()
  def normalize_keys(%_{} = value), do: value

  def normalize_keys(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {normalize_key(k), normalize_keys(v)} end)
  end

  def normalize_keys(value) when is_list(value) do
    Enum.map(value, &normalize_keys/1)
  end

  def normalize_keys(value), do: value

  @doc """
  Normalize a single key from hyphen to underscore format.

  ## Examples

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_key(:"was-improved")
      "was_improved"

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_key("foo-bar")
      "foo_bar"

      iex> PtcRunner.SubAgent.KeyNormalizer.normalize_key(:no_hyphens)
      "no_hyphens"

  """
  @spec normalize_key(atom() | binary() | term()) :: binary() | term()
  def normalize_key(k) when is_atom(k), do: k |> Atom.to_string() |> String.replace("-", "_")
  def normalize_key(k) when is_binary(k), do: String.replace(k, "-", "_")
  def normalize_key(k), do: k
end
