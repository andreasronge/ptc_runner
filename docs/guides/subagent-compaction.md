# Context Compaction

Pressure-triggered context compaction trims older turns from a multi-turn agent's
LLM-input message list once turn count or estimated token usage crosses a threshold.
Recent turns stay intact so the agent always sees the raw breadcrumb trail of what
it most recently did.

Compaction is **opt-in**. The library default is `compaction: false`.

## When to enable it

You probably don't need compaction unless you're seeing one of:

- A multi-turn agent that runs long enough to push toward the model's context window.
- LLM cost dominated by repeatedly re-sending earlier turn history.
- Agents that stall because old context is drowning out the recent error trail.

For short multi-turn runs (under ~8 turns or under a few thousand tokens), the cost
of compaction outweighs the benefit. Leave it off.

## Quick start

```elixir
SubAgent.run(prompt, llm: llm, max_turns: 20, compaction: true)
```

`compaction: true` selects sensible defaults — the `:trim` strategy with
`trigger: [turns: 8]`, `keep_recent_turns: 3`, `keep_initial_user: true`.

## Explicit configuration

```elixir
SubAgent.run(prompt,
  llm: llm,
  max_turns: 20,
  compaction: [
    strategy: :trim,
    trigger: [turns: 8, tokens: 12_000],
    keep_recent_turns: 3,
    keep_initial_user: true,
    token_counter: nil
  ]
)
```

| Option | Default | Meaning |
|--------|---------|---------|
| `strategy` | `:trim` | The only Phase 1 strategy. Custom modules and `:summarize` are deferred. |
| `trigger` | `[turns: 8]` | Fires when `state.turn > N` (turns) or estimated total tokens `>= N` (tokens). Set both for OR semantics. |
| `keep_recent_turns` | `3` | The most recent `N × 2` messages stay verbatim. |
| `keep_initial_user` | `true` | Keep the first user message (the original prompt) at the head of the trimmed list. |
| `token_counter` | `nil` (uses default) | 1-arity function from message content to estimated token count. |

## What `:trim` does

When pressure is detected, `:trim`:

1. Optionally keeps the first user message (when `keep_initial_user: true` and the
   head of the list actually has role `:user`).
2. Keeps the last `keep_recent_turns × 2` messages.
3. Drops everything in between.

If slicing would produce an `:assistant`-leading recent slice (e.g. odd boundaries),
`:trim` drops one more message from the front so the slice begins with `:user`.

## Behavior change vs. the legacy `compression:` option

If you migrated from `compression: true`:

- **Compaction is opt-in.** `compression: true` is removed entirely; nothing happens
  unless you set `compaction: true` (or a keyword config).
- **Compaction skips single-shot and single-shot+retry.** The legacy compression path
  ran for `retry_turns > 0` even with `max_turns: 1`. Compaction does not. The retry
  budget is small by design and raw error trails help the LLM recover.
- **Triggers are pressure-based, not turn-2.** `compression` activated from turn 2.
  Compaction only fires when turn count or token estimate crosses your threshold.
- **Stats are different.** `step.usage.compression` is gone. `step.usage.compaction`
  is set whenever compaction was active for the agent (triggered or not).

If your agent depended on compression collapsing every multi-turn run from turn 2,
either:

- Restructure to multi-turn so compaction can fire under pressure, or
- Accept the raw history (most short tasks won't hit a context limit).

## What you'll see in `step.usage.compaction`

Triggered:

```elixir
%{
  enabled: true,
  triggered: true,
  strategy: "trim",
  reason: :turn_pressure,        # | :token_pressure
  messages_before: 13,
  messages_after: 7,
  estimated_tokens_before: 31_200,
  estimated_tokens_after: 12_400,
  kept_initial_user?: true,
  kept_recent_turns: 3,
  over_budget?: false
}
```

Not triggered (compaction was active but didn't fire):

```elixir
%{
  enabled: true,
  triggered: false,
  strategy: "trim",
  reason: nil,
  messages_before: 4,
  messages_after: 4,
  estimated_tokens_before: 320,
  estimated_tokens_after: 320,
  kept_initial_user?: false,
  kept_recent_turns: 3,
  over_budget?: false
}
```

The shape is the same in both cases — every field is always present, so consumers
can read `usage.compaction.messages_before` without `Map.has_key?` guards.

`over_budget?: true` flags the case where a single retained message exceeds the
configured `trigger[:tokens]` budget. `:trim` does not split content; you'll need
to handle this at a higher level (smaller messages, larger budget, or Phase 2's
summarization once it ships).

## Token estimation

The default counter approximates tokens as `max(1, String.length(content) / 4)` —
a pressure heuristic, not a model-accurate count. If you need adapter-specific
counting, supply your own:

```elixir
compaction: [
  token_counter: fn content -> :tiktoken.encode(content) |> length() end
]
```

The counter must be a 1-arity function returning a non-negative integer.

## Limits

- **`:trim` only.** No summarization in Phase 1.
- **No custom strategy modules.** Phase 2 will add a behaviour for that.
- **Not applied to text mode.** `output: :text` rejects compaction at validation time.
- **Not applied to single-shot or single-shot+retry.** Gate is `agent.max_turns > 1`.
- **Token counter is a heuristic.** Adapter-aware counting is deferred to Phase 2.

For the deferred items, see
[Phase 2 plan](../plans/pressure-triggered-context-compaction-phase-2.md).

## See Also

- [Observability](subagent-observability.md) — finding compaction stats in traces
- [Troubleshooting](subagent-troubleshooting.md) — when context is the bottleneck
- `PtcRunner.SubAgent.Compaction` — module reference
