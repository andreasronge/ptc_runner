defmodule PtcRunner.Research.SealedEvidenceLog.Codec do
  @moduledoc """
  Deterministic JSON evidence encoding for the sealed-log prototype.

  Envelope objects use the declared inspection field order. Nested maps sort
  keys by UTF-8 bytes through `PtcRunner.Kernel.DeterministicJSON`.
  """

  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.Research.SealedEvidenceLog.Format

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
    case Jason.decode(payload) do
      {:ok, record} when is_map(record) -> {:ok, RetainedSize.detach_binaries(record)}
      _error -> {:error, :malformed_source}
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
end
