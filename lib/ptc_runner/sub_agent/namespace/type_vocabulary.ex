defmodule PtcRunner.SubAgent.Namespace.TypeVocabulary do
  @moduledoc "Converts Elixir values to human-readable type labels."

  @doc """
  Returns a type label for any value.

  ## Examples

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of([])
      "list[0]"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of([1, 2, 3])
      "list[3]"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(%{})
      "map[0]"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(%{a: 1})
      "map[1]"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(MapSet.new([1, 2]))
      "set[2]"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of({:closure, [], nil, %{}, [], %{}})
      "#fn[...]"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of("hello")
      "string"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(42)
      "integer"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(3.14)
      "float"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(true)
      "boolean"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(false)
      "boolean"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(:foo)
      "keyword"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(nil)
      "nil"

      iex> PtcRunner.SubAgent.Namespace.TypeVocabulary.type_of(fn -> :ok end)
      "fn"
  """
  @spec type_of(term()) :: String.t()
  def type_of([]), do: "list[0]"
  def type_of(list) when is_list(list), do: "list[#{length(list)}]"
  def type_of(%MapSet{} = set), do: "set[#{MapSet.size(set)}]"
  def type_of(map) when is_map(map), do: "map[#{map_size(map)}]"
  def type_of(s) when is_binary(s), do: "string"
  def type_of(n) when is_integer(n), do: "integer"
  def type_of(f) when is_float(f), do: "float"
  def type_of(true), do: "boolean"
  def type_of(false), do: "boolean"
  def type_of(nil), do: "nil"
  def type_of(a) when is_atom(a), do: "keyword"
  def type_of({:closure, _, _, _, _, _}), do: "#fn[...]"
  def type_of({:closure, _, _, _, _}), do: "#fn[...]"
  def type_of(f) when is_function(f), do: "fn"
  def type_of(_), do: "unknown"
end
