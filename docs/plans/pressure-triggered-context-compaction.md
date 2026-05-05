# Pressure-triggered Context Compaction

## Problem

The current `compression` support rewrites every multi-turn PTC-Lisp run from turn 2 into a synthetic single user message. This is more than context reduction: it changes the agent's view of its own history by rendering namespaces, keeping only selected successful-turn history, dropping tool results from the rendered tool-call list, and conditionally hiding errors.

This has produced poor results in exploratory examples such as code search. Those tasks need the recent raw breadcrumb trail: what was searched, what was returned, which attempts failed, and why the next query changed. For the current test workload, many conversations are also short enough that there is no context-window pressure to solve.

The feature should be replaced with a simpler pressure-triggered compaction model:

- Preserve normal conversation history by default.
- Trigger only when turn count or token budget pressure is reached.
- Keep recent raw turns intact.
- Compact only older history.
- Expose clear library configuration so users can pick deterministic trimming or custom policies.

## Current Behavior

Compression is enabled through `compression: true | module | {module, opts}` and currently defaults to `PtcRunner.SubAgent.Compression.SingleUserCoalesced`.

Observed drawbacks:

- It activates too early: `Loop.build_llm_messages/3` switches from accumulated messages to compressed messages on turn 2.
- It drops important evidence: `ExecutionHistory.render_tool_calls/2` renders only `name(args)`, not tool results.
- It treats success and failure asymmetrically: failed turns are excluded from accumulated tool calls/prints, and recovered errors are hidden.
- It conflates memory rendering with conversation history.
- It is hard to evaluate because token reduction and behavior changes are mixed together.

## Reference Patterns

Most agent frameworks manage context with a short-term memory policy rather than always-on semantic compression:

- **LangChain/LangGraph**: trim, delete, or summarize older messages, with token thresholds and recent-message preservation.
- **LlamaIndex**: FIFO queue with token limits and flush sizes; older messages flushed only under pressure.
- **AutoGen**: buffered recent-message view or token-limited context.
- **Semantic Kernel**: chat history reducers summarize older messages past a threshold.

Shared pattern: keep recent history raw, trigger under pressure, make policy configurable.

## Scope: Phase 1 (this plan) vs. Phase 2 (follow-up)

**Phase 1 — what this plan ships.** Pressure-triggered deterministic trimming only. One strategy: `:trim`. No summarization, no custom-module behaviour, no `tokens_ratio`, no `compact_to`, no summarizer override. Minimal new surface area.

**Phase 2 — deferred.** Summarization (`:summarize`), custom strategy behaviour, summarizer LLM override, ratio-based triggers tied to adapter context-window metadata. These were in the previous draft of this plan and removed because:

- Re-summarizing from raw turns on every triggered turn is O(n²) without a watermark/cache (Codex review).
- The `{messages, stats}` strategy contract has no return path for `state.compaction_summary` without new state-update plumbing.
- Summarizer LLM cost, fallback ladders, and adjacent-user-message edge cases need design work that shouldn't gate the trim path.
- This is a 0.x library — ship the simple correct thing first, add complexity only after we see real pressure cases that trim alone can't handle.

A separate follow-up doc will design Phase 2 once `:trim` is in production.

## Decisions Locked In

These were open questions in earlier drafts. Resolved here so implementation has a single answer:

1. **`compression` is removed, not deprecated.** Per `CLAUDE.md`: "delete old code rather than deprecate." Drop `PtcRunner.SubAgent.Compression`, `SingleUserCoalesced`, the `compression:` option, and `state.compression_stats` entirely. CHANGELOG note: "rename `compression:` to `compaction:` and re-tune."
2. **`compaction: true` is opt-in.** Library default is `false`.
3. **One strategy only: `:trim`.** No `:summarize` in Phase 1. No custom-module behaviour.
4. **No compaction for single-shot or single-shot + retry.** Skip both. Gate: `agent.max_turns > 1`. This reverses the existing behavior (`loop.ex:1112` currently runs compression for `retry_turns > 0`); this change is documented in the migration note.
5. **Strategy contract is pure `(input) -> {messages, stats}`.** No state mutations. The loop owns all state.
6. **No `state` leak in any future custom-strategy API.** When Phase 2 adds the behaviour, it will receive a `%Compaction.Context{}` (memory, turn, max_turns, retry phase, token limit, system token estimate) — never the full loop state struct. Locking this in now so the Phase 1 internal call site already uses the same shape.
7. **Token counter is pluggable but explicitly a pressure heuristic.** Default: `String.length(content) / 4` (matches existing `metrics.ex:18`, not `byte_size`). Override via `token_counter: fun`. We do not claim model-accurate counting.
8. **Empty keyword `compaction: []` is invalid.** Validator rejects it. Use `true` for defaults.
9. **Strategies operate on the loop's LLM-input messages**, which today are `:user | :assistant` only (verified in `loop.ex:271-978`). System prompt stays separate via `llm_input.system`. `Turn.message` (`turn.ex:55`) does include `:system` but that's the *collected debug* shape, not what strategies see.

