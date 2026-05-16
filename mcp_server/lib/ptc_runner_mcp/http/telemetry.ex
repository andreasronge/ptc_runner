defmodule PtcRunnerMcp.Http.Telemetry do
  @moduledoc false

  def emit(event, measurements, metadata) do
    :telemetry.execute([:ptc_runner_mcp, :http | List.wrap(event)], measurements, metadata)
  end
end
