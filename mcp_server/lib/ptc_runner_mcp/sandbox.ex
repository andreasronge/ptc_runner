defmodule PtcRunnerMcp.Sandbox do
  @moduledoc """
  Thin adapter that drives `PtcRunner.PtcToolProtocol.lisp_run/2` with
  the Phase 2 invariants (§ 11) and renders the result into the MCP
  envelope.

  Per `Plans/ptc-runner-mcp-server.md` § 11, every `tools/call` must:

    * use a fresh `memory: %{}` and `tool_cache: %{}`
    * never reuse a journal across requests
    * never reach into `Loop.State` or any text-mode/SubAgent
      internals
    * tag the call with `caller: :mcp` for telemetry

  Result rendering goes through `PtcToolProtocol.render_success_from_step/2`
  (§ 13.1) for success and `PtcToolProtocol.render_error/3` for the
  seven shared reasons; `:fail` carries a `result` preview per § 10.5.

  Phase 2 does NOT wire `context` or `signature` (§ 9.3, § 9.4) —
  those are explicit Phase 3 work and are intentionally not passed to
  `lisp_run/2`.
  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.PtcToolProtocol
  alias PtcRunnerMcp.Envelope

  @doc """
  Run a validated PTC-Lisp `program` and return an MCP envelope.

  `program` must already have been validated by the caller (see
  `PtcRunnerMcp.Tools.call/1`); this function does not re-check size
  or shape.
  """
  @spec execute(String.t()) :: Envelope.t()
  def execute(program) when is_binary(program) do
    case PtcToolProtocol.lisp_run(program, lisp_run_opts()) do
      {:ok, %PtcRunner.Step{return: {:__ptc_fail__, fail_args}} = step} ->
        render_fail(step, fail_args)

      {:ok, %PtcRunner.Step{return: {:__ptc_return__, value}} = step} ->
        # `(return v)` in single-shot context is identical to a final
        # expression value: unwrap and render as success.
        unwrapped = %{step | return: value}
        render_success(unwrapped)

      {:ok, %PtcRunner.Step{} = step} ->
        render_success(step)

      {:error, %PtcRunner.Step{fail: fail} = _step} when is_map(fail) ->
        render_runtime_error(fail)
    end
  end

  # ----------------------------------------------------------------
  # Lisp.run/2 opts (§ 11 invariants)
  # ----------------------------------------------------------------

  defp lisp_run_opts do
    [
      caller: :mcp,
      memory: %{},
      tool_cache: %{}
      # No :context (Phase 3); no :signature (Phase 3); no :journal
      # (a fresh per-call journal is fine — Lisp.run/2 owns it).
    ]
  end

  # ----------------------------------------------------------------
  # Renderers
  # ----------------------------------------------------------------

  defp render_success(step) do
    json = PtcToolProtocol.render_success_from_step(step, [])
    Envelope.success(Jason.decode!(json))
  end

  defp render_fail(_step, fail_args) do
    {preview, _truncated} = Format.to_clojure(fail_args, limit: 50)
    message = inspect(fail_args)

    Envelope.render_error(:fail, message, result: preview, feedback: message)
  end

  defp render_runtime_error(%{reason: reason, message: message}) do
    Envelope.render_error(classify(reason), message)
  end

  # Map `Step.fail.reason` (closed atom set per `lib/ptc_runner/step.ex`
  # docstring) to the shared error reason enum surfaced by MCP.
  # Mirrors `PtcRunner.SubAgent.Loop.PtcToolCall.classify_lisp_error/1`,
  # adapted for the MCP closed-set without the in-process catch-all.
  defp classify(:parse_error), do: :parse_error
  defp classify(:timeout), do: :timeout
  defp classify(:memory_exceeded), do: :memory_limit

  defp classify(reason) when is_atom(reason) do
    reason_str = Atom.to_string(reason)

    cond do
      String.contains?(reason_str, "parse") -> :parse_error
      String.contains?(reason_str, "timeout") -> :timeout
      String.contains?(reason_str, "memory") -> :memory_limit
      true -> :runtime_error
    end
  end
end