## Proposed API

```elixir
SubAgent.run(prompt, llm: llm, compaction: true)
```

Explicit configuration:

```elixir
SubAgent.run(prompt,
  llm: llm,
  compaction: [
    strategy: :trim,
    trigger: [turns: 8, tokens: 12_000],
    keep_recent_turns: 3,
    keep_initial_user: true,
    token_counter: nil       # nil = String.length/4 default
  ]
)
```

Type:

```elixir
@type compaction_opts ::
        false | nil | true | keyword()
```

Custom strategy modules and `{module, opts}` are **not accepted in Phase 1.** Validator rejects them with a message pointing to the follow-up plan.

Recommended defaults for `compaction: true`:

```elixir
[
  strategy: :trim,
  trigger: [turns: 8],
  keep_recent_turns: 3,
  keep_initial_user: true,
  token_counter: nil
]
```

### Trigger semantics

- `trigger: [turns: N]` — fires when `state.turn > N`.
- `trigger: [tokens: N]` — fires when estimated total message tokens ≥ `N`.
- Both may be set; either firing triggers compaction (OR, not AND).
- Once triggered, `:trim` is idempotent — re-running on already-trimmed history is cheap and produces the same result. No watermark needed for Phase 1.

There is no `compact_to` knob. `:trim` always trims to exactly `keep_initial_user? + keep_recent_turns` worth of messages. Token budget is enforced post-trim only via the `over_budget?: true` flag in stats (see §`:trim` semantics below).

## Strategy: `:trim`

Deterministic. Keeps:

1. The first user message (if `keep_initial_user: true`) — the *first* message with role `:user` in the input list. Defined as the head, not a re-derivation from `state.turns`. This handles `initial_messages` correctly (see `loop.ex:271`).
2. The last `keep_recent_turns × 2` messages (one assistant + one user per turn pair).

Drops everything in between.

### Edge cases the validator and implementation must handle

- **Fewer messages than `keep_recent_turns × 2 + 1`**: return input unchanged, `triggered: false`.
- **First message is not `:user`**: skip `keep_initial_user`; emit `over_budget?: true` is *not* the right signal — instead emit `kept_initial_user?: false` in stats.
- **Result starts with `:assistant`**: never. The recent slice must begin with `:user`. If slicing produces an assistant-leading sequence, drop one more message from the front.
- **Single message exceeds token budget after trim**: keep it whole. Emit `over_budget?: true` in stats. Do not split content.
- **Token estimation**: explicitly a pressure heuristic. Document in the strategy module that this is not adapter-accurate.

### Slicing source of truth

`keep_recent_turns` slices **`state.messages`** (the LLM-input message list), not `state.turns`. Reasoning:

- `state.messages` is what the LLM actually sees. Trimming it is what reduces context.
- `state.turns` is debug/observability state, retained in full regardless.
- Final, retry, validation, parse-error, and `must_return` phases produce variable message counts per "turn." Slicing on messages avoids guessing how many messages a phase contributes.

Phase 2's `:summarize` strategy will need a different slicing model that maps turns → message spans. That's part of why it's deferred.

## Implementation Plan

### 1. Add `PtcRunner.SubAgent.Compaction`

New module. Responsibilities:

- Normalize `compaction` configuration.
- Decide whether pressure has been reached.
- Call the selected strategy (currently only `:trim`).
- Return `{messages, stats}`.

Internal call shape (used by `:trim` today, exposed publicly only in Phase 2):

```elixir
@type context :: %PtcRunner.SubAgent.Compaction.Context{
        turn: pos_integer(),
        max_turns: pos_integer(),
        retry_phase?: boolean(),
        memory: map() | nil,
        token_counter: (String.t() -> non_neg_integer())
      }

@spec maybe_compact([message()], context(), keyword()) ::
        {[message()], stats()} | {:not_triggered, [message()], stats()}
```

The `Context` struct is defined now even though Phase 1 only has one internal caller. This locks in the API shape for Phase 2 so we don't accidentally leak `%State{}` later.

### 2. Normalization and validation

`Compaction.normalize/1` accepts:

- `nil | false` → `{:disabled, []}`.
- `true` → `{:trim, default_opts}`.
- `keyword()` with `strategy: :trim` (or unspecified) → `{:trim, merged_opts}`.

Rejects with clear error messages:

