defmodule PtcRunner.Kernel.DeterministicJSON do
  @moduledoc """
  Internal deterministic encoder for frozen Kernel metadata and hashes.

  Ordinary maps require binary UTF-8 keys or valid public symbol-reference
  wrappers and are recursively sorted by their normalized key bytes.
  `{:object, pairs}` accepts the same key types, preserves an explicit key
  order for versioned projections, and rejects duplicate normalized keys
  before a map could erase them. Symbol-reference values are likewise encoded
  as their display strings. Arrays retain their input order and output contains
  no insignificant whitespace.
  """

  alias PtcRunner.Lisp.Format.SymbolRef

  @type json_key :: binary() | %SymbolRef{name: binary()}
  @type ordered_object :: {:object, [{json_key(), term()}]}

  @spec encode(term() | ordered_object()) ::
          {:ok, binary()} | {:error, :invalid_json | :duplicate_key}
  def encode(value) do
    case encode_value(value) do
      {:ok, encoded} -> {:ok, IO.iodata_to_binary(encoded)}
      error -> error
    end
  end

  defp encode_value({:object, pairs}) when is_list(pairs) do
    if proper_list?(pairs),
      do: with({:ok, normalized} <- normalize_pairs(pairs), do: encode_pairs(normalized)),
      else: {:error, :invalid_json}
  end

  defp encode_value(value) when is_map(value) and not is_struct(value) do
    with {:ok, normalized} <- value |> Map.to_list() |> normalize_pairs() do
      normalized
      |> Enum.sort_by(&elem(&1, 0))
      |> encode_pairs()
    end
  end

  defp encode_value(value) when is_list(value) do
    if proper_list?(value) do
      with {:ok, items} <- encode_many(value) do
        {:ok, [?[, join(items), ?]]}
      end
    else
      {:error, :invalid_json}
    end
  end

  defp encode_value(%SymbolRef{} = value) do
    if SymbolRef.valid?(value),
      do: encode_value(Kernel.to_string(value)),
      else: {:error, :invalid_json}
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

  defp normalize_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, {MapSet.new(), []}}, fn
      {key, value}, {:ok, {seen, normalized}} ->
        with {:ok, key} <- normalize_key(key),
             false <- MapSet.member?(seen, key) do
          {:cont, {:ok, {MapSet.put(seen, key), [{key, value} | normalized]}}}
        else
          true -> {:halt, {:error, :duplicate_key}}
          {:error, :invalid_json} = error -> {:halt, error}
        end

      _pair, _state ->
        {:halt, {:error, :invalid_json}}
    end)
    |> case do
      {:ok, {_seen, normalized}} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_key(%SymbolRef{} = key) do
    if SymbolRef.valid?(key),
      do: normalize_key(Kernel.to_string(key)),
      else: {:error, :invalid_json}
  end

  defp normalize_key(key) when is_binary(key),
    do: if(String.valid?(key), do: {:ok, key}, else: {:error, :invalid_json})

  defp normalize_key(_key), do: {:error, :invalid_json}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  defp join([]), do: []
  defp join([item]), do: item
  defp join([item | rest]), do: [item, ?,, join(rest)]
end
