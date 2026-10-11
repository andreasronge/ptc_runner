defmodule PtcRunner.Kernel.TraceLog.Source do
  @moduledoc false

  # Shared canonical encoding, validation and file identity checks.

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.QueryCursor
  alias PtcRunner.Kernel.TraceEventValidation

  @spec same_file(File.Stat.t(), File.Stat.t()) :: :ok | {:error, :source_changed}
  def same_file(
        %File.Stat{major_device: device, minor_device: minor, inode: inode},
        %File.Stat{major_device: device, minor_device: minor, inode: inode}
      ),
      do: :ok

  def same_file(_expected, _opened), do: {:error, :source_changed}

  @spec decode_jsonl(binary()) :: {:ok, [map()]} | {:error, :malformed_source}
  def decode_jsonl(source) do
    source
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, events} ->
      with {:ok, decoded} <- Jason.decode(line, objects: :ordered_objects),
           {:ok, event} <- ordered_map(decoded),
           true <- is_map(event) do
        {:cont, {:ok, [event | events]}}
      else
        _ -> {:halt, {:error, :malformed_source}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_map(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, map} ->
        case ordered_map(value) do
          {:ok, normalized} -> {:cont, {:ok, Map.put(map, key, normalized)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :duplicate_json_key}
    end
  end

  defp ordered_map(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case ordered_map(value) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp ordered_map(value), do: {:ok, value}

  @spec validate_loaded([map()], pos_integer()) :: {:ok, [map()], binary()} | {:error, atom()}
  def validate_loaded(events, max_bytes) when is_list(events) do
    encoded_bytes = Enum.reduce(events, 0, &(&2 + byte_size(Jason.encode!(&1))))

    with true <- encoded_bytes <= max_bytes,
         :ok <- TraceEventValidation.validate(events) do
      source_id = digest(events)

      {:ok, events, source_id}
    else
      false -> {:error, :source_limit_exceeded}
      {:error, _reason} = error -> error
    end
  rescue
    Jason.EncodeError -> {:error, :malformed_source}
  end

  @spec digest(term()) :: binary()
  def digest(value), do: QueryCursor.query_digest(value)
  @spec normalize(term()) :: term()
  def normalize(value) when is_struct(value, DateTime), do: DateTime.to_iso8601(value)
  def normalize(nil), do: nil
  def normalize(value) when is_boolean(value), do: value
  def normalize(value) when is_atom(value), do: Atom.to_string(value)
  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  def normalize(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)

  def normalize(value), do: value

  @spec private_path?(binary()) :: boolean()
  def private_path?(path), do: String.ends_with?(path, ".private.jsonl")
  @spec inspection_path?(binary()) :: boolean()
  def inspection_path?(path), do: String.ends_with?(path, ".ptcins")
  @spec reserved_path?(binary()) :: boolean()
  def reserved_path?(path), do: private_path?(path) or inspection_path?(path)
end