- `keyword()` with no keys (`compaction: []`) → "use `compaction: true` for defaults".
- `strategy:` value other than `:trim` (e.g. `:summarize`, `:last_n`, `:token_trim`) → "Phase 1 supports `:trim` only. See docs/plans/pressure-triggered-context-compaction-phase-2.md".
- Module or `{module, opts}` form → same Phase 2 message.
- `keep_recent_turns < 1`.
- `trigger` not a keyword list.
- `trigger[:turns]` not a positive integer.
- `trigger[:tokens]` not a positive integer.
- `trigger` empty (`trigger: []`) — ambiguous; require at least one of `:turns` or `:tokens`.
- `token_counter` not a 1-arity function.
- Unknown keys in the top-level keyword list (catches typos).

### 3. Token estimation

Default: `String.length(content) / 4` (matches `metrics.ex:18`).

`token_counter: fun/1` overrides. Receives a single message's content string, returns a non-negative integer.

Document in the module @moduledoc and the guide that this is a pressure heuristic. Do not claim model-accurate counting. Phase 2 may add adapter-aware counting via `tokens_ratio:` and `context_window:`, but Phase 1 does not.

Estimation runs on every multi-turn LLM call when compaction is enabled. The cost is O(total_message_chars) which is already what we materialize for the LLM call — keep the loop in pure Elixir, no regex or unicode normalization.

### 4. Replace `build_llm_messages/3`

Change `Loop.build_llm_messages/3`:

1. If `compaction` is disabled, return `state.messages` as-is. No stats. (Zero-overhead path.)
2. If `agent.max_turns <= 1`, return `state.messages` as-is. No stats. (Single-shot, including single-shot+retry.)
3. Otherwise build the `Compaction.Context`, call `Compaction.maybe_compact/3` with `state.messages`.
4. If `:not_triggered`, return original messages plus `triggered: false` stats.
5. If triggered, return trimmed messages plus stats.

Invariants:

- `llm_input.system` stays separate from `messages`.
- `state.messages` itself is not mutated. The trimmed list is only used for the LLM call. `state.turns` is also untouched.
- `state.compaction_stats` is overwritten on each turn (last event wins). This matches existing `compression_stats` behavior. If a multi-event view is ever needed, that's a separate metrics question — not a Phase 1 blocker.

### 5. Implement `:trim`

`PtcRunner.SubAgent.Compaction.Trim`. Pure function, no LLM calls, no state.

```elixir
def run(messages, ctx, opts) do
  if triggered?(messages, ctx, opts) do
    trimmed = do_trim(messages, opts)
    {trimmed, build_stats(messages, trimmed, opts)}
  else
    {:not_triggered, messages, %{enabled: true, triggered: false, strategy: "trim"}}
  end
end
```

Tests cover all edge cases listed in §`:trim` semantics.

### 6. Stats shape

Store under `state.compaction_stats`. Surface in `step.usage.compaction`.

```elixir
%{
  enabled: true,
  triggered: true,
  strategy: "trim",
  reason: :turn_pressure,        # | :token_pressure | nil
  messages_before: 13,
  messages_after: 7,
  estimated_tokens_before: 31_200,
  estimated_tokens_after: 12_400,
  kept_initial_user?: true,
  kept_recent_turns: 3,
  over_budget?: false
}
```

Non-triggered: `%{enabled: true, triggered: false, strategy: "trim"}`.

Disabled: omit `step.usage.compaction` entirely.

### 7. Removal of `compression`

Before merging, run a sweep:

```bash
rg -l "compression|Compression" lib test docs examples demo priv
```

Delete or update every hit. Known references beyond the previous list:

- `lib/ptc_runner/sub_agent.ex` (option passthrough)
- `lib/ptc_runner/sub_agent/loop/metrics.ex` (compression_stats handling)
- `lib/ptc_runner/sub_agent/debug.ex` (debug rendering)
- `lib/ptc_runner/sub_agent/loop/step_assembler.ex` (usage struct)
- Any `trace_log` / `trace` handler that includes compression fields
- All `compression*` test files
- All `compression*` doc references in guides
- `examples/code_scout/*` (`--compression` flag)
- `demo/lib/ptc_demo/*` (`/compression` slash command)

Replace with `compaction` equivalents only where the user-facing surface needs them (CLI flag, slash command, guide). Internal-only references just go away.

### 8. CHANGELOG and migration note

```markdown
### Breaking

- Removed `compression:` option. Use `compaction: true` or `compaction: [strategy: :trim, ...]` instead.
- Compaction is now opt-in (was opt-in before too, but the default strategy is different).
- Compaction no longer runs for single-shot or single-shot + retry. If your single-shot agent
  relied on compression collapsing retry context, restructure to multi-turn or accept the
  raw retry context.
- Behavior change: compaction triggers only under pressure (turn count or token estimate),
  not from turn 2 onward. Short conversations now keep raw history.
- `:summarize` and custom strategy modules are deferred to a follow-up. If you used a custom
  compression module, you'll need to wait or trim manually.
```

