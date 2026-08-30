defmodule PtcRunner.LiveStatus do
  @moduledoc """
  Opt-in live status reporting for one Kernel run.

  `PtcRunner.Kernel.Runner` starts one internal reporter per run when either an
  owning host injects a per-run target or `PTC_VIEWER_URL` names an external
  Viewer. It samples public run state (`RunState.usage/1`, parallel-budget
  occupancy, sandbox heap) and sends self-contained frames to that target.
  `PTC_VIEWER_TOKEN`, when present, authenticates the HTTP form. Reporting is
  strictly best-effort: a dead, absent, or rejecting Viewer never affects the
  run.
  """

  alias PtcRunner.LiveStatus.Reporter
  alias PtcRunner.LiveStatus.Target

  @target_key {__MODULE__, :target}

  @doc "Starts the configured per-run or HTTP reporter; returns nil otherwise."
  @spec maybe_start(struct(), struct()) :: pid() | nil
  def maybe_start(config, run_state) do
    case Process.get(@target_key) do
      %Target{} = target ->
        case Reporter.start(target, config, run_state) do
          {:ok, pid} -> pid
          _error -> nil
        end

      _absent ->
        maybe_start_http(config, run_state)
    end
  end

  @doc false
  @spec with_target(Target.t() | nil, (-> result)) :: result when result: term()
  def with_target(nil, fun) when is_function(fun, 0), do: fun.()

  def with_target(%Target{} = target, fun) when is_function(fun, 0) do
    previous = Process.get(@target_key, :absent)
    Process.put(@target_key, target)

    try do
      fun.()
    after
      restore_target(previous)
    end
  end

  defp maybe_start_http(config, run_state) do
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

  defp restore_target(:absent), do: Process.delete(@target_key)
  defp restore_target(previous), do: Process.put(@target_key, previous)

  @doc "Posts the final frame carrying the run outcome."
  @spec complete(pid() | nil, atom(), term(), binary() | nil, map() | nil) :: :ok
  def complete(reporter, phase, reason, limit, last_evaluation_error \\ nil)

  def complete(nil, _phase, _reason, _limit, _last_evaluation_error), do: :ok

  def complete(pid, phase, reason, limit, last_evaluation_error) when is_pid(pid),
    do: Reporter.complete(pid, phase, reason, limit, last_evaluation_error)

  @doc "Stops the reporter; safe on nil and on an already-dead pid."
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok
  def stop(pid) when is_pid(pid), do: Reporter.stop(pid)
end
