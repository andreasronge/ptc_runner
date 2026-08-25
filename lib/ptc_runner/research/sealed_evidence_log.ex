defmodule PtcRunner.Research.SealedEvidenceLog do
  @moduledoc """
  Test/benchmark-only sealed evidence log with private ETS indexes.

  Production inspection routing is unchanged. This module is the #1646
  reference implementation: a small versioned header, length-framed
  deterministic JSON evidence, a terminal footer, one streaming admission
  pass, and owner-bound ETS metadata that never retains evidence payloads.
  """

  alias PtcRunner.Research.SealedEvidenceLog.Limits
  alias PtcRunner.Research.SealedEvidenceLog.Producer
  alias PtcRunner.Research.SealedEvidenceLog.Query
  alias PtcRunner.Research.SealedEvidenceLog.Snapshot

  @spec produce(Path.t(), Enumerable.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def produce(path, records, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, limits} <- Limits.merge(Keyword.get(opts, :limits, [])) do
      Producer.write(path, records, limits, opts)
    end
  end

  @spec admit([map()] | map(), keyword()) :: {:ok, Snapshot.t()} | {:error, atom()}
  def admit(artifacts, opts \\ [])

  def admit(artifact, opts) when is_map(artifact) and is_list(opts),
    do: admit([artifact], opts)

  def admit(artifacts, opts) when is_list(artifacts) and is_list(opts) do
    with {:ok, limits} <- Limits.merge(Keyword.get(opts, :limits, [])) do
      Snapshot.start(artifacts, limits, opts)
    end
  end

  @spec query(Snapshot.t(), atom(), map(), keyword()) ::
          {:ok, map(), Query.metrics()} | {:error, atom()}
  def query(snapshot, operation, arguments, opts \\ [])
      when is_atom(operation) and is_map(arguments) and is_list(opts) do
    Snapshot.query(snapshot, operation, arguments, opts)
  end

  @spec info(Snapshot.t()) :: {:ok, map()} | {:error, atom()}
  defdelegate info(snapshot), to: Snapshot

  @spec close(term()) :: :ok
  defdelegate close(snapshot), to: Snapshot
end
