defmodule PtcRunnerMcp.Sandbox do
  @moduledoc """
  Thin adapter that drives `PtcRunner.PtcToolProtocol.lisp_run/2` with
  the Phase 2/3 invariants (§ 11) and renders the result into the MCP
  envelope.

  Per `Plans/ptc-runner-mcp-server.md` § 11, every `tools/call` must:

    * use a fresh `memory: %{}` and `tool_cache: %{}`
    * never reuse a journal across requests
    * never reach into `Loop.State` or any text-mode/SubAgent
      internals
    * tag the call with `caller: :mcp` for telemetry

  Result rendering goes through `PtcToolProtocol.render_success_from_step/2`
  (§ 13.1) for success and `PtcToolProtocol.render_error/3` for the
  shared reasons; `:fail` carries a `result` preview per § 10.5.

  Phase 3 wires `context` (§ 9.3) and `signature` (§ 9.4):

    * `context` arrives as a coerced JSON map with binary keys and is
      forwarded to `Lisp.run/2` under the `:context` opt — the
      runtime then exposes those keys as `data/<key>` references.
    * `signature` arrives as an already-parsed signature term (the
      caller in `PtcRunnerMcp.Tools` calls
      `PtcToolProtocol.parse_signature/1` before reaching this module
      so a parse error never consumes a concurrency permit). The
      parsed signature is used solely to validate the program's
      return value via `PtcToolProtocol.validate_return/2`. On match,
      the structured return is encoded via
      `PtcToolProtocol.to_json_value/1` and surfaced as the
      top-level `validated` field of the R22 success payload.
  """

  alias PtcRunner.Lisp.Format
  alias PtcRunner.PtcToolProtocol
  alias PtcRunnerMcp.Envelope

  @typedoc "Already-parsed signature term, or `nil` when no signature was supplied."
  @type parsed_signature :: term() | nil

  @doc """
  Run a validated PTC-Lisp `program` and return an MCP envelope.

  All three arguments are pre-validated by the caller (see
  `PtcRunnerMcp.Tools.call/1`); this function does not re-check shape
  or size:

    * `program` — non-empty PTC-Lisp source string within
      `:max_program_bytes`.
    * `context` — a string-keyed map (`%{}` if absent). Encoded JSON
      size has already been checked against `:max_context_bytes`.
    * `parsed_signature` — either `nil` (no signature supplied) or a
      term returned by `PtcToolProtocol.parse_signature/1`.
  """
  @spec execute(String.t(), map(), parsed_signature()) :: Envelope.t()
  def execute(program, context \\ %{}, parsed_signature \\ nil)
      when is_binary(program) and is_map(context) do
    case PtcToolProtocol.lisp_run(program, lisp_run_opts(context)) do
      {:ok, %PtcRunner.Step{return: {:__ptc_fail__, fail_args}} = step} ->
        render_fail(step, fail_args)

      {:ok, %PtcRunner.Step{return: {:__ptc_return__, value}} = step} ->
        # `(return v)` in single-shot context is identical to a final
        # expression value: unwrap and render as success (with optional
        # signature validation).
        unwrapped = %{step | return: value}
        render_success_with_signature(unwrapped, parsed_signature)

      {:ok, %PtcRunner.Step{} = step} ->
        render_success_with_signature(step, parsed_signature)

      {:error, %PtcRunner.Step{fail: fail} = _step} when is_map(fail) ->
        render_runtime_error(fail)
    end
  end

  # ----------------------------------------------------------------
  # Lisp.run/2 opts (§ 11 invariants)
  # ----------------------------------------------------------------

  defp lisp_run_opts(context) do
    [
      caller: :mcp,
      memory: %{},
      tool_cache: %{},
      context: context,
      # § 9.3: a `data/<key>` reference for an absent key must produce
      # a runtime_error naming the binding, not silently return nil.
      strict_data: true
      # No :signature passed to Lisp.run/2 — MCP performs signature
      # validation post-hoc via `PtcToolProtocol.validate_return/2` so
      # parse errors are caught before permit acquisition (§ 9.4) and
      # validation errors render through the MCP `validation_error`
      # path with `to_json_value/1` for the `validated` field (§ 13).
    ]
  end

  # ----------------------------------------------------------------
  # Renderers
  # ----------------------------------------------------------------

  # No signature: emit R22 success without a `validated` field.
  defp render_success_with_signature(step, nil) do
    json = PtcToolProtocol.render_success_from_step(step, [])
    Envelope.success(Jason.decode!(json))
  end

  # Signature supplied: validate the typed return value, then either
  # surface the structured `validated` field on success or emit a
  # `validation_error` envelope on mismatch.
  defp render_success_with_signature(step, parsed_signature) do
    typed = atomize(step.return, parsed_signature)
    definition = %{parsed_signature: parsed_signature}

    case PtcToolProtocol.validate_return(definition, typed) do
      :ok ->
        case PtcToolProtocol.to_json_value(typed) do
          {:ok, encoded} ->
            json = PtcToolProtocol.render_success_from_step(step, validated: encoded)
            Envelope.success(Jason.decode!(json))

          {:error, reason} ->
            # The signature matched but the typed value contained a
            # term `to_json_value/1` cannot encode (e.g., a PID). Map
            # to validation_error with a path-pointing message — the
            # LLM authored a program whose typed shape is fine but
            # whose contents aren't representable on the wire.
            Envelope.render_error(:validation_error, "validated value: #{reason}")
        end

      {:error, errors} when is_list(errors) ->
        Envelope.render_error(:validation_error, format_validation_errors(errors))
    end
  end

  # Atomize the program's raw return value to the type-shape implied by
  # the signature so signature validation sees the right keys/types.
  # Falls back to identity when no signature was supplied.
  defp atomize(value, nil), do: value

  defp atomize(value, {:signature, _params, return_type}) do
    PtcToolProtocol.atomize_value(value, return_type)
  end

  defp atomize(value, _other), do: value

  defp format_validation_errors(errors) do
    Enum.map_join(errors, "; ", fn
      %{path: path, message: message} ->
        path_str = if path == [], do: "return", else: "return." <> Enum.join(path, ".")
        "#{path_str}: #{message}"

      other ->
        inspect(other)
    end)
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
