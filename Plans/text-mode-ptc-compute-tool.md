# Text-Mode PTC-Lisp Compute Tool (Future Discussion Draft)

## Status

The current v1 runtime rejects `output: :text, ptc_transport: :tool_call`
because `Loop.TextMode` does not know how to execute `lisp_eval`,
share state with PTC-Lisp execution, or manage large native tool results.
The rejection is scope discipline, not a statement that the combination
is semantically invalid. This plan describes the path to enable it as an
opt-in feature.

## Addendum (decisions locked after spec review, 2026-05-06)

These decisions supersede or refine statements elsewhere in this document.
When a section below conflicts with the body of the plan, this addendum
wins.

1. **`ptc_reference: :full` is deferred.** v1 accepts only
   `ptc_reference: :compact`. The validator MUST reject `:full` with an
   ArgumentError in v1. Combined mode always includes the compact
   reference; richer/configurable reference content is a follow-up. This
   overrides the `:compact | :full` typespec in "System Prompt."

2. **`chat/3` accepts combined mode; cross-call state does not persist.**
   Each `chat/3` invocation behaves like a fresh combined-mode run over
   the provided messages. `tool_cache`, `journal`, `turn_history`, and
   retained child-execution state do NOT survive across `chat/3` turns.
   The validator MUST NOT reject combined mode in `chat/3`. Document as
   "supported with degraded cache semantics."

   **Known wart (accepted, not fixed in v1).** A previous turn's
   `full_result_cached: true` + `cache_hint` payload references a cache
   key that no longer exists on the next `chat/3` call. The LLM
   following the hint causes a tool re-run, which is correct but
   wasteful. Document in Tier 4 user-facing docs; do not branch the
   preview renderer on chat-vs-run mode.

3. **Tier 0 lands as the first standalone PR of the text-mode track.**
   Tier 0 ships byte-for-byte preserving existing v1 PTC `:tool_call`
   behavior, with profile strings and `error_reason()` enum members for
   all three known consumers (`:in_process_with_app_tools`,
   `:in_process_text_mode`, `:mcp_no_tools`). MCP plan consumes the
   module later; this plan owns the implementation PR.

4. **`render_error/3` for `:fail` is a special-shaped error.** Tier 0
   substring tests MUST assert that `render_error(:fail, message, result:
   value)` produces JSON containing `"reason": "fail"` AND a `"result"`
   field carrying the `(fail v)` value. This is the only `error_reason()`
   member that carries a value; every other reason renders without a
   `result` field.

5. **List-sampling rule for "consistent keys" detection.** Compare the
   first element's key set against up to the next 4 elements **that
   exist**. Lists of length 1–4 compare against whatever is present.
   Lists of length 1 are trivially consistent.

6. **`retained_bytes` telemetry definition.** Computed as
   `:erlang.external_size(full_result)` at the point of cache write. Pin
   in Tier 2b tests and the telemetry section.

7. **Tier 4 user-facing docs file.** `docs/guides/text-mode-ptc-compute.md`.
   Implementers create the file in Tier 4; do not anticipate it earlier.

8. **Agent workflow note for implementers.** Do NOT run `/codex review`
   or `/codex challenge` yourself. Flag the recommended checkpoint in
   the PR description / final note so the human can run review or spawn
   a reviewer.

9. **Test additions (not a spec change, just locking missing coverage):**
   - `:ptc_lisp`-only tool called natively in combined mode → returns
     `unknown_tool` per Multi-Call Rule Row 6 / Row 5.
   - Custom preview function that raises does not corrupt the tool
     function dispatch — the tool's actual return value is unaffected;
     only the preview falls back to metadata.

## Addendum 2 (locked after second spec review, 2026-05-06)

These decisions resolve the remaining ambiguities surfaced during the
second review pass. They supersede or refine statements elsewhere in
this document; when a section below conflicts, this addendum wins.

10. **Tier 0 description: existing v1 wins for `:in_process_with_app_tools`.**
    `PtcToolProtocol.tool_description(:in_process_with_app_tools)` MUST
    return the **exact** string currently in
    `lib/ptc_runner/sub_agent/loop/ptc_tool_call.ex:53` (the
    `@lisp_eval_description` module attribute):

    > "Execute a PTC-Lisp program in PtcRunner's sandbox. Use this for
    > deterministic computation and tool orchestration. Call app tools
    > as `(tool/name ...)` from inside the program — do not attempt to
    > call app tools as native function calls; only `lisp_eval`
    > is available natively."

    The byte-for-byte invariant on existing v1 PTC `:tool_call` behavior
    wins over the MCP plan's current capability-profile table wording.
    The MCP plan's `:in_process_with_app_tools` row in "Tool Description
    Capability Profiles" MUST be updated in lockstep with Tier 0 to
    match this string. New profiles (`:in_process_text_mode`,
    `:mcp_no_tools`) MAY use the MCP plan's proposed wording — the
    constraint applies only to the in-process v1 profile.

11. **Description assembly format: per-profile full string, no
    runtime concatenation.** Each capability profile is stored as one
    canonical string constant. `tool_description/1` returns that
    constant directly — no `base <> " " <> capability_note`
    concatenation at call time. Rationale: avoids newline/spacing drift
    in provider-visible strings and keeps each profile pinnable as a
    single unit. The MCP plan's "base + capability note" framing is
    spec-level prose, not an implementation directive. When two
    profiles share a base, the implementer MAY define a private
    `@base` module attribute and concatenate at compile time, but the
    public surface is one string per profile.

12. **`render_success/2` and `render_error/3` opts contract.**

    `render_success(lisp_step, opts \\ [])` — keyword list. Preserves
    the existing v1 success payload exactly: `status`, optional
    `result`, `prints`, `feedback`, `memory.changed`,
    `memory.stored_keys`, `memory.truncated`, top-level `truncated`.
    Recognized opts:
    - `validated:` — JSON value, included as `"validated"` field. MCP
      v1 only emits this; in-process surfaces never set it.

    `render_error(reason, message, opts \\ [])` — keyword list.
    Recognized opts:
    - `result:` — only meaningful for `reason: :fail`; encodes as the
      `"result"` field. Ignored for any other reason.
    - `feedback:` — string. Defaults to `message` when not provided.

    **Unknown opts: ignored, not rejected.** Easier call sites; future
    additions are non-breaking. Tests assert the recognized opts work;
    they do NOT assert that unknown opts raise.

13. **Cache-key migration is a deliberate behavior improvement.**
    `KeyNormalizer.canonical_cache_key/2` intentionally widens
    equivalence classes vs today's PTC-Lisp keying (atom/string keys
    converge, map ordering stabilizes, integer-equal floats and
    integers converge). The migration policy: **preserve value
    semantics for ordinary callers, NOT preserve old cache-miss
    quirks.** If existing PTC-Lisp tests depend on old miss behavior
    (e.g., `1` and `1.0` previously produced separate cache entries),
    those tests MUST be updated as part of Tier 1b. Document in the
    Tier 1b PR description as a deliberate cache-compatibility
    migration. Add a CHANGELOG/notes entry.

14. **`cache_hint` renderer: reuse `PtcRunner.Lisp.Formatter.format/1`.**
    Do NOT hand-roll string interpolation for nested args. The
    `cache_hint` field's args fragment (e.g., `{:query "error code 42"}`)
    MUST be produced by the existing
    `PtcRunner.Lisp.Formatter.format/1` (or a thin helper that calls
    it) so escaping for strings, nested maps, vectors, and keywords is
    consistent with the rest of the runtime. Tests MUST cover:
    - simple string args
    - nested maps
    - strings containing double quotes (escape correctly)
    - lists/vectors as arg values
    - keyword keys vs string keys (canonical form pinned)

15. **`tool_cache` initialization site: TextMode combined-mode setup,
    not `Loop.State` defaults.** Keep `Loop.State`'s default
    `tool_cache: nil` unchanged. In the combined-mode entry path
    inside `Loop.TextMode` (the same branch that registers
    `lisp_eval`), set `state = %{state | tool_cache:
    state.tool_cache || %{}}` before the loop body runs. Pure
    `output: :text` paths MUST NOT touch `tool_cache`. The Tier 2b
    regression test asserts pure-text leaves it `nil`.

16. **`expose:` default backfill: missing field accepted, defaulted
    per mode.** Validator MUST accept tools without an explicit
    `expose:` field and apply the per-mode default from "Tool Exposure
    Policy." No backfill required in existing fixtures or test data.
    No deprecation warning for missing `expose:` — it's the documented
    default behavior.

17. **`expose: :both, cache: false` is legal.** Native calls return
    the tool's actual result (no metadata preview). PTC-Lisp programs
    can call `(tool/name ...)`, but each call re-executes the tool
    function — there is no shared cache. Validator accepts this
    combination. Document in Edge Cases. Add a test pinning the
    no-cache-reuse behavior.

18. **`ptc_reference: :full` body text: struck.** All prose in the
    body of this plan describing `:full` as a valid v1 value is
    superseded by Addendum #1. Implementers reading the body MUST
    treat the `:full` references as deferred. The body has been
    annotated; if any prose still appears that contradicts this,
    Addendum #1 wins.

19. **Compact reference card: included even when zero PTC-callable
    tools exist.** Combined mode appends the compact card whenever
    `output: :text, ptc_transport: :tool_call, ptc_reference:
    :compact` regardless of how many tools are exposed `:both` or
    `:ptc_lisp`. `lisp_eval` is useful for pure deterministic
    computation even with no app-tool inventory inside programs;
    omitting the card produces agents that don't know how to use it.

