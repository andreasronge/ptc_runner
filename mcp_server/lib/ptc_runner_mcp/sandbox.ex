defmodule PtcRunnerMcp.Sandbox do
  @moduledoc """
  Thin adapter that drives `PtcRunner.PtcToolProtocol.lisp_run/2` with
  the Phase 2/3 invariants (§ 11) and **builds the v1 structured
  payload** for the MCP request handler.

  Per `Plans/ptc-runner-mcp-aggregator.md` §11.3, the MCP request
  handler — not this module — owns the `success/error_envelope`
  wrap. This separation gives Phase 1a a clean place to insert
  `upstream_calls` decoration between "build payload" (here) and
  "wrap envelope" (in `PtcRunnerMcp.Tools`):

      {kind, payload} = Sandbox.execute(program, ctx, sig, opts)
      # Phase 1a: payload = decorate_with_upstream_calls(payload, drained)
      case kind do
        :ok    -> Envelope.success(payload)
        :error -> Envelope.error_envelope(payload)
      end

  Per `Plans/ptc-runner-mcp-server.md` § 11, every `tools/call` must:

    * use a fresh `memory: %{}` and `tool_cache: %{}`
    * never reuse a journal across requests
    * never reach into `Loop.State` or any text-mode/SubAgent
      internals
    * tag the call with `caller: :mcp` for telemetry

  Payload construction:

    * Success goes through
      `PtcToolProtocol.render_success_from_step/2` (§ 13.1).
    * Shared-reason errors go through
      `PtcRunnerMcp.Envelope.render_error_payload/3`, which
      delegates to `PtcToolProtocol.render_error/3` for the seven
      shared reasons and constructs MCP-only payloads (`:busy`,
      `:unknown_tool`, `:shutting_down`) locally.
    * `:fail` carries a `result` preview per § 10.5.

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
  alias PtcRunnerMcp.{Envelope, Limits}

  @typedoc """
  Outcome of a single `tools/call` PTC-Lisp execution.

  The first element discriminates success vs. error and tells the
  request handler which envelope wrapper to use
  (`Envelope.success/1` for `:ok`, `Envelope.error_envelope/1` for
  `:error`). The second element is the **unwrapped** v1 R22/R23
  structured payload (string-keyed map, JSON-encodable).
  """
  @type result :: {:ok | :error, map()}

  # Word size of the running BEAM in bytes. 8 on 64-bit (the only
  # supported target — see CLAUDE.md "Tech Stack: OTP 28"). Cached
  # at compile time because the value cannot change for a given
  # release. Used to convert
  # `Limits.program_memory_limit_bytes/0` (bytes, the user-facing
  # unit per `Plans/ptc-runner-mcp-aggregator.md` §9) into the BEAM
  # words `Lisp.run/2`'s `:max_heap` opt expects (see
  # `lib/ptc_runner/sandbox.ex` "Max Heap (~10 MB = 1,250,000 words)").
  @bytes_per_word :erlang.system_info(:wordsize)

  # BEAM's minimum accepted `max_heap_size` (in words) — empirically
  # 233 on OTP 28; values below are rejected by `spawn_opt` with
  # `ArgumentError: invalid spawn option`. The forwarder must clamp
  # to this floor so a sub-word byte count from `Limits` (e.g.,
  # `program_memory_limit_bytes: 4` → 0 words on 64-bit) does not
  # either silently disable the cap (the BEAM's `0` semantics) or
  # crash the spawn outright (sizes 1..232). Operators who configure
  # a tiny byte count get the tightest cap the runtime will accept,
  # which trips on virtually any allocation — preserving "tight cap
  # → tight enforcement" semantics.
  @min_max_heap_words 233

  @typedoc "Already-parsed signature term, or `nil` when no signature was supplied."
  @type parsed_signature :: term() | nil

  @doc """
  Run a validated PTC-Lisp `program` and return the **unwrapped**
  result for the MCP request handler to wrap.

  Returns `{:ok, structured_payload}` for a successful program (with
  optional signature `validated` field) and `{:error, structured_payload}`
  for any failure mode (`:fail`, `:timeout`, `:memory_limit`,
  `:parse_error`, `:runtime_error`, `:validation_error`). The handler
  is expected to wrap with `PtcRunnerMcp.Envelope.success/1` or
  `PtcRunnerMcp.Envelope.error_envelope/1` per the kind discriminator
  — see this module's `@moduledoc` for the §11.3 decoration-seam
  rationale.

  All three positional arguments are pre-validated by the caller
  (see `PtcRunnerMcp.Tools.call/1`); this function does not re-check
  shape or size:

    * `program` — non-empty PTC-Lisp source string within
      `:max_program_bytes`.
    * `context` — a string-keyed map (`%{}` if absent). Encoded JSON
      size has already been checked against `:max_context_bytes`.
    * `parsed_signature` — either `nil` (no signature supplied) or a
      term returned by `PtcToolProtocol.parse_signature/1`.
  """
  @spec execute(String.t(), map(), parsed_signature(), keyword()) :: result()
  def execute(program, context \\ %{}, parsed_signature \\ nil, opts \\ [])
      when is_binary(program) and is_map(context) and is_list(opts) do
    case PtcToolProtocol.lisp_run(program, lisp_run_opts(context, opts)) do
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

  defp lisp_run_opts(context, opts) do
    # Phase 0 (`Plans/ptc-runner-mcp-aggregator.md` §11.2 / §11.5):
    #   * `:tools` is the new aggregator seam. An empty list (the only
    #     Phase 0 value) leaves Lisp.run/2's behavior unchanged versus
    #     v1, where no tools were registered. Phase 1a will populate
    #     it with the `mcp-call` virtual-tool registry.
    #   * `:profile` is a pure-instrumentation tag attached to the
    #     `[:ptc_runner, :lisp, :execute, *]` span. v1 always passes
    #     `:mcp_no_tools`; Phase 1a flips it to `:mcp_aggregator` from
    #     an aggregator-mode handler.
    tools = Keyword.get(opts, :tools, [])

    # Phase 0 (`Plans/ptc-runner-mcp-aggregator.md` §11.6 / §9):
    # forward the configured program-level limits into Lisp.run/2.
    # Without this, `--program-timeout-ms` and
    # `--program-memory-limit-bytes` (and their env-var equivalents)
    # are persisted in `Limits` but never consumed — the PTC-Lisp
    # sandbox would silently use its own hard-coded defaults.
    # `:max_heap` is in BEAM words (see lib/ptc_runner/sandbox.ex);
    # the Limits getter is in bytes per the user-facing flag/env
    # name, so we convert here.
    #
    # `max(@min_max_heap_words, ...)`: see the module-level constant
    # for the rationale — a sub-word byte count rounds to 0 words
    # ("no limit" in the BEAM), and the BEAM's `spawn_opt` rejects
    # any positive value below 233. Clamping to the runtime floor
    # preserves "tiny byte count → tight cap" semantics without
    # crashing the spawn.
    timeout_ms = Limits.program_timeout_ms()

    max_heap_words =
      max(
        @min_max_heap_words,
        div(Limits.program_memory_limit_bytes(), @bytes_per_word)
      )

    base = [
      caller: :mcp,
      profile: :mcp_no_tools,
      memory: %{},
      tools: tools,
      tool_cache: %{},
      context: context,
      timeout: timeout_ms,
      max_heap: max_heap_words,
      # § 9.3: a `data/<key>` reference for an absent key must produce
      # a runtime_error naming the binding, not silently return nil.
      strict_data: true
      # No :signature passed to Lisp.run/2 — MCP performs signature
      # validation post-hoc via `PtcToolProtocol.validate_return/2` so
      # parse errors are caught before permit acquisition (§ 9.4) and
      # validation errors render through the MCP `validation_error`
      # path with `to_json_value/1` for the `validated` field (§ 13).
    ]

    # Phase 4: when called from a per-call worker (Stdio), `link: true`
    # tells the inner `PtcRunner.Sandbox` to spawn its child linked
    # to this process. A `notifications/cancelled` that kills the
    # worker then propagates the link signal to the sandbox child,
    # so a 5-second runaway program dies promptly instead of running
    # orphaned until its own heap/timeout limit fires (§ 6.4).
    if Keyword.get(opts, :link, false) do
      Keyword.put(base, :link, true)
    else
      base
    end
  end

  # ----------------------------------------------------------------
  # Renderers — produce {:ok | :error, payload} tuples
  # ----------------------------------------------------------------
  #
  # Phase 0 (`Plans/ptc-runner-mcp-aggregator.md` §11.3) keeps the
  # structured-payload construction inside `Sandbox.execute/4` and
  # leaves the envelope wrap to the request handler. In Phase 1a the
  # handler will insert `upstream_calls` decoration between the two
  # — returning unwrapped `{kind, payload}` tuples gives the handler
  # a clean slot to augment before wrapping. `PtcRunnerMcp.Envelope`
  # and `PtcRunner.PtcToolProtocol` MUST NOT gain new options for
  # `upstream_calls` in Phase 0 (§11.3 last sentence); the
  # decoration lives in the request handler only.

  # No signature: emit R22 success without a `validated` field.
  defp render_success_with_signature(step, nil) do
    {:ok, build_v1_success_payload(step, [])}
  end

  # Signature supplied: validate the typed return value, then either
  # surface the structured `validated` field on success or emit a
  # `validation_error` payload on mismatch.
  defp render_success_with_signature(step, parsed_signature) do
    typed = atomize(step.return, parsed_signature)
    definition = %{parsed_signature: parsed_signature}

    case PtcToolProtocol.validate_return(definition, typed) do
      :ok ->
        case PtcToolProtocol.to_json_value(typed) do
          {:ok, encoded} ->
            {:ok, build_v1_success_payload(step, validated: encoded)}

          {:error, reason} ->
            # The signature matched but the typed value contained a
            # term `to_json_value/1` cannot encode (e.g., a PID). Map
            # to validation_error with a path-pointing message — the
            # LLM authored a program whose typed shape is fine but
            # whose contents aren't representable on the wire.
            error_payload(:validation_error, "validated value: #{reason}")
        end

      {:error, errors} when is_list(errors) ->
        error_payload(:validation_error, format_validation_errors(errors))
    end
  end

  # Build the v1 R22 success payload (string-keyed map) — this is the
  # "build" step of the §11.3 two-step seam. Phase 1a's request
  # handler may augment this map with `upstream_calls` before wrapping.
  defp build_v1_success_payload(step, render_opts) do
    step
    |> PtcToolProtocol.render_success_from_step(render_opts)
    |> Jason.decode!()
  end

  # Build a v1 R23 error payload (string-keyed map) for the shared and
  # MCP-only reasons.  Mirrors `build_v1_success_payload/2` for the
  # error path; the request handler wraps with `error_envelope/1`.
  defp error_payload(reason, message, opts \\ []) do
    {:error, Envelope.render_error_payload(reason, message, opts)}
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

    error_payload(:fail, message, result: preview, feedback: message)
  end

  defp render_runtime_error(%{reason: reason, message: message}) do
    error_payload(classify(reason), message)
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
