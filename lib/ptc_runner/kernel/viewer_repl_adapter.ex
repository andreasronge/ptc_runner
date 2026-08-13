defmodule PtcRunner.Kernel.ViewerReplAdapter do
  @moduledoc """
  Local connected backend for the standalone Viewer's run-analysis REPL.

  The connected backend owns Core session handles and an idempotent bounded
  operation ledger. Browser-facing code receives only opaque backend/session
  references and safe projections; paths and Core capabilities never cross the
  adapter boundary.
  """

  alias PtcRunner.Kernel.ViewerReplBackend

  @profile_id "run-analysis-v1"

  # The standalone Viewer validates this callback contract dynamically. The
  # root library deliberately does not depend on the nested Viewer project.
  def connect(%{trace_dir: trace_dir, profile_id: @profile_id})
      when is_binary(trace_dir) do
    with expanded <- Path.expand(trace_dir),
         {:ok, %File.Stat{type: :directory}} <- File.stat(expanded),
         {:ok, backend} <- ViewerReplBackend.start_link(expanded, self()) do
      {:ok, backend,
       %{
         "enabled" => true,
         "profile_id" => @profile_id,
         "namespaces" => ["analysis", "cap"],
         "source_limit_bytes" => 65_536
       }}
    else
      _ -> {:error, :invalid_repl_connection}
    end
  end

  def connect(_config), do: {:error, :invalid_repl_connection}

  def prepare_operation(backend, session, kind, operation_id),
    do: ViewerReplBackend.prepare(backend, session, kind, operation_id)

  def start(backend, operation_id, public_session_id),
    do: ViewerReplBackend.start_session(backend, operation_id, public_session_id)

  def reconcile_start(backend, operation_id),
    do: ViewerReplBackend.reconcile(backend, :start, operation_id)

  def evaluate(backend, session, operation_id, source),
    do: ViewerReplBackend.evaluate(backend, session, operation_id, source)

  def reconcile_evaluate(backend, session, operation_id),
    do: ViewerReplBackend.reconcile(backend, {:evaluation, session}, operation_id)

  def template(backend, session, kind, run_id),
    do: ViewerReplBackend.template(backend, session, kind, run_id)

  def info(backend, session), do: ViewerReplBackend.info(backend, session)

  def close(backend, session, operation_id),
    do: ViewerReplBackend.close_session(backend, session, operation_id)

  def reconcile_close(backend, session, operation_id),
    do: ViewerReplBackend.reconcile(backend, {:close, session}, operation_id)

  def acknowledge_operation(backend, kind, operation_id),
    do: ViewerReplBackend.acknowledge(backend, kind, operation_id)

  def abort(backend, session, reason), do: ViewerReplBackend.abort(backend, session, reason)
end
