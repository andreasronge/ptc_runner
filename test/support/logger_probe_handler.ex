defmodule PtcRunner.TestSupport.LoggerProbeHandler do
  @moduledoc false

  def log(event, %{test_pid: test_pid}) do
    send(test_pid, {:logger_probe, event})
  end
end
