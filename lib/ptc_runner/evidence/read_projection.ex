defmodule PtcRunner.Evidence.ReadProjection do
  @moduledoc false

  @safe_keys ~w(bundle_id item_id source_ref checksum bytes truncated)

  @spec from_result(term()) :: [map()]
  def from_result(%{"items" => items}) when is_list(items) do
    items
    |> Enum.map(&from_item/1)
    |> Enum.reject(&is_nil/1)
  end

  def from_result(%{} = item) do
    case from_item(item) do
      nil -> []
      read -> [read]
    end
  end

  def from_result(_result), do: []

  @spec normalize(term()) :: [map()]
  def normalize(reads) when is_list(reads) do
    reads
    |> Enum.map(&normalize_read/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize(_reads), do: []

  defp from_item(item) when is_map(item), do: normalize_read(item)
  defp from_item(_item), do: nil

  defp normalize_read(read) when is_map(read) do
    bundle_id = string_or_nil(get_key(read, :bundle_id))
    item_id = string_or_nil(get_key(read, :item_id))
    checksum = string_or_nil(get_key(read, :checksum))

    if is_binary(bundle_id) and is_binary(item_id) and is_binary(checksum) do
      read
      |> Map.take(@safe_keys)
      |> Map.merge(%{
        "bundle_id" => bundle_id,
        "item_id" => item_id,
        "source_ref" => string_or_nil(get_key(read, :source_ref)),
        "checksum" => checksum,
        "bytes" => get_key(read, :bytes),
        "truncated" => get_key(read, :truncated) == true
      })
    end
  end

  defp normalize_read(_read), do: nil

  defp get_key(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp string_or_nil(nil), do: nil
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(value), do: to_string(value)
end
