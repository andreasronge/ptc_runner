# Opt-In PTC-Lisp Tool-Call Transport (v1)

## Summary

Add `ptc_transport: :tool_call` for `output: :ptc_lisp` agents. In this mode, the LLM no longer returns markdown-fenced Clojure. Instead, PtcRunner exposes one internal native tool, `lisp_eval`, whose `program` argument contains PTC-Lisp source. The LLM may call that tool zero or more times, then return a final answer directly. Final answers are validated against `signature:` as today.

The current markdown-fence parser remains the default via `ptc_transport: :content`. **`:auto` is intentionally out of scope for v1** — capability detection in this codebase is not strong enough to make a fallback path predictable, and it adds the highest-complexity surface for the least proven value. Add later only if real usage demands it.

## Non-Goals

- No `:auto` mode.
- No flipping the default to `:tool_call` in this release.
- No exposing app tools as native provider tools — app tools remain callable only from sandboxed PTC-Lisp via `(tool/name ...)`.
- No new capability-detection layer in the adapter.

## Requirements

Stable IDs for traceability in PRs and reviews. Each requirement points to the section that specifies it.

**API & Validation**
- **R1** — Add `ptc_transport: :content | :tool_call` to `SubAgent.new/1`, default `:content`. *(Public API)*
- **R2** — Reject `ptc_transport` with `output: :text` (`ArgumentError` naming both keys). *(Public API)*
- **R3** — Reject invalid `ptc_transport` values with `ArgumentError` listing accepted values. *(Public API)*
- **R4** — Reserve the tool name `lisp_eval` globally; validator rejects any user app tool with that name regardless of mode. *(Public API, Implementation Plan → Definition + Validator)*

**Two Tool Layers**
- **R5** — In `:tool_call` mode, the LLM request `tools` field contains exactly one entry (`lisp_eval`); app tools are never exposed as provider-native tools. *(Two Tool Layers)*
- **R6** — System prompt continues to render the app-tool inventory in `:tool_call` mode. *(Two Tool Layers)*
- **R7** — The `lisp_eval` tool description explicitly tells the model to call app tools as `(tool/name ...)` from inside the program, not as native calls. *(Two Tool Layers)*

