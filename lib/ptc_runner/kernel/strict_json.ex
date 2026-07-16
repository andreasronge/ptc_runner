defmodule PtcRunner.Kernel.StrictJSON do
  @moduledoc """
  Duplicate-rejecting JSON decoding for authority and protocol boundaries.

  Objects are decoded as ordered key-value pairs first, then recursively
  converted to ordinary maps only when every object key is unique.
  """

  alias Jason.OrderedObject

  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_json | :duplicate_json_key}
  @doc "Decodes one JSON value and rejects duplicate keys at every nesting level."
  def decode(source) when is_binary(source) do
    case Jason.decode(source, objects: :ordered_objects) do
      {:ok, decoded} -> value(decoded)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  def decode(_source), do: {:error, :invalid_json}

  defp value(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, item}, {:ok, map} ->
        case value(item) do
          {:ok, item} -> {:cont, {:ok, Map.put(map, key, item)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_json_key}
    end
  end

  defp value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn item, {:ok, normalized} ->
      case value(item) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp value(value), do: {:ok, value}
end
