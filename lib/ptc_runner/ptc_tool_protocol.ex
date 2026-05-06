defmodule PtcRunner.PtcToolProtocol do
  @moduledoc """
  Wire-format source of truth for the `ptc_lisp_execute` tool surface.

  Owns the canonical tool description (per capability profile) and the
  shared response-payload renderers (`render_success/2`,
  `render_error/3`) used across:

    * **In-process v1 PTC `:tool_call`** — `output: :ptc_lisp,
      ptc_transport: :tool_call` agents that expose `ptc_lisp_execute`
      as the only provider-native tool. Profile:
      `:in_process_with_app_tools`.
    * **In-process text-mode (combined mode)** — `output: :text,
      ptc_transport: :tool_call` agents that expose `ptc_lisp_execute`
      alongside `:both`-tagged app tools. Profile:
      `:in_process_text_mode`.
    * **MCP server** — standalone JSON-RPC server that advertises
      `ptc_lisp_execute` with no app tools available inside programs.
      Profile: `:mcp_no_tools`.

  The three feature plans share four conventions; this module is where
  all four are pinned (see "Coupling Points" in
  `Plans/text-mode-ptc-compute-tool.md`):

    1. **Profile-string convention.** Each profile is one canonical
       string constant. `tool_description/1` returns it directly — no
       runtime concatenation of base + capability note. If the
       representation ever changes (e.g., to a structured map), all
       three profiles change together.
    2. **`error_reason()` is a closed union.** Adding a new reason
       requires updating the `@type` and `render_error/3`'s reason
       handling in lockstep. `render_error/3` MUST handle every member
       without crashing.
    3. **Renderer signatures are keyword-driven.** `render_success/2`
       and `render_error/3` take a keyword list for any non-essential
       parameter so future additions are non-breaking. Unknown opts are
       silently ignored, not rejected.
    4. **`tool_description/1` carries capability statements only.**
       Cache-reuse guidance, prompt cards, and other workflow guidance
       live in plan-specific surfaces (system prompt, `cache_hint`, MCP
       server documentation), not here.

  See `Plans/text-mode-ptc-compute-tool.md` § "Prerequisite: Shared
  Protocol Module" and `Plans/ptc-runner-mcp-server.md` § "Tool
  Description Capability Profiles" for the spec.
  """

  alias PtcRunner.Lisp
  alias PtcRunner.SubAgent.Loop.JsonHandler

  # ----------------------------------------------------------------
  # Capability-profile description constants
  # ----------------------------------------------------------------
  #
  # Per Addendum #10 (text-mode plan): the `:in_process_with_app_tools`
  # string is locked to the existing v1 wording. Per Addendum #11: each
  # profile is one canonical constant; `tool_description/1` returns it
  # directly with no runtime concatenation. New profiles must extend
  # this list and add a substring-pinning test.

  @in_process_with_app_tools_description "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation and tool orchestration. Call app tools as `(tool/name ...)` from inside the program — do not attempt to call app tools as native function calls; only `ptc_lisp_execute` is available natively."

  @in_process_text_mode_description "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation, filtering, aggregation, or multi-step data transformation. Call `:both`-exposed app tools as `(tool/name ...)` from inside the program. The same tools are also callable natively in this assistant turn, but not in the same turn as `ptc_lisp_execute`."

  @mcp_no_tools_description "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation, filtering, aggregation, or multi-step data transformation. No app tools are available inside the program. Pass external data via the `context` argument; each invocation is independent — there is no memory of prior calls."

  @typedoc """
  Closed union of error reasons surfaced through `render_error/3`.

  Members:

    * `:parse_error`        — PTC-Lisp source failed to parse.
    * `:runtime_error`      — runtime evaluation error inside a program
      (also covers return-validation errors against the agent's
      signature).
    * `:timeout`            — sandbox timeout exceeded.
    * `:memory_limit`       — sandbox memory cap exceeded.
    * `:args_error`         — tool arguments malformed (missing
      `program`, non-string, wrong shape, oversized). Emitted only by
      MCP v1; in-process surfaces never construct it (Addendum #25).
    * `:fail`               — program called `(fail v)` to terminate
      with an error value. Only reason carrying a `result` payload
      (Addendum #4).
    * `:validation_error`   — return-value signature mismatch.
      Reserved for MCP v1; no in-process surface emits it today
      (Tier 0 scope expansion).
  """
  @type error_reason ::
          :parse_error
          | :runtime_error
          | :timeout
          | :memory_limit
          | :args_error
          | :fail
          | :validation_error

  @doc """
  Capability profile for the `ptc_lisp_execute` tool description.

  Returns the canonical description string for the requested profile.
  Per Addendum #11, each profile is one constant returned directly —
  no runtime concatenation. The `:in_process_with_app_tools` string is
  byte-for-byte locked to the existing v1 wording (Addendum #10).
  """
  @spec tool_description(:in_process_with_app_tools | :in_process_text_mode | :mcp_no_tools) ::
          String.t()
  def tool_description(:in_process_with_app_tools), do: @in_process_with_app_tools_description
  def tool_description(:in_process_text_mode), do: @in_process_text_mode_description
  def tool_description(:mcp_no_tools), do: @mcp_no_tools_description

  # ----------------------------------------------------------------
  # Response-payload renderers
  # ----------------------------------------------------------------

  @doc """
  Render a successful `ptc_lisp_execute` invocation as JSON.

  Preserves the v1 success payload shape exactly: `status`, optional
  `result`, `prints`, `feedback`, `memory.{changed,stored_keys,truncated}`,
  and top-level `truncated`.

  ## Required input shape

  `lisp_step` is the `Step.t()` result of `Lisp.run/2`. Only the
  `:return` field is consulted directly (to decide whether to drop the
  `"result"` field when nil).

  ## Recognized opts

    * `:execution` — required for v1 callers. A
      `TurnFeedback.execution_feedback/3` result map carrying
      `:result`, `:prints`, `:feedback`, `:memory.{changed,stored_keys,truncated}`,
      and `:truncated`. The renderer reads these directly. Future
      callers (MCP server, text-mode) MAY pass their own equivalent
      map.
    * `:validated` — JSON-encodable value. When present, included as
      a top-level `"validated"` field. Used by MCP v1 to surface
      schema-validated return values.

  Unknown opts are ignored (Addendum #12).

  ## Result-field elision

  Matches the v1 invariant: when both `execution.result` and
  `lisp_step.return` are `nil`, the `"result"` field is dropped from
  the JSON. Any other combination keeps the field (even when the
  rendered value is `null`).
  """
  @spec render_success(map(), keyword()) :: String.t()
  def render_success(lisp_step, opts \\ []) do
    execution = Keyword.fetch!(opts, :execution)

    payload = %{
      "status" => "ok",
      "result" => execution.result,
      "prints" => execution.prints,
      "feedback" => execution.feedback,
      "memory" => %{
        "changed" => execution.memory.changed,
        "stored_keys" => execution.memory.stored_keys,
        "truncated" => execution.memory.truncated
      },
      "truncated" => execution.truncated
    }

    payload =
      if is_nil(payload["result"]) and is_nil(Map.get(lisp_step, :return)) do
        Map.delete(payload, "result")
      else
        payload
      end

    payload =
      case Keyword.fetch(opts, :validated) do
        {:ok, value} -> Map.put(payload, "validated", value)
        :error -> payload
      end

    Jason.encode!(payload)
  end

  @doc """
  Render an error `ptc_lisp_execute` response as JSON.

  Every member of `error_reason()` is handled. Output payload keys:

    * `"status"` — always `"error"`.
    * `"reason"` — `Atom.to_string/1` of the reason atom.
    * `"message"` — the supplied human-readable message.
    * `"feedback"` — defaults to `message`; overridden via
      `feedback:` opt.
    * `"result"` — present **only when** `reason == :fail`. The value
      is taken from the `result:` opt (Addendum #4: `:fail` is the
      only reason that carries a value).

  ## Recognized opts

    * `:result`   — only meaningful for `reason: :fail`. Encoded as
      the top-level `"result"` field (typically a string preview of
      the failed value). Ignored for any other reason.
    * `:feedback` — string. Defaults to `message` when not provided.

  Unknown opts are ignored (Addendum #12).
  """
  @spec render_error(error_reason(), String.t(), keyword()) :: String.t()
  def render_error(reason, message, opts \\ []) when is_atom(reason) and is_binary(message) do
    feedback = Keyword.get(opts, :feedback, message)

    base = %{
      "status" => "error",
      "reason" => Atom.to_string(reason),
      "message" => message,
      "feedback" => feedback
    }

    payload =
      case reason do
        :fail -> Map.put(base, "result", Keyword.get(opts, :result))
        _ -> base
      end

    Jason.encode!(payload)
  end

  # ----------------------------------------------------------------
  # Re-exports
  # ----------------------------------------------------------------
  #
  # Thin wrappers so future `Loop.TextMode` (and the MCP server tier)
  # do not have to reach into v1 internals (`Loop.JsonHandler`, etc.)
  # directly. Bodies are pure delegation; no behavior change.

  @doc """
  Delegates to `PtcRunner.Lisp.run/2`.

  Re-exported here so non-v1 callers (text-mode combined loop, MCP
  server) can drive PTC-Lisp programs through the protocol module
  without depending on the v1 loop's transitive aliases.
  """
  @spec lisp_run(String.t(), keyword()) ::
          {:ok, PtcRunner.Step.t()} | {:error, PtcRunner.Step.t()}
  def lisp_run(source, opts \\ []), do: Lisp.run(source, opts)

  @doc """
  Delegates to `PtcRunner.SubAgent.Loop.JsonHandler.atomize_value/2`.

  Used by surfaces that need to coerce a raw JSON value into the
  shape implied by a parsed signature before validation.
  """
  @spec atomize_value(term(), term()) :: term()
  def atomize_value(value, type), do: JsonHandler.atomize_value(value, type)

  @doc """
  Delegates to `PtcRunner.SubAgent.Loop.JsonHandler.validate_return/2`.

  Used by surfaces that need to validate a return value against an
  agent's parsed signature.
  """
  @spec validate_return(map(), term()) :: :ok | {:error, list()}
  def validate_return(definition, value), do: JsonHandler.validate_return(definition, value)
end
