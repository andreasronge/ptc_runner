# Lisp Kernel - Autonomous D4 Kernel TurnEvents Plan

**Status:** implemented 2026-07-09 on `exp/lisp-kernel`. Written after
role-backed prelude selection landed and after the decision to use the existing
TraceLog substrate instead of adding a kernel-specific logging API.

This plan makes `PtcRunner.Kernel` the third canonical TurnEvent driver beside
`PtcRunner.Session` and the `PtcRunner.SubAgent` loop. It is not a new logging
API, not a live A/B, and not a replacement for the existing kernel `:events`
debug/report callback.

Implementation evidence:

```sh
mix test test/ptc_runner/kernel_test.exs \
  test/ptc_runner/kernel/eval_test.exs \
  test/ptc_runner/kernel/feedback_ab_test.exs \
  test/ptc_runner/trace_log/turn_log_integration_test.exs \
  test/ptc_runner/trace_log/turn_event_test.exs
```

## Short Goal Prompt

```text
Run the autonomous D4 Kernel TurnEvents plan described in
docs/plans/lisp-kernel/autonomous-d4-kernel-turn-events.md.

Goal: make PtcRunner.Kernel emit canonical PtcRunner.TraceLog.TurnEvent records
through TraceLog.record_turn_event/1, one per model/eval turn, with the same
top-level shape as Session and SubAgent. Preserve the existing :events callback
as an ephemeral eval-report/debug channel, and never write unsafe_debug raw
prompts/messages/programs into TraceLog.

Work risk-first: first prove TraceLog.with_trace around Kernel.run captures
turns across the Lisp sandbox/tool boundary; then extend
turn_log_integration_test.exs so kernel is the third parity driver.
```

## Objective

S19 feedback A/B reports remain descriptive because the kernel does not emit
canonical D4 turn logs. The rest of the substrate already exists:

- `PtcRunner.TraceLog.TurnEvent.build/1` defines the canonical turn shape.
- `PtcRunner.TraceLog.record_turn_event/1` fans out to active JSONL collectors
  and in-memory sinks.
- `PtcRunner.TraceLog.Analyzer` and `TraceLog.Introspection` already consume
  driver-agnostic turn events.
- `PtcRunner.Kernel` now carries role-backed prelude metadata in
  `prelude.metadata[:role_prelude_selection]`, including role,
  grant fingerprint, selected refs, resolved refs, and renderer id.

The missing piece is only the driver integration: every kernel LLM/eval pair
should produce a bounded, sanitized TurnEvent through the same emission point
as Session and SubAgent.

## Fit With Existing Plans

- **D4 in architecture.md.** This is the concrete implementation brief for
  the recorded D4 decision: "kernel emits `PtcRunner.TraceLog.TurnEvent` per
  llm/eval pair."
- **D20 role-backed selection.** D20 should feed D4 metadata. Kernel
  TurnEvents should stamp `role`, `grant_fingerprint`, selected/resolved
  preludes, and presentation metadata when role-backed preludes are used.
- **S19 / M3 measurement.** D4 is the gate that lets feedback A/B claims use
  existing turn-log metrics such as turns, repeated reads by `args_hash`,
  tokens, and trace/write-error counts.
- **TraceLog Introspection.** Model-visible log access should later be granted
  through the existing `log/` introspection prelude and role-selected backing
  tools. Do not add a bespoke `Kernel.run(logs: true)` API.

## Non-Goals

- No new TraceLog event schema.
- No new kernel logging API.
- No live model run or benchmark claim.
- No migration of unsafe debug payloads into TraceLog.
- No replacement of the kernel `:events` callback or
  `PtcRunner.Kernel.Eval` report format.
- No model-visible history access in this session; granting `log/` via roles
  is a later integration step.
- No broad changes to Session/SubAgent turn emission except parity-test
  updates required by the shared shape.

## Channel Split

Keep two channels with different guarantees:

- **TraceLog TurnEvents** are durable, sanitized, replayable, and eventually
  model-inspectable through `TraceLog.Introspection`. They must contain no raw
  prompts, raw provider responses, raw eval programs beyond the canonical
  bounded `program` field, raw host memory, raw mission data, or unsafe debug
  payloads.
