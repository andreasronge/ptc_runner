# PtcRunner Roadmap

## Release Plan

```
v0.5: Observability & Debugging ✅
  - Turn struct, tool_calls, prints, Step introspection
  - Message compression (SingleUserCoalesced strategy)
  - Debug API (print_trace)
  - Lisp error attribution (line/column)

v0.5.1: JSON Output Mode ✅
  - output: :json for structured data (classification, extraction)
  - Extended LLM callback interface: schema, tools, tool_choice
  - Signature to JSON Schema conversion

v0.5.2: Bugfixes ✅

v0.6: Language, Composition & Tracing ✅
  PTC-Lisp language:
  - `for` list comprehension
  - String functions: .indexOf, .lastIndexOf
  - Collection functions: extract, extract-int, pairs, combinations,
    mapcat, butlast, take-last, drop-last, partition-all
  - Aggregators: sum, avg, quot
  - Reader literals: ##Inf, ##-Inf, ##NaN

  SubAgent core:
  - return_retries for validation recovery (single-shot + multi-turn)
  - :self sentinel for recursive agents
  - memory_strategy :rollback for recoverable memory limit errors
  - Budget introspection and callback for RLM patterns
  - Last expression as return value on budget exhaustion
  - Iterative driver loop (refactored from recursive)
  - llm_query builtin integrated into system prompts

  LLM-as-tool composition:
  - LLMTool with response_template mode for typed LLM output
  - Transparent tool unwrapping and LLMTool input validation

  Tracing & observability:
  - TraceLog + Analyzer for structured SubAgent tracing
  - Hierarchical tracing for nested SubAgents (pmap, as_tool)
  - Chrome DevTools trace export
  - HTML trace viewer
  - Post-sandbox tool telemetry + child trace propagation
  - Span correlation in telemetry

  Utilities:
  - PtcRunner.Chunker for text chunking

v0.7: Plan & Execute, Tracing, Language ✅
  Plan System & Multi-Agent Orchestration:
  - MetaPlanner with trial & error replanning
  - PlanRunner / PlanExecutor for multi-agent workflows
  - Per-task quality gates with evidence-based verification
  - Direct agent for LLM-free task execution

  Journaled Task System:
  - (task id expr) - idempotent journaled execution
  - Journal: pure map passed via context, returned in Step.journal
  - step-done, task-reset forms and plan progress tracking

  Tracing & Observability:
  - ptc_viewer web UI (DAG graph, Gantt timeline, execution tree)
  - Cross-process trace propagation (TraceContext)
  - PlanTracer for plan-layer telemetry

  PTC-Lisp:
  - Tree traversal (walk, prewalk, postwalk, tree-seq)
  - boolean, type builtins; :when/:let/:while for for/doseq
  - Map support for take/drop/distinct family
  - Removed PTC-JSON language

  SubAgent:
  - thinking option, prompt caching (Anthropic/OpenRouter/Bedrock)
  - Configurable sandbox limits via application env
  - Unified builtin_tools, tool result caching
  - return_retries renamed to retry_turns

  Architecture: Pure library, developer owns persistence

v0.8: Text Mode, Language & Tooling ✅
  Unified Text Mode:
  - Renamed JSON mode to text mode, unifying :json and :tool_calling
  - Native tool calling mode for smaller LLMs
  - TextMode module with separate JsonHandler
  - ToolSchema for tool schema generation

  PTC-Lisp:
  - defonce special form for idempotent initialization
  - pr-str function, str fixed for Clojure-conformant collection printing
  - #"..." regex literal support
  - CoreToSource for Core AST to PTC-Lisp serialization
  - MapSet support for some/every?/not-any?/join/split/replace
  - Preserved tool_calls/prints from HOF closures and loop/recur

  SubAgent:
  - max_tool_calls limit to prevent runaway tool loops
  - pmap_max_concurrency config for parallel task limits
  - SubAgent name propagated to Step for TraceTree/Debug display
  - Journal/step-done prompt sections gated behind journaling: true
  - Prompt migration from markdown to XML tags

  LLM Client:
  - Embedding API (embed/2,3 and embed!/2,3)
  - Groq provider, Bedrock inference profile support
  - Migrated to ReqLLM pricing

  Tracing & Viewer:
  - Plan progress in Debug/TraceTree
  - ptc_viewer: multi-run span tree, collapsible groups, draggable sidebar
  - Trace sanitize max_map_size to prevent heap overflow

  Examples:
  - ALMA: evolutionary memory design for GraphWorld/ALFWorld environments

v0.9: Function Passing Between SubAgents
  - Share function definitions across recursive agent levels
  - CoreToSource-based namespace export/import
  - Eliminate redundant code generation in :self recursive pattern
  See: docs/plans/function-passing-between-subagents.md

FUTURE (not scheduled):
  State Management:
  - JSON serialization as default (Step <-> JSON)
  - Resume from serialized state
  - MFA tuple tool format for serializability

  Streaming & Sessions:
  - on_token / on_tool_start / on_tool_end callbacks
  - Session GenServer for long-lived agents
  - SandboxPool for concurrency limiting

  Production:
  - Stable serialization format
  - Phoenix/Oban integration guides
  - Performance benchmarks
```

---

## Design Notes

### Meta Planner (v0.7)

**Journaled Task System** — Stateless re-navigation via journal. See `docs/plans/v0.7-journaled-tasks.md`.

| Concept | Description |
|---------|-------------|
| `(task id expr)` | Idempotent execution — checks journal, skips if already done |
| Journal | Pure map of task ID → result, passed in via context |

### Function Passing (v0.9)

Share parent-defined functions with child agents in recursive `:self` patterns. Uses `CoreToSource` to serialize the parent's `user_ns` into PTC-Lisp source that is prepended to the child's context. See `docs/plans/function-passing-between-subagents.md`.

### State Serialization (future)

- JSON as default format (debuggability with `jq` over efficiency)
- MFA tuples for serializable tools (no registry, no global state)
- Binary serialization available as opt-in for high-throughput

### OTP Architecture

Current: Pure library. `SubAgent.run/2` is synchronous, sandboxes are ephemeral.

When task system + persistence require shared state, use `child_spec` without auto-start:

```elixir
children = [
  {PtcRunner.Supervisor, name: :ptc, pool_size: 10},
]
```

Recommended integration: use ptc_runner as a pure library within your own GenServer. Only adopt `PtcRunner.Supervisor` when you need sandbox pooling, pending ops tracking, or session management.

### BEAM-Native Differentiators

- **Distributed execution**: Serialize state, resume on different node
- **Supervision integration**: SubAgent as supervised GenServer child
- **Phoenix integration**: LiveView/Channel streaming helpers
- **Oban integration**: SubAgent as background job with retry

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

---

## Open Questions

1. **Journal truncation**: How aggressively to truncate results in Mission Log?
2. **Backpressure**: How to handle LLM rate limits in streaming?
3. **Pool implementation**: Poolboy, NimblePool, or custom?

---

## References

- Architecture: `lib/ptc_runner/sub_agent/` (Loop, Telemetry, ToolNormalizer)
- Step struct: `lib/ptc_runner/step.ex`
- Sandbox: `lib/ptc_runner/sandbox.ex`
- Plans: `docs/plans/v0.7-journaled-tasks.md`, `docs/plans/function-passing-between-subagents.md`
- Text Mode: `lib/ptc_runner/sub_agent/loop/text_mode.ex`
- CoreToSource: `lib/ptc_runner/lisp/core_to_source.ex`
