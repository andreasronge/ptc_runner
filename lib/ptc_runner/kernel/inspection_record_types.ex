defmodule PtcRunner.Kernel.InspectionRecordTypes do
  @moduledoc """
  The closed private inspection record vocabulary.

  `PtcRunner.Kernel.InspectionSink` (retention) and
  `PtcRunner.Kernel.InspectionArtifact` (persistence and loading) must accept
  and reject the exact same record types; drift
  between two independent copies of that vocabulary is a defect, not a
  divergence either module is free to make on its own.
  """

  @record_types ~w(capability-input capability-output evaluation-source prelude-source mcp-request mcp-response execution-prints execution-error)

  @spec all() :: [binary()]
  @doc "Returns every record type admitted by the current schema."
  def all, do: @record_types
end