- **Kernel `:events` / `:unsafe_debug`** remains the ephemeral harness/debug
  channel. It may include unsafe prompt/message/program material only behind
  the existing explicit unsafe flag and must never be routed into
  `TraceLog.record_turn_event/1`.

Do not collapse these channels in this plan. A later cleanup may teach the eval
harness to collect sanitized evidence from a `MemorySink`, but that should not
change the D4 emission contract.

## Proposed Event Shape

Build events through `PtcRunner.TraceLog.TurnEvent.build/1` and record through
`PtcRunner.TraceLog.record_turn_event/1`.

Use:

- `driver: :kernel` after extending `TurnEvent.driver_string/1` / tests to
  accept the third driver.
- `role` and `grant_fingerprint` from
  `prelude.metadata[:role_prelude_selection]`, or nil for embedded defaults.
- `turn` as the canonical committed-turn counter, one-based for the first
  successful kernel turn and advanced only when the attempt succeeds.
- `attempt` as the one-based monotonic model-attempt counter, advanced for
  protocol/transport failures and eval attempts.
- `committed` true when the model attempt produced a successful kernel turn;
  false for protocol/transport failures, runtime errors, and explicit
  `(fail ...)` evals. This is distinct from kernel PTC-Lisp memory mutation:
  explicit `(fail ...)` can preserve memory from the inner eval while still
  logging `committed: false`.
- `status` as `:ok` for successful eval returns/continues, `:error` for
  eval failure/protocol/transport errors.
- token fields from the normalized LLM action.
- `program` as the model-selected PTC-Lisp program for tool-call turns. This is
  already a canonical TurnEvent field, but it is still sanitized by the event
  path and must not be duplicated elsewhere.
- `result_preview`, `prints`, `tool_calls`, `catalog_ops`, and `fail` from the
  existing public eval projection, using `TurnEvent.preview/1` and
  `TurnEvent.tool_call_summary/1` where applicable.
- `preludes` from `TurnEvent.prelude_provenance(Prelude.trace_summary(prelude))`.
- `prelude_projection` and `prelude_call_policy` from role-backed prelude
  metadata where available, bounded and source-free. `prelude_presentation`
  carries bounded run-level presentation policy such as the symbol-inventory
  renderer id; it is not role authority.
- `turn_type` such as `:eval`, `:protocol_error`, or `:transport_error`.

Do not include:

- raw LLM request system/messages;
- raw provider response body;
- raw `unsafe_debug` artifacts;
- raw memory maps;
- prelude source or prompt wording;
- raw tool args/results.

## Implementation Plan

### Phase 1 - Research and Exact Boundary

Read before editing:

- `lib/ptc_runner/kernel.ex`
- `priv/preludes/agent/core.lisp`
- `lib/ptc_runner/trace_log.ex`
- `lib/ptc_runner/trace_log/turn_event.ex`
- `lib/ptc_runner/session.ex`
- `lib/ptc_runner/sub_agent/loop/metrics.ex`
- `test/ptc_runner/trace_log/turn_log_integration_test.exs`
- `test/ptc_runner/kernel_test.exs`

Record implementation notes for:

- where the kernel can observe both the normalized LLM action and the matching
  eval result;
- whether `TraceLog.with_trace/2` around `Kernel.run/2` captures writes from
  the sandbox/tool process without extra `TraceLog.join/2`;
- what token fields are available in the normalized action;
- which public eval projection fields are safe to reuse;
- how role-backed metadata is read from the compiled prelude.

### Phase 2 - Explicit Turn Pairing

Make turn pairing explicit. `agent.core` already passes `"turn"` into
`tool/llm-complete`; update it to pass `"turn"` into `tool/eval-program` too:

```clojure
(tool/eval-program {"program" (action "program") "turn" turn})
```

Update the private tool signature and Elixir argument handling accordingly.
This avoids pairing a later eval with a previous model action through mutable
"last action" guesses. Because this is a 0.x branch, do not add broad
compatibility shims: `eval-program` should require `"turn"` and fail closed for
stale `agent.core` variants that omit it.

### Phase 3 - Kernel Turn Recorder

Add a small per-run recorder owned by the kernel process, not by the sandbox:

- `llm-complete` stores a bounded pending action summary keyed by turn.
- `eval-program` records the completed TurnEvent for that same turn after
  receiving the eval projection.
- protocol errors and transport errors record an event from `llm-complete`
  because no eval follows.
- final return/fail/continue status is derived from the eval projection.

The recorder should be private to `Kernel.run/2` and cleaned up with the same
`after` block that stops host-held memory. It must not expose unsafe debug data
to the model or the trace sink.

If the implementation can build the event without a recorder by threading all
needed data through private tool args safely, prefer that simpler path, but do
not push raw request/messages through Lisp-visible data to achieve it.

### Phase 4 - Canonical Emission

Build the event with `TurnEvent.build/1` and call
`TraceLog.record_turn_event/1`. Do not use `TraceLog.write_to_active/1` for
turns; D4 requires fan-out to every active JSONL collector and memory sink.

The call must be a no-op outside a trace scope, matching the existing
`record_turn_event/1` contract.

### Phase 5 - Tests

Add deterministic tests before any live run:

- `TraceLog.with_trace(fn -> Kernel.run(...) end)` captures kernel turn events
  from a JSONL sink.
- A `TraceLog.with_memory_sink/1` or equivalent MemorySink scope captures the
  same kernel turn events for current-run history.
- Kernel, Session, and SubAgent turn events share identical top-level keys and
  identical `data` keys in `turn_log_integration_test.exs`.
- `Analyzer.sessions/1`, `Analyzer.programs/1`, and duplicate-call metrics can
  consume kernel turns without a kernel-specific path.
- Role-backed kernel turns include `role`, `grant_fingerprint`, and source-free
  prelude provenance.
- Embedded-default kernel turns still emit with nil role/fingerprint and valid
  prelude provenance.
- Unsafe debug raw prompt/message/program fields do not appear in JSONL or
  MemorySink events.
- The existing `:events` callback still receives the current sanitized
  prelude/action/eval report events so `Kernel.Eval` and `FeedbackAB` do not
  regress.
- Running outside TraceLog scope does not fail and does not require a collector.

Suggested commands:

```sh
mix test test/ptc_runner/kernel_test.exs \
  test/ptc_runner/kernel/eval_test.exs \
  test/ptc_runner/kernel/feedback_ab_test.exs \
  test/ptc_runner/trace_log/turn_log_integration_test.exs \
  test/ptc_runner/trace_log/turn_event_test.exs
```

Finish with:

```sh
mix precommit
```

## Design Checks

- **Projection path.** Use the public eval projection and TurnEvent helpers;
  never log native memory or raw `%Step{}` structs.
- **Value shape.** Every driver-specific value in `data` is bounded by
  `TurnEvent.build/1` / `TraceLog.Event.sanitize/1` and has deterministic
  JSON-safe shape.
- **Trace propagation.** Prove whether sandbox/tool process writes reach active
  collectors. If not, add the smallest `TraceLog.join/2` propagation at the
  kernel boundary and test cleanup.
- **Schema parity.** Adding `driver: "kernel"` must not fork top-level or data
  keys across drivers.
- **Debug separation.** Unsafe debug is never durable TraceLog data.
- **No parallel harness.** Do not add a kernel analyzer, kernel log file, or
  kernel-specific replay format in this plan.

## Stop Conditions

- Stop and report if kernel TurnEvents require changing the canonical
  TurnEvent schema in a way that breaks Session/SubAgent parity.
- Stop and report if `TraceLog.with_trace/2` cannot capture kernel tool-process
  emissions without broad TraceContext surgery.
- Stop and report if useful D4 evidence would require logging raw prompts,
  raw responses, raw eval programs outside the canonical `program` field, or
  unsafe debug artifacts.
- Stop and report if preserving the existing `:events` report path conflicts
  with canonical TurnEvent emission.

## Launch Criteria

The plan is complete when:

- `PtcRunner.Kernel` emits canonical TurnEvents through
  `TraceLog.record_turn_event/1`;
- kernel is included in the Session/SubAgent turn-event parity test;
- JSONL and MemorySink traces both capture kernel turns;
- role/prelude provenance appears in kernel turns without source leakage;
- existing kernel eval and feedback reports still work;
- S19/M3 reports no longer need to say D4 canonical TurnEvents are absent.
