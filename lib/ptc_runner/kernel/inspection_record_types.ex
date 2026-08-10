defmodule PtcRunner.Kernel.InspectionRecordTypes do
  @moduledoc """
  The closed private inspection record vocabulary, by schema version.

  `PtcRunner.Kernel.InspectionSink` (retention) and
  `PtcRunner.Kernel.InspectionArtifact` (persistence and loading) must accept
  and reject the exact same record types for a given schema version; drift
  between two independent copies of that vocabulary is a defect, not a
  divergence either module is free to make on its own.
  """

  @v1 ~w(capability-input capability-output evaluation-source prelude-source)
  @v2 @v1 ++ ~w(mcp-request mcp-response)
  @v3 @v2 ++ ~w(execution-prints execution-error)

  @spec for_schema_version(1 | 2 | 3) :: [binary()]
  @doc "Returns the exact record types admitted at the given schema version."
  def for_schema_version(1), do: @v1
  def for_schema_version(2), do: @v2
  def for_schema_version(3), do: @v3
end