### 9. Tests

`test/ptc_runner/sub_agent/compaction_test.exs`:

- Normalization: `nil`, `false`, `true`, valid keyword, invalid keyword (empty, bad strategy, bad types, unknown keys, module form), bad `token_counter` arity.
- `:trim` does not trigger below threshold.
- `:trim` triggers on turn pressure.
- `:trim` triggers on token pressure.
- `:trim` keeps initial user when `keep_initial_user: true`.
- `:trim` skips initial user when first message isn't `:user`; sets `kept_initial_user?: false`.
- `:trim` never produces an assistant-leading recent slice.
- `:trim` reports `over_budget?: true` when a single retained message exceeds token estimate budget.
- `:trim` is idempotent: running twice produces the same output.

`test/ptc_runner/sub_agent/loop_compaction_test.exs`:

- Compaction skipped when `max_turns <= 1` (single-shot).
- Compaction skipped when `max_turns == 1, retry_turns > 0` (single-shot + retry — verifies the behavior change).
- Compaction skipped when disabled (`compaction: false` and unspecified).
- Stats appear in `step.usage.compaction` when enabled.
- `state.messages` is not mutated by compaction.
- `state.turns` is preserved in full after compaction.
- `collect_messages` debug visibility is preserved (raw `state.messages` accessible).
- Retry turns: validation errors remain visible (the recent window must include the retry turn).

Existing tests to delete: `test/ptc_runner/sub_agent/loop_compression_test.exs` and any other `compression`-named test file.

## Files Likely To Change

New:

- `lib/ptc_runner/sub_agent/compaction.ex`
- `lib/ptc_runner/sub_agent/compaction/context.ex`
- `lib/ptc_runner/sub_agent/compaction/trim.ex`
- `test/ptc_runner/sub_agent/compaction_test.exs`
- `test/ptc_runner/sub_agent/loop_compaction_test.exs`
- `docs/guides/subagent-compaction.md`
- `docs/plans/pressure-triggered-context-compaction-phase-2.md` (Phase 2 design stub)

Modified:

- `lib/ptc_runner/sub_agent/definition.ex` (drop `compression:`, add `compaction:`)
- `lib/ptc_runner/sub_agent/validator.ex` (compaction option validation)
- `lib/ptc_runner/sub_agent/loop.ex` (rewrite `build_llm_messages/3`)
- `lib/ptc_runner/sub_agent/loop/state.ex` (drop `compression_stats`, add `compaction_stats`)
- `lib/ptc_runner/sub_agent/loop/metrics.ex` (compaction_stats handling)
- `lib/ptc_runner/sub_agent/loop/step_assembler.ex` (usage struct)
- `lib/ptc_runner/sub_agent/debug.ex`
- `lib/ptc_runner/sub_agent.ex` (option passthrough, if any)
- `examples/code_scout/*`
- `demo/lib/ptc_demo/*`
- CHANGELOG

Deleted:

- `lib/ptc_runner/sub_agent/compression.ex`
- `lib/ptc_runner/sub_agent/compression/single_user_coalesced.ex`
- `lib/ptc_runner/sub_agent/compression/` (directory)
- `docs/guides/subagent-compression.md`
- `test/ptc_runner/sub_agent/loop_compression_test.exs`
- Any other `compression*` test/example files surfaced by the `rg` sweep.

## Sequencing

Land in this order to keep CI green at every step:

1. Add `Compaction`, `Compaction.Context`, `Compaction.Trim` modules + `compaction_test.exs`. No loop changes yet. CI green.
2. Update `definition.ex`, `validator.ex`, `state.ex`, `metrics.ex`, `step_assembler.ex` to add `compaction` field plumbing alongside existing `compression`. Both fields valid; `compaction` not yet wired into the loop. CI green.
3. Rewrite `build_llm_messages/3` to call `Compaction`. Add `loop_compaction_test.exs`. CI green.
4. Delete `compression` module, `compression:` option, `compression_stats` field, all `compression`-named tests/docs/examples. Run `rg` sweep. Update CHANGELOG. CI green.

Step 4 is the breaking commit. Steps 1–3 are additive.

## Verification

```bash
mix test test/ptc_runner/sub_agent/compaction_test.exs
mix test test/ptc_runner/sub_agent/loop_compaction_test.exs
mix test test/ptc_runner/sub_agent/loop_retry_turns_test.exs
mix test test/ptc_runner/sub_agent/validator_test.exs
mix precommit
rg -l "compression|Compression" lib test docs examples demo priv  # should return nothing
```
