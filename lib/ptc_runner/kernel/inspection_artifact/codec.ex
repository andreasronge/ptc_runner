defmodule PtcRunner.Kernel.InspectionArtifact.Codec do
  @moduledoc false

  alias Jason.OrderedObject
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.InspectionArtifact.Format
  alias PtcRunner.Kernel.MCPProtocol
  alias PtcRunner.Lisp.RetainedSize

  @envelope [
    "schema_version",
    "run_id",
    "trace_id",
    "sequence",
    "timestamp",
    "record_type",
    "correlation",
    "payload"
  ]

  @spec encode_record(map()) :: {:ok, binary()} | {:error, :invalid_record}
  def encode_record(record) when is_map(record) do
    with {:ok, pairs} <- envelope_pairs(record),
         {:ok, encoded} <- DeterministicJSON.encode({:object, pairs}) do
      {:ok, encoded}
    else
      _error -> {:error, :invalid_record}
    end
  end

  def encode_record(_record), do: {:error, :invalid_record}

  @spec decode_record(binary()) :: {:ok, map()} | {:error, :malformed_source}
  def decode_record(payload) when is_binary(payload) do
    with true <- MCPProtocol.within_inspection_document_depth?(payload),
         {:ok, ordered} <- Jason.decode(payload, objects: :ordered_objects),
         {:ok, record} when is_map(record) <- ordered_value(ordered),
         {:ok, ^payload} <- encode_record(record) do
      {:ok, RetainedSize.detach_binaries(record)}
    else
      _invalid -> {:error, :malformed_source}
    end
  end

  def decode_record(_payload), do: {:error, :malformed_source}

  @spec schema_version() :: pos_integer()
  def schema_version, do: Format.schema_version()

  defp envelope_pairs(record) do
    Enum.reduce_while(@envelope, {:ok, []}, fn key, {:ok, pairs} ->
      case Map.fetch(record, key) do
        {:ok, value} -> {:cont, {:ok, [{key, value} | pairs]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      :error -> :error
    end
  end

  defp ordered_value(%OrderedObject{values: pairs}) do
    keys = Enum.map(pairs, &elem(&1, 0))

    if keys == Enum.uniq(keys) do
      Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
        case ordered_value(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(normalized, key, value)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp ordered_value(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, normalized} ->
      case ordered_value(value) do
        {:ok, value} -> {:cont, {:ok, [value | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp ordered_value(value), do: {:ok, value}
end
