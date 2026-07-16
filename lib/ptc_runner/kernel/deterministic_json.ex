defmodule PtcRunner.Kernel.DeterministicJSON do
  @moduledoc """
  Internal deterministic encoder for frozen Kernel metadata and hashes.

  Ordinary maps require binary UTF-8 keys and are recursively sorted by key
  bytes. `{:object, pairs}` preserves an explicit key order for versioned
  projections and rejects duplicate keys before a map could erase them.
  Arrays retain their input order and output contains no insignificant
  whitespace.
  """

  @type ordered_object :: {:object, [{binary(), term()}]}

  @spec encode(term() | ordered_object()) ::
          {:ok, binary()} | {:error, :invalid_json | :duplicate_key}
  def encode(value) do
    case encode_value(value) do
      {:ok, encoded} -> {:ok, IO.iodata_to_binary(encoded)}
      error -> error
    end
  end

  defp encode_value({:object, pairs}) when is_list(pairs) do
    with :ok <- valid_pairs(pairs) do
      encode_pairs(pairs)
    end
  end

  defp encode_value(value) when is_map(value) and not is_struct(value) do
    pairs = Enum.sort_by(value, &elem(&1, 0))

    with :ok <- valid_pairs(pairs) do
      encode_pairs(pairs)
    end
  end

  defp encode_value(value) when is_list(value) do
    with {:ok, items} <- encode_many(value) do
      {:ok, [?[, join(items), ?]]}
    end
  end

  defp encode_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value) do
    case Jason.encode_to_iodata(value) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp encode_value(_value), do: {:error, :invalid_json}

  defp encode_pairs(pairs) do
    with {:ok, encoded} <-
           encode_many(pairs, fn {key, value} ->
             with {:ok, encoded_key} <- encode_value(key),
                  {:ok, encoded_value} <- encode_value(value) do
               {:ok, [encoded_key, ?:, encoded_value]}
             end
           end) do
      {:ok, [?{, join(encoded), ?}]}
    end
  end

  defp encode_many(values), do: encode_many(values, &encode_value/1)

  defp encode_many(values, encoder) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, encoded} ->
      case encoder.(value) do
        {:ok, item} -> {:cont, {:ok, [item | encoded]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp valid_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, MapSet.new()}, fn
      {key, _value}, {:ok, seen} when is_binary(key) ->
        cond do
          not String.valid?(key) -> {:halt, {:error, :invalid_json}}
          MapSet.member?(seen, key) -> {:halt, {:error, :duplicate_key}}
          true -> {:cont, {:ok, MapSet.put(seen, key)}}
        end

      _pair, _seen ->
        {:halt, {:error, :invalid_json}}
    end)
    |> case do
      {:ok, _seen} -> :ok
      error -> error
    end
  end

  defp join([]), do: []
  defp join([item]), do: item
  defp join([item | rest]), do: [item, ?,, join(rest)]
end
