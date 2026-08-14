defmodule PtcRunner.Kernel.InspectionRecordTypes do
  @moduledoc """
  The closed private inspection record vocabulary.

  `PtcRunner.Kernel.InspectionSink` (retention) and
  `PtcRunner.Kernel.InspectionArtifact` (persistence and loading) must accept
  and reject the exact same record types; drift
  between two independent copies of that vocabulary is a defect, not a
  divergence either module is free to make on its own.
  """

  @record_types ~w(capability-input capability-output evaluation-source evaluation-analysis prelude-source mcp-request mcp-response execution-prints execution-error run-result)

  @spec all() :: [binary()]
  @doc "Returns every record type admitted by the current schema."
  def all, do: @record_types

  @doc false
  @spec valid_boundary_producer_details?(map()) :: boolean()
  def valid_boundary_producer_details?(details) when is_map(details) do
    case Map.fetch(details, "boundary_producer") do
      :error -> true
      {:ok, producer} -> valid_boundary_producer?(producer)
    end
  end

  defp valid_boundary_producer?(producer) when is_map(producer) do
    Enum.sort(Map.keys(producer)) == ~w(complete? evaluation_ids) and
      is_boolean(producer["complete?"]) and
      is_list(producer["evaluation_ids"]) and
      Enum.all?(producer["evaluation_ids"], &valid_id?/1) and
      producer["evaluation_ids"] == Enum.uniq(producer["evaluation_ids"])
  end

  defp valid_boundary_producer?(_producer), do: false

  defp valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and String.valid?(id)
end
