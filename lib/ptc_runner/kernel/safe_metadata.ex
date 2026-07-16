defmodule PtcRunner.Kernel.SafeMetadata do
  @moduledoc """
  Validates the closed, payload-free metadata vocabulary used by canonical events.

  Safe metadata is intentionally less expressive than general JSON. Labels use
  only documented run fields and annotation data is a flat map of bounded
  identifiers and scalar values. Prompts, generated source, arbitrary nested
  application data, and free-form text therefore require private inspection.
  """

  @label_keys ~w(name model provider tags)
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,255}\z/
  @key ~r/\A[a-z][a-z0-9._-]{0,63}\z/

  @spec labels?(term()) :: boolean()
  @doc "Returns whether a value is an exact bounded canonical-label map."
  def labels?(labels) when is_map(labels) and not is_struct(labels) do
    keys = Map.keys(labels)

    keys -- @label_keys == [] and
      Enum.all?(Map.take(labels, ~w(name model provider)), fn {_key, value} ->
        identifier?(value)
      end) and tags?(Map.get(labels, "tags", %{}))
  end

  def labels?(_labels), do: false

  @spec annotation?(term(), term()) :: boolean()
  @doc "Returns whether an annotation type and flat data map are safe canonical metadata."
  def annotation?(type, data) when is_map(data) and not is_struct(data) do
    identifier?(type) and map_size(data) <= 32 and
      Enum.all?(data, fn {key, value} -> key?(key) and scalar?(value) end)
  end

  def annotation?(_type, _data), do: false

  defp tags?(tags) when is_map(tags) and not is_struct(tags) and map_size(tags) <= 32,
    do: Enum.all?(tags, fn {key, value} -> key?(key) and identifier?(value) end)

  defp tags?(_tags), do: false

  defp scalar?(value) when is_boolean(value) or is_nil(value) or is_integer(value), do: true
  defp scalar?(value) when is_float(value), do: value == value
  defp scalar?(value), do: identifier?(value)

  defp identifier?(value), do: is_binary(value) and String.valid?(value) and value =~ @identifier
  defp key?(value), do: is_binary(value) and String.valid?(value) and value =~ @key
end
