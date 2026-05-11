# Agentic `ptc_task` Phase 0 Contract Notes

Date: 2026-05-11

This note records the shared contract boundary for implementing
`Plans/agentic-ptc-task-subagent-spec.md`.

## SubAgent Completion Mode

`PtcRunner.SubAgent` now accepts:

- `completion_mode: :implicit` — default, preserves existing behavior.
- `completion_mode: :explicit` — reserved for `ptc_task`; Worker A owns full
  enforcement that only `(return ...)` and `(fail ...)` are terminal.

The no-tool single-shot fast path is limited to implicit mode, so explicit-mode
agents enter the normal loop.

## Continuation Guard

`PtcRunner.SubAgent.Loop.run/2` accepts:

```elixir
continuation_guard: fn turn, state, next_state ->
  :continue | {:stop, {:ok | :error, %PtcRunner.Step{}}}
end
```

The guard runs after a non-terminal turn has produced a continuation state and
before the next LLM turn starts. Worker D/Worker C can use this to enforce the
ledger-aware no-continuation-after-write rule.

## Agentic Ledger

`PtcRunnerMcp.Agentic.Ledger` defines the internal entry shape:

```elixir
%{
  id: reference(),
  server: String.t(),
  tool: String.t(),
  args_hash: String.t(),
  status: :attempted | :ok | :error,
  effect: :read | :write | :unknown,
  turn: pos_integer(),
  started_at: DateTime.t(),
  completed_at: DateTime.t(),
  duration_ms: non_neg_integer(),
  result_bytes: non_neg_integer(),
  error_reason: String.t(),
  error: String.t()
}
```

Entries are internal atom-keyed maps. JSON projection happens at the MCP
envelope boundary.

## Response Projection

`PtcRunnerMcp.Agentic.Projection.partial_side_effects/0` is the single source
for the `:partial_side_effects` atom. `reason_string/1` maps it to
`"partial_side_effects"`.

## Structured Catalog Snapshot

`PtcRunnerMcp.Upstream.Catalog` now exposes:

- `snapshot/1`
- `freeze_snapshot/1`
- `frozen_snapshot/0`

The shape matches `render_entries/1`. Prompt/capability-summary work should use
the structured snapshot rather than parsing `frozen/0`.
