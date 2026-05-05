# Pressure-triggered Context Compaction — Phase 2 (deferred)

This is a design stub for items deferred from
[Phase 1](pressure-triggered-context-compaction.md). Phase 1 ships
`compaction: true | [strategy: :trim, ...]` and that's it. Anything more
ambitious lives here.

## Why a Phase 2 at all

Phase 1's `:trim` strategy works for the common case: agent turns alternate
`:user` / `:assistant`, the recent few turns matter most, and the first user
prompt is worth keeping. When pressure hits, drop the middle.

That's not enough when:

- The middle contains genuinely useful state the recent turns reference back to
  ("we already tried X, Y, Z and they all failed for reason R").
- The conversation is very long and even the recent slice is over budget.
- A library consumer wants different retention rules per-agent (tool-use agents
  vs. coding agents vs. research agents).

Phase 2 adds the knobs for those cases without re-tuning Phase 1.

## What's deferred

### 1. `strategy: :summarize`

Replace the dropped middle with an LLM-generated summary instead of nothing. The
summary lives as a single `:user` message between the kept-initial-user (if any)
and the recent slice.

Open design questions:

- **Watermark / cache.** Re-summarizing from raw turns on every triggered turn
  is `O(n²)`. Either cache the summary per "summarized so far" position, or
  carry it forward in `state.compaction_summary` and only re-summarize when new
  middle content accumulates. The current strategy contract
  `(input) -> {messages, stats}` has no return path for this — Phase 2 needs
  state-update plumbing.
- **Summarizer LLM.** Default to `agent.llm`? Allow override? What about
  fallback when the summarizer call fails?
- **Adjacent-user-message edge cases.** If the recent slice begins with a
  `:user` and the summary message is also `:user`, do we coalesce?
- **Cost surfacing.** Summarizer LLM calls show up where in `step.usage`?

### 2. Custom strategy behaviour

Phase 1 explicitly rejects `compaction: SomeModule` and `compaction: {SomeModule, opts}`.
Phase 2 adds:

```elixir
@callback compact(messages :: [message()], ctx :: Compaction.Context.t(), opts :: keyword()) ::
            {[message()], stats()}
```

The contract is **already locked in** by `Compaction.Context` (defined in Phase 1).
Strategies receive a read-only context (turn, max_turns, retry_phase?, memory,
token_counter), never the full `%State{}`. This was a Phase 1 decision specifically
to avoid leaking loop internals into a public extension API later.

What still needs design:

- Validation hook: should the validator call `Module.validate(opts)` at agent
  construction time?
- Naming convention: `MyAgent.MyStrategy` vs. an atom shorthand registered like
  LLM names.
- How custom strategies surface their own stats keys without colliding with
  built-in `:trim` keys.

### 3. Adapter-aware token counting

Phase 1's default counter is `max(1, String.length(content) / 4)` — a pressure
heuristic, not a model-accurate count. Phase 2 should:

- Accept `tokens_ratio:` and `context_window:` options that let triggers be
  expressed as a fraction of the model's actual context window.
- Allow the LLM adapter to advertise its own counter when one is available
  (e.g., `tiktoken` for OpenAI, native counts from Anthropic).
- Document explicitly when the heuristic is good enough vs. when the adapter
  count matters (cost reporting wants accuracy; pressure detection doesn't).

### 4. `compact_to` knob

Phase 1's `:trim` always trims to exactly `keep_initial_user? + keep_recent_turns × 2`
messages. There is no "trim to under N tokens" target. If the recent slice itself
exceeds the budget, you get `over_budget?: true` in stats and that's it.

Phase 2 could add `compact_to: tokens` that drops more aggressively until the
budget is met, or splits oversize messages. Both add complexity that hasn't been
required in production yet.

### 5. Multi-event stats

Phase 1's `state.compaction_stats` is overwritten each turn (last event wins).
If a multi-event view is ever needed (every triggered firing, with stats per
firing), that's a separate metrics question — probably handled via telemetry
rather than the usage map.

## Trigger conditions for starting Phase 2

Don't start Phase 2 until at least one of these is true:

- A real production agent shows that `:trim` alone leaves it unable to recover
  context that summarization would preserve. ("The middle contained the schema
  the LLM keeps re-asking for.")
- Multiple consumers ask for a custom strategy module (one consumer = give them
  a workaround; multiple = build the API).
- An adapter ships a native token counter and the heuristic difference materially
  affects pressure detection.

This is a 0.x library. Ship the simple correct thing first.
