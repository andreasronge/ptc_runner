defmodule PtcViewer.ReplError do
  @moduledoc false

  @catalog %{
    invalid_json: {400, "Request body must be valid JSON."},
    invalid_request: {400, "Request body does not match this operation."},
    delete_body_not_allowed: {400, "Close does not accept a request body."},
    forbidden_request: {403, "Viewer request security context is invalid."},
    repl_not_configured: {404, "REPL is not configured."},
    method_not_allowed: {405, "Method is not allowed for this REPL endpoint."},
    operation_active: {409, "Another operation is active."},
    session_terminal: {409, "The session is terminal; close or reset it."},
    session_closed: {409, "The session is closed; reset it to continue."},
    trace_changed: {409, "The trace source changed during capture."},
    session_changed: {412, "The session changed; refresh before retrying."},
    body_too_large: {413, "Request body is too large."},
    source_too_large: {413, "PTC-Lisp source is too large."},
    trace_source_too_large: {413, "The trace source is too large."},
    unsupported_media_type: {415, "Content-Type must be application/json."},
    unsupported_trace: {422, "The trace source is malformed or unsupported."},
    session_precondition_required: {428, "A current session precondition is required."},
    adapter_failure: {500, "The REPL backend failed."},
    repl_start_failed: {500, "The REPL session could not be started; retry."},
    persistence_failed: {500, "The session trace could not be persisted."},
    trace_unavailable: {503, "The trace source is unavailable."}
  }

  @spec response(atom()) :: {pos_integer(), map()}
  def response(code) do
    {status, message} = Map.fetch!(@catalog, code)
    {status, %{"error" => %{"code" => Atom.to_string(code), "message" => message}}}
  end
end
