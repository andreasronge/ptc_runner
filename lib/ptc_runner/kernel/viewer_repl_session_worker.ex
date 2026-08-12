defmodule PtcRunner.Kernel.ViewerReplSessionWorker do
  @moduledoc false

  alias PtcRunner.Kernel.AnalysisSession
  alias PtcRunner.Kernel.AnalysisSessionBuilder
  alias PtcRunner.Kernel.PublicRunAnalysisProfile

  def run(backend, trace_dir, public_session_id) when is_pid(backend) do
    Process.link(backend)

    case AnalysisSessionBuilder.start(
           PublicRunAnalysisProfile.id(),
           %{"traces" => trace_dir},
           {:directory, trace_dir}
         ) do
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
        result = AnalysisSession.evaluate(session, source)
        send(backend, {:viewer_repl_operation, self(), key, result})
        loop(backend, session, session_ref, public_session_id)

      {:operation, key, :close} ->
        result = session |> AnalysisSession.close() |> rewrite_info(public_session_id)
        send(backend, {:viewer_repl_operation, self(), key, result})
        loop(backend, session, session_ref, public_session_id)

      {:control, control_ref, :info} ->
        result = session |> AnalysisSession.info() |> rewrite_info(public_session_id)
        send(backend, {:viewer_repl_control, self(), control_ref, result})
        loop(backend, session, session_ref, public_session_id)

      {:control, control_ref, {:abort, reason}} ->
        result = session |> AnalysisSession.abort(reason) |> rewrite_info(public_session_id)
        send(backend, {:viewer_repl_control, self(), control_ref, result})
        AnalysisSession.stop(session)

      {:stop, reason} ->
        _ = AnalysisSession.abort(session, reason)
        AnalysisSession.stop(session)

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
