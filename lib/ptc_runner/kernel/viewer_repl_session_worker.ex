defmodule PtcRunner.Kernel.ViewerReplSessionWorker do
  @moduledoc false

  alias PtcRunner.Kernel.LogAnalysisSession
  alias PtcRunner.Kernel.LogAnalysisSessionBuilder

  def run(backend, trace_dir, public_session_id) when is_pid(backend) do
    Process.link(backend)

    case LogAnalysisSessionBuilder.start({:directory, trace_dir}, {:directory, trace_dir}) do
      {:ok, session, info} ->
        session_ref = Process.monitor(session.pid)
        send(backend, {:viewer_repl_started, self(), {:ok, public_info(info, public_session_id)}})
        loop(backend, session, session_ref, public_session_id)

      {:error, reason} ->
        send(backend, {:viewer_repl_started, self(), {:error, reason}})
    end
  end

  defp loop(backend, session, session_ref, public_session_id) do
    receive do
      {:operation, key, {:evaluate, source}} ->
        result = LogAnalysisSession.evaluate(session, source)
        send(backend, {:viewer_repl_operation, self(), key, result})
        loop(backend, session, session_ref, public_session_id)

      {:operation, key, :close} ->
        result = session |> LogAnalysisSession.close() |> rewrite_info(public_session_id)
        send(backend, {:viewer_repl_operation, self(), key, result})
        loop(backend, session, session_ref, public_session_id)

      {:control, control_ref, :info} ->
        result = session |> LogAnalysisSession.info() |> rewrite_info(public_session_id)
        send(backend, {:viewer_repl_control, self(), control_ref, result})
        loop(backend, session, session_ref, public_session_id)

      {:control, control_ref, {:abort, reason}} ->
        result = session |> LogAnalysisSession.abort(reason) |> rewrite_info(public_session_id)
        send(backend, {:viewer_repl_control, self(), control_ref, result})
        LogAnalysisSession.stop(session)

      {:stop, reason} ->
        _ = LogAnalysisSession.abort(session, reason)
        LogAnalysisSession.stop(session)

      {:DOWN, ^session_ref, :process, _pid, reason} ->
        exit({:core_session_down, reason})

      _message ->
        loop(backend, session, session_ref, public_session_id)
    end
  end

  defp rewrite_info({:ok, info}, public_session_id),
    do: {:ok, public_info(info, public_session_id)}

  defp rewrite_info(result, _public_session_id), do: result

  defp public_info(info, public_session_id) do
    info
    |> Map.take([
      :lifecycle,
      :profile_id,
      :profile_digest,
      :namespaces,
      :snapshot,
      :evaluation_count,
      :terminal_reason,
      :usage,
      :trace
    ])
    |> Map.put(:session_id, public_session_id)
  end
end
