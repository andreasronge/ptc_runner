defmodule PtcRunner.LiveStatus do
  @moduledoc """
  Opt-in live status reporting for one Kernel run (spike for issue #1444).

  When `PTC_VIEWER_URL` is set, `PtcRunner.Kernel.Runner` starts one
  `PtcRunner.LiveStatus.Reporter` per run. The reporter samples public run
  state (`RunState.usage/1`, parallel-budget occupancy, sandbox heap) and
  pushes JSON frames to the Viewer's live endpoint. Reporting is strictly
  best-effort: a dead or absent Viewer never affects the run.
  """

  alias PtcRunner.LiveStatus.Reporter

  @doc "Starts a reporter when `PTC_VIEWER_URL` is configured; returns nil otherwise."
  @spec maybe_start(struct(), struct()) :: pid() | nil
  def maybe_start(config, run_state) do
    case System.get_env("PTC_VIEWER_URL") do
      url when is_binary(url) and url != "" ->
        case Reporter.start(url, config, run_state) do
          {:ok, pid} -> pid
          _error -> nil
        end

      _absent ->
        nil
    end
  end

  @doc "Posts the final frame carrying the run outcome."
  @spec complete(pid() | nil, atom(), term()) :: :ok
  def complete(nil, _phase, _reason), do: :ok
  def complete(pid, phase, reason) when is_pid(pid), do: Reporter.complete(pid, phase, reason)

  @doc "Stops the reporter; safe on nil and on an already-dead pid."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok
  def stop(pid) when is_pid(pid), do: Reporter.stop(pid)
end
