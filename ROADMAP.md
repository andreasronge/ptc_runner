# PtcRunner Roadmap

## Future (not scheduled)

### Function Passing Between SubAgents

- Share function definitions across recursive agent levels
- CoreToSource-based namespace export/import
- Eliminate redundant code generation in `:self` recursive pattern

See: `docs/plans/function-passing-between-subagents.md`

### State Management

- JSON serialization as default (Step <-> JSON)
- Resume from serialized state
- MFA tuple tool format for serializability

### Production

- Stable serialization format
- Oban integration guide
- Performance benchmarks

---

## Decisions Made

1. **Idempotency**: `(task id expr)` with journal-based caching. Semantic IDs over expression hashing.
2. **No plan objects**: Implicit re-planning — LLM re-navigates from journal state each turn.
3. **No suspension primitives**: Use `(return {:status :waiting})` instead of checkpoint/resume.
4. **Developer owns persistence**: Journal is a pure map; no DB/Oban dependency.
5. **Serialization format**: JSON default, binary opt-in.
6. **Tool serialization**: MFA tuples (no registry needed).
7. **Unified text mode**: Single `:text` output mode replaced separate `:json` and `:tool_calling` modes.
8. **XML prompts**: System prompts use XML tags instead of markdown headings for better LLM parsing.
9. **Pure library**: No GenServer/Supervisor layer. Callers manage state (e.g., LiveView assigns for chat, GenServer for long-lived agents). Streaming via `on_chunk` callback.

---

## Open Questions

1. **Journal truncation**: How aggressively to truncate results in Mission Log?
2. **Backpressure**: How to handle LLM rate limits in streaming?

---

## References

- Architecture: `lib/ptc_runner/sub_agent/` (Loop, Telemetry, ToolNormalizer)
- Step struct: `lib/ptc_runner/step.ex`
- Sandbox: `lib/ptc_runner/sandbox.ex`
- Plans: `docs/plans/v0.7-journaled-tasks.md`, `docs/plans/function-passing-between-subagents.md`
- Text Mode: `lib/ptc_runner/sub_agent/loop/text_mode.ex`
- CoreToSource: `lib/ptc_runner/lisp/core_to_source.ex`
