defmodule PtcRunner.Kernel.ViewerAdapter do
  @moduledoc "Read-only viewer adapter over the shared source-scoped TraceLog query layer."

  alias PtcRunner.Kernel.TraceLog

  @spec query(TraceLog.source(), atom(), map()) :: {:ok, map()} | {:error, atom()}
  def query(source, operation, arguments) when is_map(arguments) do
    with {:ok, trace_log} <- TraceLog.new(source: source),
         do: TraceLog.query(trace_log, operation, arguments)
  end
end