**Transport Behavior**
- **R8** — One `lisp_eval` call per assistant turn → execute via `Lisp.run/2`, threading memory / journal / tool_cache / child_steps / turn_history identically to `:content` mode. *(Behavior #1)*
- **R9** — Direct content with no tool calls → treat as final answer, validate against `signature:`. *(Behavior #2)*
- **R10** — Direct-final-answer `Step` preserves PTC loop state (memory, journal, tool_cache, child_steps, summaries from the latest execution). Reuse `JsonHandler` parsing/coercion helpers but not its step-building path. *(Behavior #2)*
- **R11** — `tool_calls` + content together → execute tool, preserve content in history, do not treat content as final. *(Behavior #3)*
- **R12** — Multiple `lisp_eval` calls in one turn → execute none, append one error tool_result per `tool_call_id`, continue. *(Behavior #4)*
- **R13** — Unknown native tool (single call) → append paired error tool_result, continue. Any assistant turn with **more than one** native tool call — regardless of names, valid or unknown — is treated as multi-call rejection (R12); execute none, pair errors for every `tool_call_id`. The rule is "exactly one native tool call per turn," learned uniformly through feedback. *(Behavior #5)*
- **R14** — Malformed args (missing / non-string / empty `program`, `args_error`) → paired error tool_result, continue. *(Edge Cases)*
- **R15** — `(return v)` / `(fail v)` → append paired final tool_result, then terminate. *(Behavior #1)*
- **R16** — Markdown-fenced clojure as content in `:tool_call` mode → targeted feedback, do not parse as PTC-Lisp, do not run signature validation first. *(Behavior #7)*
- **R17** — Provider without native tool calling → surface `:llm_error` with provider reason; no fallback. *(Edge Cases, Adapter)*
- **R17a** — Protocol-error recovery turns (multiple calls, unknown tool, malformed args, fenced-content feedback in `:tool_call` mode) consume a `max_turns` slot, exactly like parse/runtime retry feedback in `:content` mode. `lisp_eval`'s exemption from `max_tool_calls` (R19) does not extend to `max_turns`. *(Behavior #4, Behavior #5, Behavior #7, Edge Cases)*

**Pairing, Budget, History**
- **R18** — Universal pairing: every returned `tool_call_id` paired with a `role: :tool` message before continuing or terminating, including success, `(return)`, `(fail)`, and all protocol-error paths. *(Behavior — universal pairing rule)*
- **R19** — `max_tool_calls` does **not** count `lisp_eval`; it continues to bound app tools called inside PTC-Lisp via `(tool/...)`. *(Behavior — `max_tool_calls` semantics)*
- **R20** — `*1/*2/*3` reference previous successful `lisp_eval` executions, not direct-answer turns. "Successful" means an intermediate execution that returned a value normally; `(return)`, `(fail)`, parse / runtime / timeout / memory errors, validation failures, and protocol errors do not advance `turn_history`. *(Implementation Plan → `*1`/`*2`/`*3` history)*

**Tool-Result Shape**
- **R21** — Refactor: extract `TurnFeedback.execution_feedback/3` from `format/3`; reimplement `format/3` on top of it without behavior change. *(Tool-result message shape)*
- **R22** — Success tool-result JSON matches spec (`status`, `result`, `prints`, `feedback`, `memory.{changed,stored_keys,truncated}`, `truncated`). *(Tool-result message shape)*
- **R23** — Error tool-result JSON matches spec; `feedback` field contains execution / protocol error text only — no `append_turn_info`, no `append_progress`. The error shape carries an optional `result` field, **present only for `reason: "fail"`** with the failed-value preview; absent for all other error reasons. *(Tool-result message shape)*
- **R24** — `feedback` is produced by `execution_feedback/3` (success) or its error-rendering helpers (execution errors); the protocol-error renderer for `unknown_tool` / `multiple_tool_calls` / `args_error` lives in `Loop.PtcToolCall`, not in `TurnFeedback` — protocol feedback is transport concern, not PTC execution concern. Never produced by `format/3`. *(Tool-result message shape)*

**System Prompt**
- **R25** — Add `@output_format_tool_call` (and thinking variant); select in `resolve_static_sections/2` based on `agent.ptc_transport`. *(Implementation Plan → System prompt)*
- **R26** — Tool-call output format instructs the model to call `lisp_eval` for computation/orchestration, return final answers directly in signature shape, and not return fenced code. *(Implementation Plan → System prompt)*

**Telemetry / Compaction / Adapter**
- **R27** — Telemetry parity: execution turns record `program / raw_response / prints / tool_calls / memory / result preview`; direct-final turns record raw content with `program: nil`. *(Implementation Plan → Telemetry)*
- **R28** — Compaction handles the new message shape (assistant `tool_calls` + `role: :tool` messages) without dropping `tool_call_id` pairings. *(Implementation Plan → Compaction)*
- **R29** — No new adapter capability detection. A "disable parallel tool calls" knob is wired only if a current/future adapter version exposes one — Phase 4 must not block on finding it. The multi-call rejection path (Behavior #4) is the correctness source of truth. *(Implementation Plan → Adapter)*

**Tests & Docs**
- **R30** — Unit and integration test coverage per the Tests section, including the parity test against `execution_feedback/3` and the universal-pairing assertion under `collect_messages: true`. *(Tests)*
- **R31** — Documentation updates per the Docs section (usage-rules, README output-mode section, SubAgent guides, troubleshooting, livebook). *(Docs)*
- **R32** — `demo/` benchmark comparing turn-count and cost between `:content` and `:tool_call` for one representative workload. *(Tests → Bench / eval)*

## Phases

Implement in order. Each phase is **reviewable independently on a feature branch**, but landing on `main` follows the merge policy below.

**Merge policy:** Phases 1–3 may land on `main` only if the runtime treats `:tool_call` as not-yet-implemented — `Loop` must raise `ArgumentError` (or surface a clear `:not_implemented` error) when an agent constructed with `ptc_transport: :tool_call` is actually executed, until Phase 4 lands. This avoids users opting into a half-wired transport.

**The Phase 1 runtime guard is removed in the same commit/PR that satisfies Phase 4's full DoD — never earlier.** Phase 4's 4a / 4b split is a *suggested commit boundary within that PR* for review ergonomics; 4a alone (success path without protocol-error handling) must not land on `main` with the guard removed. Either both halves of Phase 4 are merged together, or the guard stays. Phase 5 may land normally once its DoD is met.

**Index vs spec:** the Requirements section above is an index into the detailed sections. **If a requirement line and a detailed section conflict, the detailed section wins** and the requirement index must be corrected — never the reverse. Terse IDs are not a parallel spec.

### Phase 1 — Foundation (R1–R4)

Add the surface area without changing runtime behavior.

- Add `:ptc_transport` to `SubAgent.Definition` with default `:content`.
- Validator rejects invalid values, the `:text` combination, and any user tool named `lisp_eval`.
- Loop still routes everything through the existing `:content` path; `:tool_call` is constructible but executing such an agent raises `ArgumentError` with message `"ptc_transport: :tool_call not yet implemented"`. This guard is removed in Phase 4.

**DoD:** agents can be built with `:tool_call`; executing one raises the not-yet-implemented error; all existing tests pass unchanged; new validator tests cover R1–R4 plus the runtime guard.

### Phase 2 — TurnFeedback refactor (R21)

De-risks Phase 4 by isolating the shared rendering helper.

- Extract `TurnFeedback.execution_feedback/3` returning the structured map specified in the Tool-result message shape section.
- Reimplement `TurnFeedback.format/3` as a thin wrapper that calls `execution_feedback/3` and appends `append_turn_info` / `append_progress`.

**DoD:** all existing content-mode feedback tests pass byte-for-byte (golden regression); new unit tests cover `execution_feedback/3` directly.

### Phase 3 — System prompt and native tool schema (R5, R6, R7, R25, R26)

The "two layers" become observable on the wire even before execution is wired.

- Add `@output_format_tool_call` and the thinking variant; select in `resolve_static_sections/2`.
- Build the `lisp_eval` OpenAI-format tool schema with the proactive "use `(tool/name ...)` inside the program" guidance.
- In `:tool_call` mode, the LLM request includes exactly one native tool entry; system prompt still renders the full app-tool inventory.

**DoD:** request-building tests assert the request shape (one native tool, full inventory in prompt); schema description includes the guidance string. Loop still raises the Phase 1 not-yet-implemented error after the request is built.

**Test hook:** these tests use a **capture LLM callback** — a test-supplied `llm:` function that sends the received request map to the test process via `send(self(), {:llm_request, req})` and returns a harmless canned response. This avoids inventing a public "preview LLM input" API just for tests. The same hook is reused throughout Phase 4.

### Phase 4 — Loop branch and execution (R8–R20, R22–R24, R27–R29)

The bulk of the work. Land as a single PR with two suggested *internal* commit boundaries for review ergonomics — **not** as two separately mergeable phases:

- **4a — Success path + state preservation:** new `Loop.PtcToolCall` module, `:tool_call` branch in the loop, single-call success, `(return)` / `(fail)` termination with paired final tool result (including the optional `result` field for `reason: "fail"`), direct-final-answer step assembly preserving PTC state (memory / journal / tool_cache / child_steps / `Loop.State.summaries`), success tool-result JSON shape, telemetry parity.
- **4b — Protocol errors + pairing + auxiliaries:** ">1 native tool call" multi-call rejection (uniform across same-name and mixed-name cases), unknown-tool single-call rejection, malformed args, fenced-content targeted feedback, universal pairing rule, error tool-result JSON shape (including optional `result` for `fail`), protocol-error renderer in `Loop.PtcToolCall`, `*1/*2/*3` semantics (intermediate normal-return only), `max_tool_calls` semantics, compaction support, best-effort parallel-tool-calls disable.

**DoD:** all unit tests in the Tests section pass; `mix precommit` clean; collected-message assertion (R18) covers every branch listed under it. **The Phase 1 runtime guard is removed in the commit that satisfies this DoD** — 4a alone does not satisfy DoD and must not remove the guard.

### Phase 5 — Integration and docs (R30 integration portion, R31)

- Integration tests (`@tag :integration`) for Scenarios 1–4, gated on `OPENROUTER_API_KEY`. **Mandatory.**
- Documentation updates per the Docs section, including the "when to use which transport" guidance. **Mandatory.**
- `demo/` benchmark (R32) comparing `:content` vs `:tool_call` turn-count and cost on one representative workload. **Optional but strongly recommended** before any future decision to flip the default — without it there is no data to inform that decision. Not a blocker for shipping `:tool_call` as opt-in.

**DoD:** integration suite green when the env var is set; docs reviewed for parity / non-regression of the `:content` mode story. Benchmark recorded if completed; if deferred, opened as a follow-up issue referencing R32.

## Two Tool Layers

`:tool_call` transport introduces a deliberate two-layer model. Keeping these distinct is the single most important conceptual point in this design — conflating them confuses both the LLM and anyone reading the code (`tool_calls` already means different things in different files; this feature stretches the term further).

| Layer | What it is | Who sees it | How the LLM invokes it |
|---|---|---|---|
| **Provider-native layer** | Exactly one tool: `lisp_eval`. | The LLM provider (OpenAI / Anthropic / etc.) via the `tools` field on the request. | Native function-calling — returns a `tool_calls` block in the assistant message. |
| **PTC-Lisp layer** | All app tools registered on the agent. | The LLM via the existing **system-prompt** Tool Inventory / namespace sections — exactly as in `:content` mode. | From inside a PTC-Lisp program: `(tool/name ...)`. Never as a native provider tool call. |

Rules:

- **App tools are never exposed as provider-native tools in `:tool_call` mode.** They stay inside the sandbox, callable only from PTC-Lisp source. This preserves PtcRunner's safety and determinism guarantees: every app-tool invocation is observable, cacheable, and bounded by `max_tool_calls`.
- **System prompt continues to render the app-tool inventory** unchanged. The Tool Inventory / namespace sections are not removed in `:tool_call` mode — they document what's callable from inside `(tool/name ...)`.
- **The `lisp_eval` description must explicitly tell the model** to call app tools as `(tool/name ...)` inside the program rather than as native function calls. The exact wording is the canonical description string defined in §Internal execution tool — do not paraphrase it in code; reference the canonical constant. This is the single most likely failure mode (model tries to call `search` natively); proactive instruction is cheaper than recovery feedback.
- **Code-reading clarity**: in `Loop.PtcToolCall`, "tool call" without qualifier refers to a *native* tool call (the `lisp_eval` invocation). PTC-Lisp `(tool/...)` invocations continue to be called "app tool calls" and surface as `lisp_step.tool_calls`. Keep the naming separate in module docs and variable names.

This design is the reason `:tool_call` transport is not "just use native tool calls for everything" — that path was rejected up front and stays rejected.

## Public API

Add `ptc_transport: :content | :tool_call` to `PtcRunner.SubAgent.new/1`.

- Default: `:content`.
- Valid only with `output: :ptc_lisp`. Passing `ptc_transport` with `output: :text` raises `ArgumentError` naming both keys.
- Invalid values raise `ArgumentError` listing accepted values.

### Internal execution tool

- Name: `lisp_eval` (reserved globally once `ptc_transport` exists — validator rejects user app tools with this name regardless of mode, to avoid mode-dependent surprises)
- Args: `%{"program" => string}` (non-empty)
- **Canonical description string** (single source of truth — referenced by R7 and the Two Tool Layers section; tests assert stable substrings from this string):

  > Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for deterministic computation and tool orchestration. Call app tools as `(tool/name ...)` from inside the program — do not attempt to call app tools as native function calls; only `lisp_eval` is available natively.

## Behavior

### `:content` mode (unchanged)

Current `ResponseHandler.parse/1` → `execute_code/4` path. No behavior change.

### `:tool_call` mode

Per assistant turn:

1. **LLM returns one `lisp_eval` call.**
   Execute via existing `Lisp.run/2` path. Memory, journal, tool_cache, child_steps, turn_history continue to thread through loop state exactly as today.
   - On `(return v)` / `(fail v)`: emit a final tool-result message (see shape below), then terminate the loop.
   - On intermediate value: emit tool-result message, continue to next turn.
2. **LLM returns content directly with no tool calls.**
   Treat as final answer. Validate / coerce against `signature:` per the rules below.

   **Zero-execution case (direct answer on turn 1, no `lisp_eval` ever called):** the returned `Step` carries the *initial* loop state — `memory` is the agent's `initial_memory` (default `%{}`), and `journal / tool_cache / child_steps / summaries` are whatever the loop state holds at construction. No execution means no execution-derived state, but initial state is preserved. The "not empty maps" rule in R10 applies only to direct answers that follow at least one execution.

   **Signature handling for direct final content:**
   - **No signature, or `:string`, or `:any`** — return raw text (no JSON parse).
   - **`{:map, ...}` or `{:list, ...}`** — parse content as JSON, coerce keys/values via `JsonHandler.atomize_keys` / `atomize_value`, validate via `JsonHandler.validate_return`.
   - **Primitive non-string signatures (`:int`, `:float`, `:bool`, `:datetime`)** — accept either:
     - a bare JSON primitive (e.g. content is `42`, `true`, `"2026-05-05T00:00:00Z"` for `:datetime`), parsed via `Jason.decode/1` and coerced via `JsonHandler.atomize_value`, **or**
     - for `:datetime`, a raw ISO-8601 string with no surrounding JSON quotes (mirrors current temporal-input handling).
   - **`{:optional, inner}`** — accept JSON `null` or any value valid for `inner`.
   - **Parse failures or validation failures** — consume a retry turn and feed validation feedback as today, never silently coerce.

   This locks in the boundary so primitive-signature agents in `:tool_call` mode aren't a separate ambiguity surface.
   **Final step assembly must preserve PTC loop state**: the returned `Step` has `memory`, `journal`, `tool_cache`, `child_steps`, `summaries`, and `tool_calls` taken from the latest accumulated loop state — not the empty maps `JsonHandler` produces today. (`summaries` here is the existing `Loop.State.summaries` field — not new surface.) Reuse `JsonHandler`'s parsing/coercion/validation helpers (`atomize_keys`, `atomize_value`, `validate_return`, `format_validation_errors`) but **do not** reuse its step-building path. Add a PTC-aware step assembler in `Loop.PtcToolCall` that takes the validated value and the current loop state, and emits the `Step`.

   **State after an errored latest execution.** Memory / journal / tool_cache / child_steps / summaries reflect the last *successful* execution; sandbox state from a failed execution is not promoted into parent loop state. Loop-level error context (e.g. `last_fail` for retry feedback) is preserved exactly as in `:content` mode — no behavior change. The principle is parity with `:content` mode error handling, not a new mechanism.
3. **LLM returns both `tool_calls` and content.**
   Execute the tool call. The assistant message keeps `content` alongside `tool_calls` in the transcript (standard message shape) — it is not re-surfaced to the model separately, just preserved on its own turn. Do not treat content as final while tool calls are present. The fenced-Clojure targeted feedback in Behavior #7 does **not** fire when tool calls are present — #7 applies only when content is the *only* thing returned. No double feedback. This turn consumes one `max_turns` slot like any execution turn.
4. **LLM returns more than one native tool call in one assistant turn — regardless of names.**
   Reject all of them. Execute none. The rule is "exactly one native tool call per assistant turn," and the model learns it uniformly through feedback rather than via per-name special cases. This covers two `lisp_eval` calls, `lisp_eval` + an unknown tool, two unknown tools, etc. **Append one `role: :tool` error message per `tool_call_id`**, each carrying the same protocol-error payload (`reason: "multiple_tool_calls"`, "exactly one `lisp_eval` call per assistant turn"). Then continue if turn budget allows. Pairing every returned `tool_call_id` with a `tool_result` is required for strict providers (Anthropic) — partial pairing produces invalid transcripts. Also configure provider requests to disable parallel tool calls where the adapter supports it (best-effort; do not rely on it).
5. **LLM calls an unknown native tool (single call).**
   Append a `role: :tool` error message paired to the unknown call's `tool_call_id` with protocol-error payload (`reason: "unknown_tool"`). Continue if turn budget allows. Only `lisp_eval` is valid in this transport. (If the unknown call is one of multiple native tool calls, route through Behavior #4 instead — the multi-call rule wins.)
6. **Validation failure on direct final content.**
   Consume a retry turn and feed validation feedback as today.
**Universal pairing rule for native tool-call protocol errors:** every `tool_call_id` returned by the LLM must be paired with a `role: :tool` message before the loop continues or terminates. This applies to malformed args, unknown tool names, multiple-call rejection, *and* the success path including `(return)` / `(fail)`. Never drop a `tool_call_id` silently.

**`max_tool_calls` semantics:** `lisp_eval` does **not** count against `max_tool_calls`. That budget continues to limit *app tools* invoked from inside PTC-Lisp via `(tool/name ...)`, exactly as in `:content` mode. The execution tool itself is bounded by the "one call per assistant turn" rule and by `max_turns`.

**`max_turns` semantics for protocol errors:** every assistant turn that produces a paired error tool-result (multiple-call rejection, unknown tool, malformed args) and every turn that produces fenced-content targeted feedback consumes a `max_turns` slot, identical to a parse/runtime retry turn in `:content` mode. The `max_tool_calls` exemption above is intentionally narrow — it does not extend to `max_turns`.

7. **LLM returns markdown-fenced Clojure as content.**
   Targeted feedback (do not run generic signature validation first):
   > In `ptc_transport: :tool_call`, call the `lisp_eval` tool with the program instead of returning fenced code.

### Tool-result message shape (specified)

JSON, compact. Sent as the `content` field of a `role: :tool` message keyed by `tool_call_id`.

The LLM-facing `feedback` string is the **primary** thing the model should read. It is generated by a new helper `PtcRunner.SubAgent.Loop.TurnFeedback.execution_feedback/3` that returns *only* the execution-feedback portion — result preview (`user=> ...`), printed `println` output, and changed/new memory previews (`;; items = [...]`). It deliberately excludes the loop-control scaffolding that `format/3` currently appends (`append_turn_info`, `append_progress` / `progress_fn`), because those are loop-level concerns that do not belong inside a native tool result — a tool result should describe what happened when the tool ran, not embed turn budgets or product-specific progress rendering.

Refactor: factor the execution-feedback computation out of the existing `TurnFeedback.format/3` into `execution_feedback/3`, then reimplement `format/3` as:

```elixir
execution = execution_feedback(agent, state, lisp_step)

feedback =
  execution.feedback
  |> append_turn_info(agent, state)
  |> append_progress(agent, state, lisp_step)

{feedback, execution.truncated, new_progress_state}
```

`execution_feedback/3` returns:

```elixir
%{
  feedback: "user=> ...\n\n;; items = [...]\n;; totals = {...}",
  prints: ["..."],
  result: "<final expression preview>",
  memory: %{
    changed: %{"items" => "[{:id 1 ...}]", "totals" => "{:count 3 ...}"},
    stored_keys: ["items", "totals"],
    truncated: false
  },
  truncated: false
}
```

This guarantees parity at the right layer: tool-call mode reuses the execution portion exactly, content mode keeps appending turn info and progress as today, and a user's `progress_fn` cannot accidentally leak into every `lisp_eval` tool result. The structured fields around `feedback` are machine-readable affordances, not a replacement for it.

**Success:**
```json
{
  "status": "ok",
  "result": "<final expression preview, EDN/Clojure-rendered>",
  "prints": ["..."],
  "feedback": "user=> ...\n\n;; items = [...]\n;; totals = {...}",
  "memory": {
    "changed": {
      "items": "[{:id 1 ...}]",
      "totals": "{:count 3 ...}"
    },
    "stored_keys": ["items", "totals"],
    "truncated": false
  },
  "truncated": false
}
```

**Error (parse / runtime / sandbox / protocol / fail):**
```json
{
  "status": "error",
  "reason": "parse_error" | "runtime_error" | "timeout" | "memory_limit" | "args_error" | "unknown_tool" | "multiple_tool_calls" | "fail",
  "message": "<short error string from existing PTC-Lisp feedback or protocol error>",
  "result": "<failed-value preview, EDN/Clojure-rendered>",
  "feedback": "<execution or protocol error feedback only — no turn info, no progress>"
}
```

`result` is **optional** and is **present only for `reason: "fail"`** — it carries the value passed to `(fail v)`. For all other error reasons (`parse_error` / `runtime_error` / `timeout` / `memory_limit` / `args_error` / `unknown_tool` / `multiple_tool_calls`), the field is omitted.

The `feedback` field in error tool results contains **only** execution-error or protocol-error text. It must **not** include `append_turn_info` or `append_progress` output, for the same reason success feedback excludes them — loop-control scaffolding does not belong in a tool result. Reuse `TurnFeedback.execution_feedback/3` (or its underlying error-rendering helpers) for execution errors. The protocol-error renderer for `unknown_tool` / `multiple_tool_calls` / `args_error` lives in `Loop.PtcToolCall` (transport concern), not in `TurnFeedback` (PTC execution concern).

Rules:
- `feedback` is produced by `TurnFeedback.execution_feedback/3` (the factored-out execution portion of `format/3`). Do **not** hand-roll a parallel renderer, and do **not** include `append_turn_info` / `append_progress` output in the tool-result JSON.
- `memory.changed` previews are computed by the same `changed_vars` path `TurnFeedback` already uses — only new/changed vars, never full memory snapshots, never unchanged vars echoed turn after turn.
- `memory.stored_keys` is a fallback orientation hint for when nothing changed or previews were truncated.
- All previews are EDN/Clojure-rendered so the LLM (which is writing PTC-Lisp) can refer to the shapes naturally.
- Reuse the same `feedback_max_chars` / `preview_max_chars` truncation knobs from `agent.format_options`. Surface truncation flags both at the top level (`truncated`) and per memory section (`memory.truncated`) where applicable.
- `(return v)` / `(fail v)` produce success/error shapes respectively, with `result` set to the returned/failed value preview. `(fail v)` uses `reason: "fail"` — it is semantically distinct from runtime/protocol errors, since it represents the program signalling intentional failure rather than the runtime detecting one. The loop terminates *after* this message is appended so transcripts remain provider-valid (Anthropic requires every `tool_use` to have a paired `tool_result`).

## Implementation Plan

### Definition + Validator

- Add `:ptc_transport` to `PtcRunner.SubAgent.Definition` (default `:content`).
- `PtcRunner.SubAgent.Validator`:
  - Validate `:ptc_transport` is `:content` or `:tool_call`.
  - Raise `ArgumentError` if set with `output: :text`.
  - Reject any user tool named `lisp_eval` (globally, regardless of transport).

### Loop split

In `PtcRunner.SubAgent.Loop`:

- Branch on `agent.ptc_transport` after the existing `output: :ptc_lisp` route.
- `:content`: existing `ResponseHandler.parse/1 -> execute_code/4` path.
- `:tool_call`: new handler that consumes `%{tool_calls: [...]}` and direct `%{content: ...}` responses.

The new handler reuses:
- `Lisp.run/2` and the entire memory/journal/tool_cache/turn_history threading already in `build_continuation_state/5`.
- `ReturnValidation` for direct-final-answer signature checks.
- `TurnFeedback` truncation/render utilities for tool-result content.

### New module

`PtcRunner.SubAgent.Loop.PtcToolCall` (small, focused):

- Build OpenAI-format tool schema for `lisp_eval`.
- Extract atom-keyed or string-keyed args; convert malformed args (`args_error`, missing `program`, non-string `program`, empty `program`) into protocol feedback rather than crashes.
- Render success/error tool-result JSON using the shape above.
- Append paired tool-result messages — including the final one before termination on `(return)` / `(fail)`.

### System prompt

In `PtcRunner.SubAgent.SystemPrompt`:

- Add `@output_format_tool_call` (and a thinking variant) alongside the existing `@output_format` constants at `system_prompt.ex:58-83`.
- Select in `resolve_static_sections/2` based on `agent.ptc_transport`.
- Tool-call format instructs the model to:
  - Call `lisp_eval` for deterministic computation and tool orchestration.
  - Return the final answer directly in the requested signature shape when ready.
  - Not return fenced code blocks.
- Keep existing PTC-Lisp language reference and tool namespace docs so generated programs can still call app tools via `(tool/name ...)`.

### `*1` / `*2` / `*3` history

Tied to previous PTC-Lisp executions, **not** LLM turns. Only **intermediate executions that returned a value normally** update `turn_history`. The following do **not** advance history:

- `(return v)` — terminates the loop; advancing history is unobservable and skipping it keeps the implementation symmetric (terminating turns never write history).
- `(fail v)` — terminates the loop with an error.
- Parse / runtime / timeout / memory-limit errors.
- Validation failures on direct final content.
- Protocol errors (multi-call, unknown tool, malformed args).
- Direct-final-answer turns (no execution happened).

`*1` is "previous successful intermediate expression result." This preserves the existing mental model from `:content` mode.

### Telemetry / tracing

- Tool-call execution turns: record `program`, `raw_response`, `prints`, `tool_calls`, memory, result preview (same fields as today). **The `tool_calls` field on execution turns refers to *app tool calls* invoked from inside the PTC-Lisp program (`lisp_step.tool_calls`)**, not the native `lisp_eval` invocation. The native call is represented in message history and `raw_response`, not in this field. This preserves naming parity with `:content` mode.
- Direct final-answer turns: record raw content with `program: nil`. Verify `Telemetry` and `StepAssembler` don't assume non-nil `program`.
- LLM telemetry reports `"tool_calls"` when native tool calls are returned by the provider — that is a *separate* field from the per-turn `tool_calls` above.

**Future cleanup (out of scope for v1):** consider renaming the per-turn execution-record field to `app_tool_calls` to remove the overload entirely. The current naming is preserved here for parity with `:content` mode and to keep the diff small; the rename is a strict improvement when the codebase is touched broadly.

### Compaction

`PtcRunner.SubAgent.Compaction` operates on message history. Tool-call transport changes the shape (assistant `tool_calls` + `role: :tool` messages). Verify compaction handles the new shape — current text-mode tool-call paths already produce this shape, so the work may be small, but it must be exercised in tests.

### Adapter

No new capability detection. Existing `req_llm_adapter.ex` already passes `tools` and surfaces `tool_calls`. If a provider raises `:tool_calling_not_supported` (Ollama / openai-compat), surface as `:llm_error` with provider reason — user picks a different model.

**Parallel-tool-calls disable knob — future / best-effort only.** Today's `req_llm_adapter.ex` is not assumed to expose a "disable parallel tool calls" option, and Phase 4 must not block on finding one. If a future ReqLLM (or direct adapter) version exposes such an option, wire it through then. The source of truth for "exactly one `lisp_eval` per turn" is the multi-call rejection path (Behavior #4); the knob is a soft latency/cost optimization, not a correctness mechanism.

### Program size

No arbitrary library limit. Reject empty / missing `program` with a clear protocol error. Document that provider tool-argument size limits may apply.

## Edge Cases (consolidated)

| Case | Behavior |
|---|---|
| Provider does not support native tool calls | `:llm_error` with provider reason. No fallback. |
| Markdown fence in content (`:tool_call` mode) | Targeted feedback, do not parse as PTC-Lisp, do not run signature validation first. |
| `tool_calls` + content together | Execute tool call. Preserve content in history. Do not treat content as final. |
| More than one native tool call in one turn (any names — same, different, or mixed valid + unknown) | Reject all. One paired `multiple_tool_calls` error per `tool_call_id`. Continue if budget allows. |
| Unknown native tool (single call only) | Paired `unknown_tool` error. Continue if budget allows. |
| Malformed args (missing/non-string `program`, `args_error`) | Protocol feedback. Continue. |
| Program parse / runtime / sandbox error | Reuse existing PTC-Lisp error feedback, wrapped in error-shape JSON. |
| `(return v)` / `(fail v)` | Append final paired tool-result, then terminate. |
| Direct final answer before any execution | Allowed. Signature-validated. |
| Direct final answer after execution(s) | Allowed. Signature-validated. |
| Complex signature on direct final content | Parse JSON, validate string-keyed map output. Failures consume retry turns. |
| App tool named `lisp_eval` | Validator rejects at agent construction (globally). |

## Tests

### Unit

- `ptc_transport` validation: accepts `:content`, `:tool_call`; rejects others; rejects with `output: :text`.
- `:content` regression: existing fenced/raw parsing tests still pass unchanged.
- `:tool_call`: executes `lisp_eval`, returns immediately on `(return ...)`, with paired final tool-result message present in history.
- `:tool_call`: intermediate execution followed by direct final JSON content.
- `:tool_call`: direct final JSON validated against signature, covering each branch of the signature-handling rules:
  - no signature / `:string` / `:any` → raw text returned.
  - `{:map, ...}` and `{:list, ...}` → JSON parsed and coerced.
  - `:int`, `:float`, `:bool` → bare JSON primitives accepted.
  - `:datetime` → both JSON-quoted ISO-8601 and raw ISO-8601 string accepted.
  - `{:optional, inner}` → JSON `null` accepted.
  - parse and validation failures consume a retry turn each.
- Phase 1 runtime guard: executing a `:tool_call` agent before Phase 4 raises the not-yet-implemented error. Removed when Phase 4 lands.
- `:tool_call`: invalid direct final content triggers retry feedback (consumes retry turn).
- `:tool_call`: markdown-fenced content produces targeted feedback, not signature-validation feedback.
- `:tool_call`: malformed tool args → recoverable protocol feedback.
- `:tool_call`: unknown native tool → recoverable protocol feedback.
- `:tool_call`: multiple `lisp_eval` calls in one turn → all rejected, none executed, one paired protocol-error per `tool_call_id`.
- `:tool_call`: mixed `lisp_eval` + unknown-tool calls in one turn → uniformly routed to multi-call rejection (`reason: "multiple_tool_calls"`), none executed, paired errors for every `tool_call_id`. Asserts the "exactly one native tool call per turn" rule wins over per-name handling.
- `:tool_call`: error tool-result JSON for `(fail v)` includes `result` with the failed-value preview; error tool-result JSON for `parse_error` / `runtime_error` / `timeout` / `args_error` / `unknown_tool` / `multiple_tool_calls` does **not** include a `result` field.
- `:tool_call`: `*1` / `*2` / `*3` reference previous successful `lisp_eval` results, not direct-answer turns.
- Validator: rejects user tool named `lisp_eval`.
- Two-layer separation: in `:tool_call` mode the LLM request's `tools` field contains exactly one entry (`lisp_eval`), regardless of how many app tools the agent declares. App tools must not appear in the native `tools` array.
- App-tool inventory still rendered: in `:tool_call` mode the system prompt still contains the Tool Inventory / namespace sections describing app tools — verify by snapshot or substring assertion against the generated prompt.
- `lisp_eval` tool description includes the "use `(tool/name ...)` inside the program, not native calls" guidance (substring assertion on the schema description).
- Tool-result message shape: success and error JSON match spec, including `feedback`, `memory.changed`, `memory.stored_keys`, and both truncation flags.
- Parity test: for an identical PTC-Lisp program and prior memory, the `feedback` field in `:tool_call` mode equals `TurnFeedback.execution_feedback/3`'s `feedback` value. Assert against `execution_feedback/3`, **not** `format/3` — the tool-result JSON must not contain `append_turn_info` / `append_progress` output.
- Refactor regression test: `TurnFeedback.format/3` output is unchanged for content mode after the factor-out (golden assertion on existing test fixtures).
- Negative test: a custom `progress_fn` set on the agent does **not** appear anywhere in the `lisp_eval` tool-result JSON, in either success or error shapes.
- Direct-final-answer state preservation: after one or more `lisp_eval` calls followed by a direct content answer, the returned `Step` carries `memory`, `journal`, `tool_cache`, `child_steps`, and `summaries` from the latest execution — not empty maps.
- Universal pairing: with `collect_messages: true`, every returned `tool_call_id` from every assistant turn has a paired `role: :tool` message in the final transcript. Cover (a) success path, (b) `(return)`, (c) `(fail)`, (d) `unknown_tool`, (e) `multiple_tool_calls` (one paired error per id), (f) `args_error`.
- `max_tool_calls` semantics: `lisp_eval` invocations do not consume the budget; app tools called from inside the program do. Mirror an existing `:content`-mode `max_tool_calls` test against `:tool_call` mode to confirm parity.
- Error feedback scope: error tool-result `feedback` field contains no turn info and no progress output, even when the agent is multi-turn with a custom `progress_fn`.
- Memory previews: only new/changed vars appear in `memory.changed`; unchanged vars are not re-echoed turn after turn.
- Compaction handles tool-call message history without dropping `tool_call_id` pairings.

### Integration (`@tag :integration`, gated on provider env vars)

- **Scenario 1**: real tool-calling model calls `lisp_eval` once to filter/aggregate data, returns validated structured final answer.
- **Scenario 2**: real model answers directly without calling the execution tool for a simple prompt.
- **Scenario 3**: date/math workflow using tool-returned `DateTime` values through the execution-tool transport.
- **Scenario 4**: parallel-tool-call rejection + recovery. The deterministic coverage is a **scripted/mock test** using a test-supplied `llm:` callback that returns two `tool_calls` in one assistant message, then a valid single call on the next turn. Asserts: none executed on the rejected turn, one paired `role: :tool` error message per `tool_call_id`, recovery on the following turn, both turns counted against `max_turns`. Real-provider coverage of "model spontaneously emits parallel tool calls" is **optional / manual** — relying on a specific live model to behave that way is flaky-by-design.

### Bench / eval

- Add a `demo/` comparison: turn-count and cost between `:content` and `:tool_call` for one representative workload. Without this, there's no data to decide whether to flip the default later.

## Docs

Update:

- `usage-rules.md`
- `usage-rules/subagent.md`
- `usage-rules/llm-setup.md`
- README output-mode section
- SubAgent guides under `docs/guides/`
- troubleshooting docs
- `livebooks/output_modes_in_app_loops.livemd`

Each must explain:

- `ptc_transport: :content` is the default.
- `ptc_transport: :tool_call` is opt-in.
- **When `:content` is preferred**: "one program, one deterministic orchestration" — lower latency, lower cost, single LLM turn.
- **When `:tool_call` is preferred**: providers/models where native tool calling is materially more reliable than markdown-fence parsing, or workloads that genuinely need iterative refinement across multiple program executions.
- Tool-call transport can turn one PTC-Lisp program into a ReAct-style loop. That is a tradeoff, not an upgrade.
- Direct final answers allowed before or after any execution-tool calls.
- Provider support: any model without native tool calling cannot use `:tool_call`; it returns `:llm_error`.
- Why app tools remain inside PTC-Lisp rather than native provider tools.

## Future Work (out of scope for v1)

- `ptc_transport: :auto` — once we have telemetry data on `:tool_call` reliability and a real capability-detection story in the adapter.
- Flipping the default to `:tool_call` — only if bench data shows comparable cost/latency and meaningfully better reliability across providers we care about.
- Disabling parallel tool calls at the request level for providers that expose the knob.

## Assumptions

- Default remains `ptc_transport: :content`.
- `:tool_call` is strict: never parses markdown fences as PTC-Lisp.
- Internal native tool name is `lisp_eval`, reserved globally.
- Direct final content is allowed before or after PTC execution.
- Final direct content is validated against `signature:` when applicable.
- Memory / journal / tool_cache / child_steps / turn_history threading is unchanged from current PTC-Lisp loop semantics.
- Final tool-result message is always appended before loop termination, including on `(return)` / `(fail)`, to keep transcripts provider-valid.