## Addendum 3 (workflow + final clarifications, 2026-05-06)

Locks the remaining ambiguities before implementation begins. When a
section below conflicts with the body of the plan, this addendum wins.

20. **Workflow: direct commits to `main`, no PRs.** Every tier lands as
    one or more commits directly on `main`. Each commit message MUST
    reference the Implementation Contract entries it satisfies and the
    "Tests To Require Before Enabling The Validator" entries it covers.
    Run `mix precommit` before each commit. Where the body of this plan
    or the MCP plan says "PR" or "PR description," read it as "commit"
    or "commit message" — the substance (tracking which contract entries
    the change satisfies) is what matters, not the GitHub surface.

21. **Codex review runs in the main agent only.** Engineer subagents
    MUST NOT invoke `/codex review` or `/codex challenge`. The body
    text's "Codex review checkpoint (strongly recommended)" notes
    (Tier 0, Tier 1b, Tier 3c, Tier 3e) are instructions for the main
    agent. After a tier lands, the main agent runs the recommended
    Codex review before proceeding to the next tier. This supersedes
    Addendum #8's "flag in PR description" framing.

22. **`cache:` field is already in place.** Verified at
    `lib/ptc_runner/tool.ex:66-101` and `tool.ex:201,210,234`: the
    `cache:` boolean option is parsed, validated, defaults `false`,
    and persists on the `Tool` struct. Combined-mode tier work does
    NOT need to introduce or rewire this field — it just consults
    `tool.cache` and adds the new `expose:` / `native_result:`
    metadata alongside it. Validator additions in Tier 1a are purely
    additive.

23. **PTC cache migration target: one line.** The existing PTC-Lisp
    cache key construction lives at `lib/ptc_runner/lisp/eval.ex:833`:
    `cache_key = {tool_name, args_map}`. Tier 1b's migration replaces
    that single line with a call to
    `KeyNormalizer.canonical_cache_key/2`. The `args_map` at that call
    site is already a PTC-Lisp-evaluated Elixir map (string-keyed after
    PTC normalization); `canonical_cache_key/2` consumes it directly.
    No other call site in `eval.ex` constructs cache keys.

24. **Tier 0 regression baseline already exists.** No new golden
    snapshots required. The byte-for-byte invariant on existing v1 PTC
    `:tool_call` behavior is enforced by the pre-existing tests in
    `test/ptc_runner/sub_agent/loop/ptc_tool_call_test.exs` and
    `test/ptc_runner/sub_agent/loop/ptc_tool_call_runtime_test.exs`.
    Tier 0 DoD: those files pass unchanged after the
    `PtcToolProtocol` extraction. New tests added by Tier 0 cover the
    extracted module's own surface (substring pins per profile,
    every `error_reason()` member rendered, `(fail v)` `result` field
    shape) — they MUST NOT modify the existing `ptc_tool_call_*` files.

25. **`:args_error` semantics.** Defined in the MCP plan as: "Tool
    args malformed (missing `program`, non-string, wrong shape,
    oversized)." MCP v1 is the only surface that emits this in v1; the
    in-process surfaces (`:in_process_with_app_tools`,
    `:in_process_text_mode`) never construct it. It MUST be in the
    shared `error_reason()` union and `render_error/3` MUST handle it
    (substring-pinned test required), but no Tier 2/3 code path emits
    it.

26. **`cache_hint` formatter helper: explicit AST conversion.**
    Addendum #14 says reuse `PtcRunner.Lisp.Formatter.format/1` for the
    `cache_hint` args fragment. `Formatter.format/1` consumes PTC-Lisp
    AST tagged tuples (`{:string, s}`, `{:map, pairs}`,
    `{:keyword, k}`, `{:vector, elems}`, etc.), not raw Elixir values.
    The thin helper Addendum #14 references performs this conversion.
    Pinned conversion rules (Tier 2b) — apply recursively to the
    canonical args map produced by `KeyNormalizer.canonical_cache_key/2`
    (after the `{tool_name, args}` tuple is unwrapped):

    | Input | AST output |
    |---|---|
    | string key in a map | `{:keyword, String.to_atom(key)}` (use `String.to_existing_atom` is unsafe; use `:erlang.binary_to_atom/2` is OK because keys originate from canonical args, but for v1 simplicity use plain `String.to_atom/1` — keys are bounded by validated tool signatures) |
    | binary value | `{:string, value}` |
    | integer / float / boolean / nil | passthrough (Formatter handles directly) |
    | list value | `{:vector, [<recursed elems>]}` |
    | nested map | `{:map, [{<keyword key>, <recursed value>}, ...]}` (preserve canonical key order, which is sorted-by-string-key per `canonical_cache_key/2`) |
    | tuple value | `{:vector, [<recursed elems>]}` (tuples present from PTC-Lisp paths flatten to vector form for display) |

    The output of the helper is then wrapped: the entire args fragment
    rendered as `{:map, [...]}` so `Formatter.format/1` produces
    `{:keyword "value" ...}` Clojure-style map output. Tests pin: simple
    string args, nested maps, strings with embedded double quotes, lists
    as values, integer-equal floats (must format as integers because
    `canonical_cache_key/2` already collapsed them).

27. **Spawn shape.** Tier 0 lands first (single Engineer). Tiers 1a and
    1b run in parallel (two Engineers, separate worktrees recommended
    to avoid `mix.lock` / formatter churn collisions). Tiers 2a → 2b
    → 3a → 3b → 3c → 3d → 3e are strictly sequential — one Engineer
    each, one tier per spawn. Tier 4 (transcript replay + docs +
    benchmark) can split into parallel Engineers (test, docs, bench).
    Main agent runs Codex review between tiers per Addendum #21.

## Summary

Explore support for `output: :text` together with `ptc_transport: :tool_call`.
In this mode, the agent remains a text/chat agent by default, but the
provider also receives the internal `lisp_eval` native tool. The
LLM can answer directly for simple turns, call ordinary native app tools
for simple lookups, or escalate to PTC-Lisp when it needs deterministic
computation, filtering, joins, parallelism, or multi-tool orchestration.

## Motivation

One of PtcRunner's original value propositions is handling tool calls that
return too much data to safely feed back into the LLM context. PTC-Lisp
can keep the raw data inside the runtime and let the model write
deterministic programs that filter, aggregate, or inspect it.

Text-mode agents are ergonomic for chat applications, but native tool
calling pushes tool result content directly into the conversation. That
is fine for small lookup tools, but weak for large result sets.

The desired flow:

1. The LLM starts in normal text mode.
2. It calls a native app tool such as `search_logs`.
3. PtcRunner returns a compact preview to the LLM and retains the full
   result in runtime state.
4. If the preview is enough, the LLM answers directly.
5. If the full data needs processing, the LLM calls `lisp_eval`.
6. The PTC-Lisp program calls the same app tool with the same args and
   receives the cached full result without re-running the tool.

This makes PTC-Lisp an opt-in deterministic compute affordance inside a
chat-shaped text agent.

## Non-Goals

- Do not change the current v1 behavior until the runtime is wired. The
  validator should keep rejecting this combination for now.
- Do not support `output: :text, ptc_transport: :content`. That remains
  nonsensical: text mode has no fenced PTC-Lisp parsing path.
- Do not fake provider transcripts by rewriting previous native app-tool
  calls into `lisp_eval` calls.
- Do not require a new handle namespace as the first design. Prefer
  shared tool cache semantics before adding a separate result-store API.
- Do not integrate `*1`/`*2`/`*3` with native tool results in v1.
  Reusing `turn_history` for native result summaries muddies an existing
  semantic.
- **Do not introduce cross-call chat-state threading in v1.** Combined-mode
  v1 lands for `SubAgent.run/2` only. `chat/3` continues to use the
  existing 4-tuple shape; cross-call `tool_cache` / `journal` /
  `turn_history` threading is fully deferred to a separate plan. State
  threading inside a single `SubAgent.run/2` invocation is supported;
  state across `chat/3` turns is not.
- Do not flip any defaults. This would be opt-in.
- Do not change pure `output: :text` behavior. Combined-mode mechanics
  (preview-and-cache, exposure filtering, multi-call rule, ...) apply
  **only** when `ptc_transport: :tool_call` is set with `output: :text`.

## File Map For Implementers

New modules and where they live. Existing modules listed for context
where they're touched.

