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

1. **No suspension primitives**: Use `(return {:status :waiting})` instead of checkpoint/resume.
2. **Developer owns persistence**: Journal is a pure map; no DB/Oban dependency.
3. **Serialization format**: JSON default, binary opt-in.
4. **Tool serialization**: MFA tuples (no registry needed).
5. **Unified text mode**: Single `:text` output mode replaced separate `:json` and `:tool_calling` modes.
6. **XML prompts**: System prompts use XML tags instead of markdown headings for better LLM parsing.
7. **Pure library**: No GenServer/Supervisor layer. Callers manage state (e.g., LiveView assigns for chat, GenServer for long-lived agents). Streaming via `on_chunk` callback.
8. **Removed MetaPlanner**: JSON plan graphs, verification predicates, and autonomous replanning removed. Simpler orchestration via Elixir (`with` chains, `Task.async_stream`, subagents-as-tools) is the recommended path.
9. **Plan as display labels**: `plan:` no longer auto-enables journaling. It provides progress visibility only. Idempotency belongs at the app/tool layer.

---

## Open Questions

1. **Backpressure**: How to handle LLM rate limits in streaming?
2. **Auto-progress from tool spans**: Render observed tool activity as progress, separate from plan step completion.

---

## References

- Architecture: `lib/ptc_runner/sub_agent/` (Loop, Telemetry, ToolNormalizer)
- Step struct: `lib/ptc_runner/step.ex`
- Sandbox: `lib/ptc_runner/sandbox.ex`
- Plans: `docs/plans/function-passing-between-subagents.md`
- Text Mode: `lib/ptc_runner/sub_agent/loop/text_mode.ex`
- CoreToSource: `lib/ptc_runner/lisp/core_to_source.ex`