| Concern | File |
|---|---|
| Shared protocol module (Tier 0) | `lib/ptc_runner/ptc_tool_protocol.ex` |
| Cache key canonicalization (Tier 1b) | extend `lib/ptc_runner/sub_agent/key_normalizer.ex` |
| Tool metadata validation (Tier 1a) | extend `lib/ptc_runner/tool.ex` and the `SubAgent.new/1` validator path |
| Agent-level `ptc_reference:` option (Tier 3a) | extend `lib/ptc_runner/sub_agent/definition.ex` (typespec + default), `lib/ptc_runner/sub_agent/validator.ex` (accept-list validation), and `SubAgent.new/1` `@doc` |
| Combined-mode TextMode wiring (Tier 2, 3) | extend `lib/ptc_runner/sub_agent/loop/text_mode.ex` |
| Combined-mode system-prompt assembly (Tier 3a) | extend `lib/ptc_runner/sub_agent/system_prompt.ex` — append the compact reference card from inside the existing tool-calling-system prompt path (the same path that produces today's `ptc_transport: :tool_call` system prompt) when `output: :text, ptc_transport: :tool_call`. Do not introduce a new top-level prompt module. |
| Combined-mode loop state (already present) | `lib/ptc_runner/sub_agent/loop/state.ex` (no new fields needed; combined-mode initializes `tool_cache: %{}` instead of `nil`) |
| Existing PTC cache path migration (Tier 1b) | `lib/ptc_runner/lisp/eval.ex` |
| Compact PTC-Lisp reference card | new file `priv/prompts/ptc_text_mode_compact_reference.md`; loaded at compile time via the same `@external_resource` / module-attribute pattern used for existing prompts in `priv/prompts/`. Recompile after changes |
| Test files (Tier 0) | `test/ptc_runner/ptc_tool_protocol_test.exs` (golden + substring-pin tests) |
| Test files (Tier 1b) | `test/ptc_runner/sub_agent/key_normalizer_canonical_test.exs` |
| Test files (Tier 2, 3) | extend `test/ptc_runner/sub_agent/loop/text_mode_test.exs`; new `test/ptc_runner/sub_agent/loop/text_mode_combined_test.exs` for combined-mode-specific cases |

Models for new code:
- For Tier 0 extraction, `lib/ptc_runner/sub_agent/loop/ptc_tool_call.ex`
  is the source of the description, success/error rendering, and the
  shared error reasons. Move; do not duplicate.
- For Tier 3 multi-call enforcement, the existing TextMode unknown-tool
  handling in `text_mode.ex` is the closest model.

## Prerequisite: Shared Protocol Module

The wire-format pieces today live scattered inside v1 internals
(`Loop.PtcToolCall.tool_description/0`, `Loop.PtcToolCall`'s private
success/error renderers, `TurnFeedback.execution_feedback/3`,
`JsonHandler.atomize_value/2` / `validate_return/2`).

> **Scope of the prerequisite.** The shared module
> `PtcRunner.PtcToolProtocol` is spec'd in `ptc-runner-mcp-server.md`
> because that plan was written first and owns the protocol surface.
> **Only the extraction itself is a prerequisite for this plan**, not
> the rest of the MCP server work. The MCP server feature and this
> text-mode feature are independent of each other; either can ship
> without the other once the shared module exists.
>
> **Tier 0 scope expansion.** The extraction PR MUST define all three
> capability profiles up front — `:in_process_with_app_tools` (used by
> v1 PTC `:tool_call`), `:in_process_text_mode` (used by this plan),
> `:mcp_no_tools` (used by the MCP plan) — and the **full
> `error_reason()` union** that any of the three plans will need
> (parse, runtime, timeout, memory, fail, plus reasons named in MCP
> plan). Doing it once avoids two rounds of "extend the shared module"
> churn when subsequent features land. Profile strings not yet
> consumed still get substring-pinning tests so future plans can rely
> on stable wording.
>
> ### Coupling Points With The MCP Plan
>
> Even after extraction, the two plans share four surfaces. Implementers
> for either plan MUST respect these:
>
> 1. **Profile-string convention.** If a future change wants to switch
>    from plain strings to a structured representation, all three
>    profiles change together. Document the chosen representation in
>    `PtcToolProtocol`'s `@moduledoc` so neither plan re-invents it.
> 2. **`error_reason()` is a closed union.** Adding a new reason
>    requires updating the typespec and `render_error/3`'s reason
>    handling in lockstep. Renderer MUST handle every union member
>    without crashing.
> 3. **Renderer signatures are keyword-driven.** `render_success/2` and
>    `render_error/3` take a keyword/options map for any non-essential
>    parameter so additions are non-breaking. Hard-coded positional
>    parameters are forbidden after Tier 0.
> 4. **`tool_description/1` carries capability statements only.**
>    Cache-reuse guidance, prompt cards, and other workflow guidance
>    live in their respective plan-specific surfaces (system prompt,
>    `cache_hint`, MCP server documentation). MCP plan must respect
>    this rule symmetrically.

This plan and the sibling `ptc-runner-mcp-server.md` plan both depend on
a new public module `PtcRunner.PtcToolProtocol` that owns:

- `tool_description(profile)` — canonical description, parameterized by
  capability profile (`:in_process_with_app_tools`,
  `:in_process_text_mode`, `:mcp_no_tools`).
- `render_success/2` and `render_error/3` — the shared response contract
  renderers.
- The shared `error_reason()` enum.
- Re-exports for `Lisp.run/2`, `Signature.parse/1`, etc., where call
  sites are awkward.

The full module spec lives in `ptc-runner-mcp-server.md`'s "Shared
Protocol Module" section. **Land that extraction as a standalone PR
before any phase below begins.** Existing v1 behavior must remain
byte-for-byte unchanged after the refactor.

This plan's text-mode work uses
`PtcToolProtocol.tool_description(:in_process_text_mode)` for the
canonical description and `render_success/2` / `render_error/3` for the
shared response shape. Do not reach into `Loop.PtcToolCall`,
`TurnFeedback`, or `JsonHandler` internals from `Loop.TextMode`.

**Source-of-truth for profile text.** All capability-profile description
strings — including `:in_process_text_mode` — live in
`PtcToolProtocol.tool_description/1`. The `:in_process_text_mode` profile
states the `:both`-tool callability rule and the
`lisp_eval`-exclusive-in-its-turn rule. **Cache-reuse guidance
does NOT live in `tool_description/1`.** It lives in two places: (a) the
compact PTC-Lisp reference card in the system prompt (see "System
Prompt"), and (b) the `cache_hint` field inside the native preview
payload (see "Native Tool Result Preview"). Implementers MUST NOT add a
third copy.

## Proposed Shape

```elixir
agent =
  SubAgent.new(
    prompt: "You are a support assistant.",
    output: :text,
    ptc_transport: :tool_call,
    tools: tools,
    max_turns: 6
  )
```

The provider-native `tools` field includes:

- app tools with `expose: :native` or `expose: :both`
- the internal `lisp_eval` tool

PTC-Lisp programs executed through `lisp_eval` see:

- app tools with `expose: :ptc_lisp` or `expose: :both`
- `memory`, `journal`, `tool_cache`, and `turn_history` for the current
  `SubAgent.run/2` invocation (not across `chat/3` turns; see Non-Goals)

### `turn_history` Semantics In Combined Mode

`turn_history` carries `*1`/`*2`/`*3` referenceable values. Combined
mode pins **v1 PTC `:tool_call` behavior verbatim**: only successful
non-terminal program executions advance history. Concretely:

- Initial value is `state.turn_history` (normally `[]`).
- A successful `lisp_eval` program result that **does not call
  `(return v)` or `(fail v)`** advances `turn_history` (the program's
  final expression value is pushed). This matches v1 PTC's
  `Loop.PtcToolCall.continue_with_intermediate/7` semantics.
- `(return v)` is **terminal** and does **not** advance `turn_history`.
  Combined mode changes `(return v)` from "run-final answer" to
  "tool result followed by an LLM text turn," but it remains terminal
  for history-advance purposes — `v` is not a `*1` candidate.
- `(fail v)` is **terminal** and does **not** advance `turn_history`.
- Native app-tool calls **never** advance `turn_history`. Consistent
  with Non-Goals: native results do not feed `*1`/`*2`/`*3` in v1.
- Direct LLM text turns **never** advance `turn_history`.
- Parse errors, runtime errors, validation errors (signature mismatch
  on a `lisp_eval` return), budget errors, and protocol errors
  (`multiple_tool_calls`, `mixed_with_lisp_eval`, `unknown_tool`)
  **never** advance `turn_history`.

**Why pin `(return v)` as non-advancing.** Combined mode reframes
`(return v)` as a tool result, which could plausibly look like a
non-terminal program result that *should* be a `*1` candidate. It is
not. The terminal semantic — `(return v)` ends program execution — is
the load-bearing property; whether the LLM gets another turn after the
tool result is orthogonal. Treating `(return v)` as non-advancing
preserves a single mental model across `:ptc_lisp` and `:text`
combined surfaces.

## Tool Exposure Policy

Text mode and PTC-Lisp mode currently make different assumptions:

- `output: :text`: app tools are provider-native tools.
- `output: :ptc_lisp`: app tools are callable from PTC-Lisp via
  `(tool/name ...)`.
- `output: :ptc_lisp, ptc_transport: :tool_call`: provider-native layer
  exposes only `lisp_eval`; app tools remain inside PTC-Lisp.

The combined text mode needs explicit exposure policy per tool.

```elixir
tools: %{
  "search_logs" =>
    {&search_logs/1,
     signature: "(query :string) -> [:any]",
     description: "Search log events.",
     expose: :both,
     cache: true,
     native_result: [preview: :metadata]}
}
```

| Value | Meaning |
|---|---|
| `:native` | Expose only as a provider-native app tool. |
| `:ptc_lisp` | Expose only inside PTC-Lisp as `(tool/name ...)`. |
| `:both` | Expose in both layers. |

Default `expose:` per mode:

- `output: :text` without `ptc_transport: :tool_call`: default `:native`.
- `output: :ptc_lisp`: default `:ptc_lisp`.
- `output: :text, ptc_transport: :tool_call` (combined mode): **default
  `:native`**, `:both` is per-tool opt-in.

**Intentional gotcha — combined mode requires explicit PTC opt-in.** An
agent that opts into combined mode but tags zero tools as `:both` or
`:ptc_lisp` gets a working `lisp_eval` that has **no app tools
visible inside programs**. Programs can still compute, transform passed
data, and use `memory` / `journal`, but `(tool/foo ...)` calls will be
rejected at parse time. This is by design: combined mode forces
deliberate exposure choices rather than auto-promoting every tool.
Document this prominently in user-facing docs (Tier 4) so users don't
configure combined mode and wonder why their programs can't see tools.

## Tool Metadata Contract

The combined mode introduces three tool-metadata fields beyond what v1
agents accept. All three are validated at agent construction.

### `expose:`

```
type: :native | :ptc_lisp | :both
default: see "Tool Exposure Policy" above (mode-dependent)
validation: must be one of the three atoms; ArgumentError otherwise
```

### Reuses existing `cache:` field

The combined mode does **not** introduce a new `cacheable:` field.
Native preview-and-cache seeding piggybacks on the **existing** PTC-Lisp
`cache:` tool option (boolean, default `false`). Setting `cache: true` on
a tool means: "this tool's results are safe to cache by `(tool_name,
canonical_args)`." The semantic is surface-invariant — true regardless
of whether native or PTC-Lisp is doing the caching. Combined mode just
adds: the cache is shared across the two layers.

This avoids a `:cache` vs `:cacheable` divergence where native calls
seed under one flag while PTC-Lisp checks the other and misses.

`native_result:` (below) requires both `expose: :both` and `cache: true`
to be valid.

### `native_result:`

```
type: keyword list | nil
default: nil  (interpreted as "metadata-only preview")
validation: rejected at agent construction unless expose: :both AND
            cache: true; ArgumentError naming both keys

fields:
  preview: :metadata | :rows | (full_result :: any -> map)
    default: :metadata
    validation: must be :metadata, :rows, or a 1-arity function;
                ArgumentError otherwise

  limit: pos_integer
    default: 20
    validation: must be a positive integer; consulted only when
                preview: :rows
```

**Custom preview function contract:**

- The function receives **only `full_result`** (not `args`, not `tool_name`).
  Authors who need additional context should construct closures that
  capture it.
- The return value MUST be a map that `Jason.encode!/1` accepts. Atom
  values are encoded as strings; if a tool author needs to round-trip
  atom semantics, encode them as strings explicitly or let signature
  coercion handle them downstream. Arbitrary atom values that Jason
  rejects (most non-standard atoms) trigger the fallback below.
- If the function raises, returns a non-map, or returns a value that
  fails `Jason.encode!/1`, the runtime falls back to the
  metadata-only preview and logs a warning at agent run time via
  `Logger.warning/1` (pinned for v1; telemetry surface deferred). The
  warning message MUST include the tool name and the failure category
  (`raised`, `non_map`, `non_encodable`). This is documented behavior,
  not undefined; tests assert via `ExUnit.CaptureLog`.

### Exposure Filtering — Implementation Rule

```
At LLM request build time:
  native_request_tools = tools where expose ∈ [:native, :both]
  if combined mode: native_request_tools ++ [lisp_eval]

At PTC-Lisp inventory build time (system prompt + Lisp analyzer):
  ptc_lisp_inventory = tools where expose ∈ [:ptc_lisp, :both]

If a PTC-Lisp program calls (tool/foo ...) where foo has expose: :native,
the existing analyzer rejects at parse time:
  "tool foo is not available inside lisp_eval (expose: :native);
  set expose: :both to make it callable from programs."
```

Parse-time, not runtime. The existing analyzer already validates tool
calls; this is a filter on the inventory it sees.

## Final-Output Semantics

`(return v)`, `(fail v)`, and normal final expressions inside
`lisp_eval` all produce **tool results**, not run-final answers.
The LLM sees the tool result and decides what to do next. The agent's
final answer is always its final text response, possibly coerced by
signature.

Matrix:

| `output` | `signature` | Final answer source |
|---|---|---|
| `:text` | none | LLM's final text response (raw) |
| `:text` | `:string` / `:any` | LLM's final text response (raw) |
| `:text` | `{:map, ...}` / `{:list, ...}` | LLM's final text response, parsed as JSON, validated via `JsonHandler.validate_return/2` |
| `:text` | `:int` / `:float` / `:bool` / `:datetime` | LLM's final text response, parsed/coerced via `JsonHandler.atomize_value/2` |

**`(return v)` does not short-circuit the run.** The program terminates
with `v` as its final expression value, the runtime emits a success
tool-result JSON, and the LLM gets one more turn to respond **if turn
budget remains** (see "Turn Budget Interaction" below). This is
identical to how every other tool call works in `:text` mode.

**`(fail v)` does not abort the run.** The program terminates with an
error tool-result JSON (`reason: "fail"`, `result` field present). The
LLM gets one more turn to react **if turn budget remains** — produce a
text apology to the user, retry with different args, etc.

**Why not short-circuit on `(return v)` matching the signature?**

- Simplest mental model: `lisp_eval` is a tool like any other
  tool. Tools return data; the LLM decides what to do with it.
- Matches every other TextMode tool's semantics. No special case in the
  loop.
- Users who want short-circuit semantics already have
  `output: :ptc_lisp, ptc_transport: :tool_call`. That mode exists for
  exactly this purpose.
- If real usage shows short-circuit is high-value, add it later as
  opt-in. Don't bake it into v1's contract.

### Turn Budget Interaction

`lisp_eval` consumes a turn like any other tool call. The
"LLM gets one more turn to respond" guarantee above is **conditional on
turn budget remaining** — it is not a reserved slot.

Concrete rules:

- If `max_turns` is reached after a `lisp_eval` call (so the
  paired `role: :tool` message is the last thing the loop emits), the
  agent terminates via TextMode's existing `max_turns_exceeded` error
  path. No final text turn happens. `step.return` carries whatever the
  existing TextMode max-turns handling produces.
- The universal pairing rule MUST still hold: the `tool_call_id` from
  the `lisp_eval` invocation MUST be paired with a `role: :tool`
  message before termination, even when the loop is terminating due to
  budget exhaustion.
- Users who need program execution followed by a text wrap-up MUST
  configure `max_turns` with at least one slot of headroom beyond their
  worst-case program-call count. Document this in user-facing docs as
  guidance, not as a runtime auto-reservation.

**Why not auto-reserve a final turn?** Auto-reservation is a hidden
budget tax that surprises users who set `max_turns: 3` and observe
only 2 LLM-driving turns. Better to fail loudly with the existing
max-turns path and let users configure budgets explicitly.

## Shared Tool Cache As The Primary Bridge

The preferred bridge between native app-tool calls and PTC-Lisp app-tool
calls is the existing tool cache, not a new result-store namespace.

When a tool with `expose: :both, cache: true` is called:

1. Native tool call:

   ```json
   {"name": "search_logs", "args": {"query": "error code 42"}}
   ```

2. Runtime executes `search_logs/1`, stores the full result in
   `tool_cache` under a canonical cache key, and returns only a preview
   to the LLM.

3. Later PTC-Lisp program:

   ```clojure
   (def rows (tool/search_logs {:query "error code 42"}))
   (return {:count (count rows)})
   ```

4. PTC-Lisp hits the same cache key and receives the full result without
   re-running `search_logs/1`.

### Canonical Cache Key — Implementation Rule

For native calls and PTC-Lisp calls to share cache entries, the cache
key MUST be deterministic across both layers regardless of how the args
arrived.

Add a new public function on `KeyNormalizer`:

```elixir
@spec canonical_cache_key(tool_name :: String.t(), args :: map()) :: term()
def canonical_cache_key(tool_name, args)
```

Rules (apply recursively to every value in `args`):

1. **Map keys**: convert all to strings (`:foo` → `"foo"`).
2. **Maps**: sort entries by key at every nesting level.
3. **Numbers**: integer-equal floats (`1.0`, `2.0`) collapse to integers
   (`1`, `2`). Non-integer floats stay floats.
4. **Lists**: recurse into elements; preserve order (lists are ordered).
5. **Tuples**: recurse into elements; preserve order. (Tuples shouldn't
   normally appear in JSON-decoded args, but PTC-Lisp call paths may
   produce them.)
6. **Strings, atoms, booleans, nil**: unchanged.

Return value: `{tool_name, normalized_args}` tuple suitable for use as a
map key.

**Sibling module is overkill**; extending `KeyNormalizer` keeps related
concerns together. Add a dedicated test file with edge cases: nested
maps, mixed-key types, deeply nested lists, integer/float boundary
values, empty maps, single-key maps.

## Native Tool Result Preview

When a tool is `expose: :both` with `cache: true`, the runtime can
preview the native result and retain the full result in `tool_cache`.

**Preview content is a JSON-encodable Elixir map**, encoded via
`Jason.encode!/1` **inside `Loop.TextMode`** at the point where it
assembles the tool-result content for the `role: :tool` message — same
boundary where existing TextMode tool results are JSON-encoded today.
Do not push this encoding into the LLM adapter or `PtcToolProtocol`.
PTC-Lisp result rendering (the `result` and `prints` fields in the
`lisp_eval` tool-result JSON) stays as EDN-rendered preview
strings produced by `PtcToolProtocol` — that's a different surface
with different ergonomic needs.

**Default preview is metadata-only, not row values.** Safe-by-default
for compliance-sensitive workloads:

```json
{
  "status": "ok",
  "result_count": 1842,
  "schema": {
    "type": "array",
    "items": {
      "type": "object",
      "properties": {
        "id": "integer",
        "message": "string"
      }
    }
  },
  "sample_keys": ["id", "message"],
  "full_result_cached": true,
  "cache_hint": "Call lisp_eval and then call (tool/search_logs {:query \"error code 42\"}) to process the full cached result."
}
```

`schema` is the JSON-Schema-ish canonical shape (rules below). `sample_keys`
is a flat sorted list of the same top-level keys, retained as a cheap
LLM-readable companion. Tests pin both fields exactly.

No actual row values appear in the preview unless the tool author opts
in explicitly via `preview: :rows` or a custom preview function. See
"Tool Metadata Contract" above for the exact `native_result` field
shape and the custom preview function contract.

**Scope.** Preview-and-cache only applies to `expose: :both` tools with
`cache: true`. A `:native`-only tool (with no escalation path)
returns its actual result with whatever truncation the tool already
does itself; no preview indirection, no cache write.

### Default Metadata Preview — Inference Rules

The default preview (when `native_result:` is unset, `nil`, or set with
`preview: :metadata`) is built from the tool's full result by these
rules. They run on the result returned by the tool function. None of
the rules recurse beyond one level — deeper inference belongs to a
custom preview function.

**Canonical contract.** `schema` is the JSON-Schema-ish nested shape —
always `{"type": ..., ...}` with `items`/`properties` nested as
appropriate. `sample_keys`, when present, is the sorted flat list of the
same top-level object keys. The two fields agree; `sample_keys` is a
readability companion, not an alternative encoding.

JSON Schema-ish type names: `"integer"`, `"number"`, `"string"`,
`"boolean"`, `"object"`, `"array"`, `"null"`.

| Result shape | `result_count` | `schema` | `sample_keys` |
|---|---|---|---|
| List of maps with consistent keys (`[%{"id" => 1, ...}, ...]`) | `length(result)` | `{"type": "array", "items": {"type": "object", "properties": <first-element keys → JSON types>}}` | sorted first-element keys |
| List of maps with mixed keys | `length(result)` | `{"type": "array", "items": {"type": "object"}}` (no `properties` — heterogeneous) | omitted |
| List of scalars (`[1, 2, 3]`) | `length(result)` | `{"type": "array", "items": {"type": "<inferred from first>"}}` (or `"any"` if mixed) | omitted |
| Empty list (`[]`) | `0` | `{"type": "array", "items": {}}` (empty list reveals nothing about item type) | omitted |
| Map (`%{...}`) | omitted | `{"type": "object", "properties": <top-level keys → JSON types>}` | sorted top-level keys |
| Empty map (`%{}`) | omitted | `{"type": "object"}` | `[]` |
| Scalar (string / number / boolean / nil) | omitted | `{"type": "<scalar kind>"}` | omitted |

**Notes**:

- For "consistent keys" detection, compare the first element's key set
  to a sample of subsequent elements (e.g., the next 4); if they all
  match, treat as consistent. This is a heuristic; deep verification is
  not required.
- For schemas with very wide first elements (e.g., a map with 50 keys),
  truncate `properties` and `sample_keys` at 20 entries. The truncation
  flag MUST live **inside the schema object** as `"truncated": true`
  (i.e. `schema.truncated`), not at the preview top level. The preview
  top level already has its own `truncated` semantics for other fields.
  Tests pin the placement.
- `length/1` is exact and O(n) on the full result list. Accepted under
  v1's "no resource limits" policy ("Resource Policy (v1)"). If a tool
  returns a truly enormous list, the count is honest at the cost of a
  full traversal; configurable bounds belong in "Future Resource Limits."
- Type inference covers the common Elixir-from-JSON shapes; PTC-Lisp
  internals like `Var` or atoms-as-tags should not appear in native
  tool results (those tools wouldn't be JSON-encodable). If a custom
  preview function returns one anyway, the runtime falls back to
  metadata-only as documented in the custom preview function contract.

The whole table is implementation guidance for the default path. Tool
authors who want richer or domain-specific previews should configure
`preview: :rows` (with `limit:`) for verbatim rows or supply a custom
preview function.

## Multi-Call Rule

`lisp_eval` is exclusive in its assistant turn. Native app-tool
calls are otherwise multi-callable (matching existing TextMode
behavior). Precedence — first match wins. "Unknown" means a native
tool name the agent did not register; "valid" means it was registered
and `expose ∈ [:native, :both]` (or it is `lisp_eval` itself
in combined mode):

| # | Turn shape | Behavior | Reason(s) |
|---|---|---|---|
| 1 | Multiple `lisp_eval` calls (any other calls present or not) | Reject all; pair one error per `tool_call_id` | `multiple_tool_calls` |
| 2 | One `lisp_eval` + any other native call(s) (valid or unknown) | Reject all; pair one error per `tool_call_id` | `mixed_with_lisp_eval` |
| 3 | One `lisp_eval` (alone) | Execute the program | n/a |
| 4 | Native app-tool calls only — all valid, no `lisp_eval` | Execute all (existing TextMode behavior) | n/a |
| 5 | Native app-tool calls only — mix of valid and unknown, no `lisp_eval` | Execute valid calls; pair `unknown_tool` errors for each unknown call | `unknown_tool` (per unknown id) |
| 6 | Native app-tool calls only — all unknown, no `lisp_eval` | Pair `unknown_tool` errors for each | `unknown_tool` (per unknown id) |

**Reading the table.** Rows 1 and 2 are about `lisp_eval`
exclusivity and reject the entire turn. Rows 4–6 cover pure-native
turns where unknown handling is orthogonal to count: every unknown call
gets paired with an error, every valid call executes. Rows 4 and 6 are
limit cases of Row 5 (zero unknowns, zero valids respectively).

**Divergence from v1 PTC `:tool_call`:** v1 treats *any* multi-native-call
turn as multi-call rejection. Text mode is more permissive — Rows 4–6
allow valid native calls to execute even when an unknown call appears
alongside them. Document the divergence as intentional; it preserves
existing TextMode chat ergonomics.

### Protocol-Error JSON Shape

```json
{
  "status": "error",
  "reason": "multiple_tool_calls" | "mixed_with_lisp_eval" | "unknown_tool",
  "message": "<violation summary, e.g. 'exactly one lisp_eval call per assistant turn'>"
}
```

No `feedback` field on protocol errors — they're transport-level, not
execution errors, and there's no execution-feedback to render. This
diverges intentionally from R23 (which has `feedback`); R23 covers
execution errors. The protocol-error renderer lives in `Loop.TextMode`,
not in `PtcToolProtocol`.

### Budget Semantics

- `lisp_eval` does not consume `max_tool_calls`. (Parity with
  v1 R19.)
- Native app-tool calls do consume `max_tool_calls`. (Parity with
  today's TextMode.)
- Every assistant turn counts toward `max_turns`, including
  protocol-error recovery turns. (Parity with v1 R17a.)

## Loop Dispatch

The combined mode lives in `Loop.TextMode`. It does not reuse
`Loop.PtcToolCall.handle_response/3` directly; both modules consume the
shared `PtcRunner.PtcToolProtocol` instead.

Required runtime changes:

- TextMode request construction includes app native tools (filtered per
  `Exposure Filtering` rule) plus `lisp_eval`. The execution-tool's
  description is sourced from
  `PtcToolProtocol.tool_description(:in_process_text_mode)`.
- TextMode recognizes `lisp_eval` as an internal native tool.
- Native app-tool execution and PTC-Lisp `(tool/name ...)` execution
  share normalized cache keys via `KeyNormalizer.canonical_cache_key/2`.
- `lisp_eval` execution threads `memory`, `journal`,
  `tool_cache`, `child_steps`, and `turn_history` through `Lisp.run/2`.
  All four are scoped to the current `SubAgent.run/2` invocation only.
- Tool-result JSON for `lisp_eval` is rendered by
  `PtcToolProtocol.render_success/2` / `render_error/3` — same renderers
  v1 PTC `:tool_call` and the MCP server use. No parallel rendering
  path.
- Protocol-error rendering for `multiple_tool_calls`,
  `mixed_with_lisp_eval`, and `unknown_tool` lives in
  `Loop.TextMode` (transport concern, surface-specific).
- TextMode continues to allow normal native app-tool calls.
- Multi-call enforcement per the "Multi-Call Rule" section.

## System Prompt

Combined-mode prompts must add a **compact PTC-Lisp reference card capped
at ≤300 tokens**. Required contents:

- `(def name value)` — bind a name in this program
- `(tool/name {:key val})` — call an app tool from inside the program
- `(return value)` — produce the program's final value (terminates
  execution; produces a successful tool result for the LLM)
- `(println ...)` — debug output between turns
- One paragraph on the `full_result_cached: true` cache-reuse pattern,
  with one combined example showing native-call → escalate-to-PTC

**Tool-inventory rule (no double-listing).** Provider-native tool
schemas continue to live in the LLM request's `tools` field — that's
where the LLM looks up native call shapes. The compact reference card
does **NOT** duplicate native tool schemas. For `:both`-exposed tools,
the card lists each as a one-line PTC entry only — name plus
`(tool/name {...})` shape — so the LLM knows it's also callable from
inside `lisp_eval`. For `:ptc_lisp`-only tools, the card carries
the same one-line PTC entry (those tools are absent from native
`tools`, so the card is the only place they're advertised).

The `lisp_eval` tool's description (separate from the prompt
section above) comes from
`PtcToolProtocol.tool_description(:in_process_text_mode)`, which
carries the capability note: app tools exposed as `:both` are callable
as `(tool/name ...)` from inside the program; `lisp_eval` is
exclusive in its assistant turn.

**`ptc_reference:` option, pinned for v1:**

> **Addendum #1 supersedes the typespec below.** v1 accepts only
> `:compact`. The validator MUST reject `:full` with ArgumentError.
> The `:full` references in this section and the paragraph below are
> retained for historical context only; treat as deferred.

```
type: :compact   (v1 — :full deferred, see Addendum #1)
default: :compact (in combined mode); :compact in pure :ptc_lisp paths is
         not affected by this plan
location: agent-level option on SubAgent.new/1, stored on Definition
validation: must be :compact; ArgumentError on :full or any other value.
            Validated by validator.ex alongside other agent-level options,
            not by tool metadata validation.
```

**Hook point.** Combined-mode system prompts assemble in
`lib/ptc_runner/sub_agent/system_prompt.ex` along the existing
tool-calling-system path (the same path used today for
`ptc_transport: :tool_call` agents). Add a compile-time-loaded constant
for `priv/prompts/ptc_text_mode_compact_reference.md` and append it to
the assembled prompt when `output: :text, ptc_transport: :tool_call,
ptc_reference: :compact`. Do not duplicate native tool schemas in the
card (see "Tool-inventory rule" above).

`:compact` is the bounded reference card described above (≤300 tokens).
~~`:full` is the complete PTC-Lisp language reference, suitable for
power-user agents where prompt budget is not a concern.~~ — **Deferred
in v1 per Addendum #1.**

`false` (i.e. "don't include any PTC-Lisp reference at all") is **not**
a valid value in combined mode. The LLM needs at least the compact
reference to use `lisp_eval` correctly; omitting it produces
agents that misuse the tool. Users who don't want the prompt overhead
should not opt into combined mode.

## Resource Policy (v1)

Concrete v1 invariants for retained native results:

- Retained results live for the duration of one `SubAgent.run/2` call.
- **No cross-run persistence.** v1 doesn't support `chat/3` cross-call
  state, so `tool_cache` does not survive across `chat/3` turns. Users
  needing persistence within a long conversation must keep everything in
  one `SubAgent.run/2` invocation, or wait for a future `ChatState` API.
- **No eviction during a run.** Full results stay in `tool_cache` until
  the run terminates. No LRU, no size-based eviction in v1.
- **Memory risk documented.** Very large retained results consume
  runtime memory for the entire run. Mitigation guidance for users:
  filter eagerly inside `lisp_eval`, return only the projection
  the program needs, let the upstream's `full_result` get garbage-collected
  after the program returns.

Configurable resource limits (`tool_cache_limit`, per-tool
`max_cached_bytes`, eviction strategies, memory accounting that
includes `memory` / `journal` / `tool_cache` / retained child steps)
are deferred to follow-up work — see "Deferred From v1" below.

## Telemetry And Debugging

Trace output must keep the layers distinct:

- native app-tool calls
- internal native `lisp_eval` calls
- app-tool calls made from inside PTC-Lisp
- cached app-tool hits reused by PTC-Lisp after a native call

**Required field on every tool-call event in this mode:**

- `exposure_layer: :native | :ptc_lisp` — required, not optional. The
  entire diagnostic story for combined mode hinges on telling the two
  layers apart in logs and bench reports.

Other useful fields:

- `cached: true | false`
- `result_preview_truncated: true | false`
- `full_result_cached: true | false`
- `cache_key_hash`
- `retained_bytes`

Avoid overloading `tool_calls` without qualification in new modules and
docs.

## Edge Cases

- A tool with `cache: false` (the default) returns a huge native
  result. The runtime returns its actual result with whatever
  truncation the tool already does itself; no preview, no cache, no
  `full_result_cached` hint. Documented behavior — leaving `cache`
  unset (or explicitly `false`) opts out of the preview-and-cache
  machinery entirely.
- A tool with `expose: :both, cache: false` is legal (Addendum #17).
  Native calls return the tool's actual result with no metadata
  preview. PTC-Lisp programs can still call `(tool/name ...)`, but
  each call re-executes the tool function — there is no shared cache
  between layers. Test pins the no-cache-reuse behavior.
- The LLM calls `lisp_eval` and the program calls a tool with
  `expose: :native`. Rejected at parse time by the analyzer (see
  "Exposure Filtering"). Programs cannot reference `:native`-only tools.
- The LLM calls a tool natively, then PTC-Lisp calls it with
  semantically same but structurally different args (e.g., string vs
  atom keys). With `KeyNormalizer.canonical_cache_key/2`, this hits the
  cache. Tests must cover this explicitly.
- Native app-tool call fails after partially producing a large result.
  Do not cache partial results unless the tool explicitly returns a
  successful partial value. **"Successful partial value" is defined by
  `Tool`'s existing success/failure normalization: a raw return value
  or `{:ok, value}` is a success and seeds the cache; `{:error, _}` and
  raises are failures and MUST NOT seed the cache.**
- Compaction within a single `SubAgent.run/2` call must preserve
  provider-valid `tool_call_id` pairings (existing v1 behavior, exercised
  by the cleanup in commit `a33abe8`).

## End-to-End Transcript

Concrete combined-mode v1 flow against an `expose: :both, cache: true`
app tool plus `lisp_eval`. Used as the canonical reference for
implementers. Annotations in `;; comments` are this transcript's
author-side commentary, not part of the wire data.

```
;; Agent setup
SubAgent.new(
  prompt: "You are a support assistant.",
  output: :text,
  ptc_transport: :tool_call,
  tools: %{
    "search_logs" =>
      {&search_logs/1,
       signature: "(query :string) -> [:any]",
       description: "Search log events.",
       expose: :both,
       cache: true,
       native_result: [preview: :metadata]}
  },
  max_turns: 6
)

;; Turn 1 — User asks a question that needs log data
USER: "Tell me how many errors happened with code 42 last hour."

;; Turn 2 — LLM calls native search_logs
ASSISTANT (tool_calls): [
  {id: "call_1", name: "search_logs", args: {"query": "error code 42"}}
]

;; Runtime executes search_logs/1, gets 1842 rows.
;; Stores full result in tool_cache under canonical key
;; {"search_logs", %{"query" => "error code 42"}}.
;; Returns metadata preview to the LLM:

TOOL (tool_call_id: "call_1"): {
  "status": "ok",
  "result_count": 1842,
  "schema": {
    "type": "array",
    "items": {
      "type": "object",
      "properties": {
        "id": "integer",
        "timestamp": "string",
        "message": "string"
      }
    }
  },
  "sample_keys": ["id", "timestamp", "message"],
  "full_result_cached": true,
  "cache_hint": "Call lisp_eval and then call (tool/search_logs {:query \"error code 42\"}) to process the full cached result."
}

;; Turn 3 — LLM decides it needs to count, calls lisp_eval
ASSISTANT (tool_calls): [
  {id: "call_2",
   name: "lisp_eval",
   args: {"program": "(def rows (tool/search_logs {:query \"error code 42\"}))\n(return {:total (count rows)})"}}
]

;; Runtime hits canonical_cache_key match, reuses cached full_result,
;; runs the program. (return {:total 1842}) terminates with the value.
;; Tool-result JSON via PtcToolProtocol.render_success/2:

TOOL (tool_call_id: "call_2"): {
  "status": "ok",
  "result": "user=> {:total 1842}",
  "prints": [],
  "feedback": "user=> {:total 1842}\n\n;; rows = [...truncated...]",
  "memory": {
    "changed": {"rows": "[{...}]"},
    "stored_keys": ["rows"],
    "truncated": true
  },
  "truncated": true
}

;; Turn 4 — LLM responds in text. This is the final answer.
ASSISTANT (content): "There were 1842 errors with code 42 in the queried window."

;; Run terminates. step.return = "There were 1842 errors..."
;; (or coerced if a structured signature were set; here no signature → raw text).
```

Key invariants visible in this transcript:

- Native tool result preview is JSON-encodable map (R-required at
  request boundary), encoded via `Jason.encode!/1`.
- Cache key from native call equals cache key from PTC-Lisp call —
  proves canonical normalization is wired.
- `(return v)` produces a successful tool result, not a run-final
  answer. The LLM still gets Turn 4 to compose text.
- Metadata-only preview by default; full result lives in `tool_cache`
  and is only seen by the program.
- `exposure_layer: :native` for Turn 2's tool call;
  `exposure_layer: :ptc_lisp` for the `(tool/search_logs ...)` call
  inside the program.

## Implementation Contract

Normative statements consolidated for implementers. **MUST** = required
for v1 DoD. **SHOULD** = strong guidance, deviation requires explicit
justification.

### Tool Metadata

- The validator MUST reject `native_result:` when `expose:` is not
  `:both` or `cache:` is not `true`. ArgumentError naming both keys.
- The validator MUST reject any value of `expose:` other than `:native`,
  `:ptc_lisp`, `:both`. ArgumentError listing accepted values.
- The combined mode MUST NOT introduce a new `cacheable:` field. It
  reuses the existing `cache:` PTC-Lisp tool option as the single source
  of truth for "this tool's results are safe to cache by (tool_name,
  canonical_args)."
- The validator MUST reject any `native_result.preview:` other than
  `:metadata`, `:rows`, or a 1-arity function.
- A custom preview function MUST receive only `full_result`. If it
  raises or returns a non-map / non-`Jason.encode!`-able value, the
  runtime MUST fall back to metadata-only and SHOULD log a warning.

### Exposure Filtering

- The LLM request's `tools` field in combined mode MUST include exactly:
  `tools where expose ∈ [:native, :both]` plus `lisp_eval`.
- The PTC-Lisp inventory (system prompt + analyzer) MUST include
  exactly: `tools where expose ∈ [:ptc_lisp, :both]`.
- A PTC-Lisp program calling `(tool/foo ...)` where `foo` has
  `expose: :native` MUST be rejected at parse time with a clear error
  message.

### Final-Output Semantics

- `(return v)`, `(fail v)`, and normal final expressions MUST produce
  tool results, not run-final answers. The LLM gets one more turn to
  respond **if turn budget remains**; if `max_turns` is exhausted by the
  `lisp_eval` call, the loop terminates via TextMode's existing
  `max_turns_exceeded` path with the `tool_call_id` paired (see "Turn
  Budget Interaction").
- The agent's final answer in combined mode MUST come from the LLM's
  final text response, optionally coerced by signature per the matrix
  in "Final-Output Semantics."
- Signature coercion MUST use the existing
  `JsonHandler.atomize_value/2` and `validate_return/2` paths
  (re-exported through `PtcToolProtocol`).

### Cache Key

- `KeyNormalizer.canonical_cache_key/2` MUST produce the same key for
  semantically identical args regardless of whether they arrived from a
  native JSON-decoded call or from a PTC-Lisp `(tool/name ...)` call.
- Native tool execution in combined mode MUST seed the cache for
  `expose: :both, cache: true` tools.
- PTC-Lisp `(tool/name ...)` execution MUST consult the cache via the
  same canonical key before invoking the tool function.
- The **existing PTC-Lisp cache path in `Lisp.Eval`** MUST be migrated
  to use `canonical_cache_key/2`. Same-key behavior for all current
  PTC-only callers MUST be preserved (regression tests for the
  `output: :ptc_lisp` cache hits cover this). This is a single source
  of truth — combined mode does not introduce a parallel keying scheme.

### Multi-Call Rule

- The runtime MUST follow the precedence table in "Multi-Call Rule"
  exactly. Earlier rules win.
- Protocol-error rendering for `multiple_tool_calls`,
  `mixed_with_lisp_eval`, `unknown_tool` MUST live in
  `Loop.TextMode`, not in `PtcToolProtocol`.
- Every returned `tool_call_id` MUST be paired with a `role: :tool`
  message before the loop continues or terminates (universal pairing
  rule).

### Resource Policy

- Retained results MUST be scoped to a single `SubAgent.run/2` call.
- The runtime MUST NOT persist `tool_cache` across `chat/3` turns in
  v1.
- The runtime MUST NOT evict `tool_cache` entries during a run in v1.

### Telemetry

- Every tool-call telemetry event in combined mode MUST carry
  `exposure_layer: :native | :ptc_lisp`.

### System Prompt

- Combined-mode prompts MUST include a PTC-Lisp reference section
  per the `ptc_reference:` option.
- The validator MUST reject any value of `ptc_reference:` other than
  `:compact` or `:full`. `false` is not valid in combined mode.
- Default `ptc_reference:` in combined mode MUST be `:compact` and
  MUST stay within the ≤300-token budget defined in "System Prompt."

### Scope Discipline

- The validator MUST continue to reject
  `output: :text, ptc_transport: :content`.
- The validator MUST allow `output: :text, ptc_transport: :tool_call`
  only after Phase 3 runtime support lands. Until then it remains
  rejected.
- Phase 2 cache mechanics MUST NOT change behavior of pure
  `output: :text` agents (without `ptc_transport: :tool_call`). The
  cache only seeds via the new combined-mode preview-and-cache path
  when both `expose: :both` and `cache: true` are set, which requires
  combined mode to be useful.

## Future Resource Limits (Deferred)

The "Resource Policy (v1)" section above pins MVP invariants. The
following are deferred to follow-up work:

- `tool_cache_limit` or `retained_result_limit` (configurable cap).
- Per-tool `max_cached_bytes`.
- Eviction strategy for chat sessions (LRU, TTL, etc.).
- Memory accounting that includes `memory`, `journal`, `tool_cache`,
  and retained child steps.
- Behavior when the cached full result is evicted and PTC-Lisp calls
  the same tool again.

## Suggested Phases

Sized for a single Engineer subagent per task. Each task has a crisp
DoD and known dependencies. Tasks within a tier are independent;
tier boundaries are sequencing gates.

### Tier 0 — Prerequisite

**0. Extract `PtcRunner.PtcToolProtocol`.** **The actual implementation
PR for Tier 0 is owned by this plan's execution sequence** — Tier 0 ships
as the first PR on the text-mode track. The MCP plan is the *spec source*
for the module's surface (profile-string wording, error-reason enum,
renderer signatures), not the *implementation owner*. Whichever feature
plan reaches Tier 0 first lands the extraction; the other feature
consumes it.

Implementer instructions:
- Copy the three capability-profile description strings **verbatim**
  from `ptc-runner-mcp-server.md` § "Tool Description Capability
  Profiles" (the table at lines ~165–168 of that file). Substring tests
  MUST pin a stable substring per profile so future drift is caught.
- `tool_description/1` for `:in_process_with_app_tools`,
  `:in_process_text_mode`, `:mcp_no_tools`.
- `render_success/2` and `render_error/3` (covers `:fail`, parse,
  runtime, timeout, memory error reasons). **Tests for `(fail v)`
  rendering required as part of this task.**
- `error_reason()` typespec — full union per "Tier 0 scope expansion"
  note above. Concrete enumeration v1: `:parse_error`, `:runtime_error`,
  `:timeout`, `:memory_limit`, `:args_error`, `:fail`,
  `:validation_error`. **`:validation_error` MUST be in the enum even
  though no in-process surface emits it in v1** — MCP v1 is the only
  emitter today, but the shared enum stays consistent across all three
  surfaces. `render_error/3` MUST handle every member without crashing
  (substring-pinned tests required for each, including
  `:validation_error`).
- Re-exports as needed.
- Existing v1 PTC `:tool_call` behavior MUST be byte-for-byte
  unchanged after extraction (regression suite + golden tests).

**Codex review checkpoint (strongly recommended).** Run `/codex review`
on the extraction diff before opening the PR. The byte-for-byte
invariant is exactly the kind of subtle-regression surface Codex
challenge mode catches — defp→def visibility shifts, accidental
re-ordering of opts, lost capture in renderer formatting. Surface
anything Codex flags in the PR description.

### Tier 1 — Pure additions (parallelizable)

**1a. Tool metadata validation + exposure filtering helpers.**
- `expose:`, `native_result:` accepted in tool metadata.
- Validator per "Implementation Contract → Tool Metadata."
- Pure helper(s) for "tools where `expose ∈ X`" filtering.
- Default `expose:` per mode per "Tool Exposure Policy."
- Unit tests for validator + filter helpers. No runtime wiring yet.

**1b. `KeyNormalizer.canonical_cache_key/2` + PTC cache migration.**
- Add the function with rules in "Shared Tool Cache → Canonical Cache
  Key."
- **Migrate the existing PTC-Lisp cache path in `Lisp.Eval`** to use
  `canonical_cache_key/2`. Preserve same-key behavior for all current
  `output: :ptc_lisp` callers (regression test required).
- Dedicated test file with edge cases: nested maps, mixed-key types,
  deeply nested lists, integer/float boundary values, empty maps.

**Codex review checkpoint (strongly recommended).** Run
`/codex challenge` on `canonical_cache_key/2` — this primitive underpins
the entire native↔PTC-Lisp cache bridge, so every edge case Codex can
invent (charlist vs binary, integer-equal `Decimal`, NaN floats, atom
keys colliding with string keys at different depths, list-of-tuples
ambiguity) is worth surfacing before downstream tiers depend on it.

### Tier 2 — TextMode wiring (sequential)

**2a. TextMode state preservation skeleton.**
- `Loop.State` already carries `memory`, `journal`, `tool_cache`,
  `turn_history`, `child_steps`. This task wires TextMode's existing
  paths (final step assembly, error paths, multi-tool turns) to
  preserve and propagate them correctly when present.
- No combined-mode behavior enabled yet; validator still rejects.
- Regression test: pure `output: :text` runs are byte-identical before
  and after.

**2b. Combined-mode native preview + cache wiring.**
- For tools with `expose: :both, cache: true`, native app-tool
  execution seeds `tool_cache` via `canonical_cache_key/2` and renders
  a preview (default metadata; row/custom per `native_result:`).
- Provider-boundary encoding via `Jason.encode!/1`. Custom preview
  fallback rule enforced.
- Cross-shape cache-hit test: native call with string-keyed args, then
  PTC-Lisp call (in `output: :ptc_lisp`, since combined still gated)
  with atom-keyed args, must hit the same entry.
- **Validator still rejects `output: :text, ptc_transport: :tool_call`.**
  Behavior change is library-internal until 3e flips the gate.
- Regression: pure `output: :text` runs end with `state.tool_cache`
  remaining `nil` (its initial value — `Loop.State` defaults `tool_cache:
  nil`). Assert "remains `nil`" rather than "is empty" — combined mode
  initializes `tool_cache` to `%{}`, but pure text mode must not.

### Tier 3 — Combined mode (sequential)

**3a. TextMode `lisp_eval` happy path.**
- Register `lisp_eval` in TextMode's request build (combined
  mode only) using `tool_description(:in_process_text_mode)`.
- Recognize and dispatch the tool, run the program via `Lisp.run/2`
  with `memory`, `journal`, `tool_cache`, `turn_history`,
  `child_steps` threaded.
- Render success/error via `PtcToolProtocol.render_success/2` /
  `render_error/3`.
- **Budget exemption.** `lisp_eval` invocations MUST NOT
  increment `state.total_tool_calls` and MUST NOT count against
  `agent.max_tool_calls`. The current TextMode counter at
  `text_mode.ex:494` (commit `8091822`) counts every dispatched tool;
  add an explicit exclusion. Direct test: an agent with
  `max_tool_calls: 1` MUST allow N `lisp_eval` calls in
  sequence (bounded only by `max_turns`). Native app-tool calls
  continue to consume the budget as today.
- No multi-call rule yet; assume well-formed turns. Validator still
  gated.

**3b. `turn_history` semantics in combined mode.**
- Per "`turn_history` Semantics In Combined Mode": only successful
  `lisp_eval` results advance it. Native calls, direct text
  turns, and all error paths do not.
- Tests cover each case directly.

**3c. Multi-call rule + protocol-error rendering.**
- Implements the precedence table per "Multi-Call Rule."
- Protocol-error JSON shape lives in `Loop.TextMode`, not in
  `PtcToolProtocol`.
- Universal pairing rule preserved.

**Codex review checkpoint (strongly recommended).** Run `/codex review`
on the dispatch / classification logic. The six-row precedence table
has high cyclomatic surface area, the rules are precedence-sensitive
("first match wins"), and a wrong branch silently degrades to
TextMode's default behavior — bugs are bisect-painful. Ask Codex
specifically to verify each table row maps to a code path and that
unknown-tool handling diverges from v1 PTC `:tool_call` exactly where
documented (Rows 4–6).

**3d. Final-output semantics, signature coercion, and budget matrix.**
- "Final-Output Semantics" matrix: one direct test per row.
- Signature coercion through `JsonHandler.atomize_value/2` /
  `validate_return/2` (re-exported via `PtcToolProtocol`).
- "Turn Budget Interaction" cases: program-call-on-final-turn
  terminates via `max_turns_exceeded` with paired `tool_call_id`.

**3e. Validator unblock.**
- Flip `output: :text, ptc_transport: :tool_call` from reject to
  allow. Single guard line.
- Add the negative test (combined mode rejected before this commit;
  accepted after) to lock the gate's location.

**Codex review checkpoint (strongly recommended).** This is the
bisectable cutoff — once it lands, combined mode is user-reachable.
Run `/codex review` over the cumulative Tier 2 + Tier 3 diff (not just
3e's one-line flip), focused on: (a) every Implementation Contract
MUST is exercised by at least one test in the test list, (b) the
`output: :text, ptc_transport: :content` rejection still holds, and
(c) no pure `output: :text` regression. Treat any "should also test"
suggestion as a blocker until resolved.

### Tier 4 — Integration, docs, benchmarks

**4. Transcript replication + docs + benchmark.**
- Live-provider integration test that replays the End-to-End Transcript.
- Docs for tool exposure policy, large-result handling, and combined-
  mode user-facing budget guidance.
- Benchmark native-only vs native-preview-plus-PTC on a large result
  workload.

## Tests To Require Before Enabling The Validator

- Validator still rejects `output: :text, ptc_transport: :content`.
- Validator allows `output: :text, ptc_transport: :tool_call` only
  after Phase 3 runtime support lands.
- **Default `expose:` in combined mode is `:native`** when not specified
  on a tool. (Negative test: no tool gets `:both` or `:ptc_lisp`
  exposure unless explicitly requested.)
- Validator rejects `native_result:` unless `expose: :both` and
  `cache: true`.
- Validator rejects invalid `expose:` and `native_result.preview:`
  values with informative ArgumentErrors.
- Combined mode reuses the existing `cache:` field; setting `cache: true`
  on a tool used in combined mode enables shared-cache behavior between
  native and PTC-Lisp layers.
- Native tool result is previewed (metadata-only by default) while
  full result is retained in `tool_cache`, for tools with both
  `expose: :both` and `cache: true`.
- `preview: :rows` opt-in includes row values in the preview, capped
  by `limit:`.
- Custom preview function receives only `full_result`; if it raises or
  returns non-encodable data, runtime falls back to metadata-only and
  emits a warning.
- PTC-Lisp call to the same tool/args hits the native-seeded cache,
  even when args arrive in different shapes (string vs atom keys,
  integer-equal floats vs integers, key-order variation) — exercises
  `canonical_cache_key/2` directly.
- Tools without `cache: true` do not advertise `full_result_cached: true`
  and do not seed `tool_cache`.
- `:native`-only tools return their actual result, not a metadata
  preview, and do not seed the cache.
- A PTC-Lisp program calling `(tool/foo ...)` where `foo` has
  `expose: :native` is rejected at parse time with a clear error.
- Multiple native app-tool calls in a single assistant turn still work
  (existing TextMode behavior preserved).
- Multi-call rule precedence: `lisp_eval` + unknown native tool
  rejects all with `mixed_with_lisp_eval`, not `unknown_tool`.
- Multi-call rule precedence: two `lisp_eval` calls reject all
  with `multiple_tool_calls`.
- Single unknown native tool (no `lisp_eval`) returns one
  `unknown_tool` error result; other valid native calls in the same
  turn proceed normally.
- `lisp_eval` invocations do not consume `max_tool_calls`;
  native app-tool calls do. Direct test: `max_tool_calls: 1` with a
  turn budget of 4 allows ≥2 sequential `lisp_eval` calls,
  while a single native call exhausts the budget.
- `(return v)` inside `lisp_eval` produces a success tool-result;
  the LLM gets one more turn to respond **when budget remains**. The
  agent's final answer is the LLM's final text, not `v`.
- `(fail v)` inside `lisp_eval` produces an error tool-result
  (`reason: "fail"`); the LLM gets one more turn to respond **when
  budget remains**.
- `lisp_eval` invoked on the final available turn: tool-result
  JSON is emitted and paired with the `tool_call_id`, then the loop
  terminates via TextMode's existing `max_turns_exceeded` path. No
  follow-up text turn happens. Test directly.
- Final-answer signature coercion matches the matrix in "Final-Output
  Semantics" — direct test for each row.
- Telemetry events for tool calls always carry `exposure_layer`.
- Pure `output: :text` mode (no `ptc_transport: :tool_call`) shows no
  cache fills after tool calls — proves Phase 2 doesn't leak into pure
  text behavior.
- Within-run compaction preserves provider-valid `tool_call_id`
  pairings (regression test for `a33abe8`-class bugs).

## Deferred From v1

- **`*1`/`*2`/`*3` integration with native tool results.** Reusing
  `turn_history` for native result summaries muddies an existing
  semantic. The cache-reuse hint in tool-result content is enough for
  v1.
- **Richer `ChatState` API** carrying `messages`, `memory`, `journal`,
  `tool_cache`, `turn_history` across `chat/3` turns. Useful beyond
  combined mode; deserves its own plan. v1 combined mode does not
  thread state across `chat/3` turns.
- **Cross-`chat/3`-turn compaction.** Same family as ChatState; defer
  together.
- **Automatic journal breadcrumbs for native large-result tool calls.**
  Already optional in earlier drafts; defer until real usage shows
  whether the cache hint alone is enough.
- **Configurable resource limits** (`tool_cache_limit`, eviction, etc.).
  See "Future Resource Limits" above.
- **Short-circuit semantics for `(return v)`** matching a structured
  signature. Not in v1; users who want this have
  `output: :ptc_lisp, ptc_transport: :tool_call`.

## Open Questions

- Should preview rendering share code with
  `TurnFeedback.execution_feedback/3`? Both produce structured maps;
  factoring may or may not be useful.
- How should retained results be accounted against memory/resource
  limits when the configurable subsystem lands? (See "Future Resource
  Limits.")

## Implementer Onboarding

Fresh implementer starting from a cold context: read in this order.

1. `CLAUDE.md` (project conventions).
2. This plan's "Summary," "Non-Goals," and "Implementation Contract"
   sections — they bound the work.
3. "File Map For Implementers" above — orient on what lives where.
4. `lib/ptc_runner/sub_agent/loop/ptc_tool_call.ex` and its tests —
   the model for Tier 0 extraction and renderer behavior.
5. `lib/ptc_runner/sub_agent/loop/text_mode.ex` and its tests — the
   surface that grows in Tiers 2 and 3.

Tier 0 is the only task that should run alone. Tier 1a and 1b can run
in parallel worktrees once Tier 0 lands. Don't skip ahead to Tier 3
without 2a/2b green; the state-preservation skeleton in 2a is the
foundation.

Each tier's PR description should link back to this plan's
"Implementation Contract" entries it satisfies and its
"Tests To Require Before Enabling The Validator" entries it covers.
The validator unblock (3e) is the bisectable cutoff.
