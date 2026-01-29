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
  - String functions: grep, grep-n, .indexOf, .lastIndexOf
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

v0.7: Unified Task System (see #703)
  - (task id expr) - idempotent execution, handles sync/async transparently
  - (parallel ...) - concurrent task execution
  - (checkpoint id msg) - human-in-the-loop suspension
  - Task state tracking in Context
  - PendingStep struct for suspended execution
  - SubAgent.resume/3 for continuing after async/checkpoint
  Architecture: Pure library (no processes initially)

v0.8: State Management
  - JSON serialization as default (Step <-> JSON)
  - Resume from serialized state
  - MFA tuple tool format for serializability
  Architecture: First child_spec components (opt-in)

v0.9: Streaming & Sessions
  - on_token / on_tool_start / on_tool_end callbacks
  - Session GenServer for long-lived agents
  - SandboxPool for concurrency limiting
  Architecture: Complete supervision tree available

v1.0: Production Ready
  - Stable serialization format
  - Phoenix/Oban integration guides
  - Performance benchmarks
  Architecture: Evaluate user feedback on OTP adoption

UNDER CONSIDERATION (not scheduled):
  - :ptc_json mode for JSON DSL programs
  - :text mode for free-form responses
  - :chat mode for traditional tool-calling agents
  See: docs/plans/question-mode-plan.md
```

---

## Design Notes

### Unified Task System (v0.7)

Core primitives:

| Form | Purpose |
|------|---------|
| `(task id expr)` | Idempotent execution - runs once, caches result, handles sync/async transparently |
| `(parallel & tasks)` | Concurrent execution - starts all tasks, suspends until all complete |
| `(checkpoint id msg)` | Human-in-the-loop - suspends for approval |

The LLM doesn't need to know if a tool is sync or async. Same syntax works for both. See GitHub Issue #703 for full design.

### State Serialization (v0.8)

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

1. **Async/idempotency**: Unified `(task)` form - single syntax for sync/async. See #703.
2. **Parallel execution**: `(parallel ...)` form with task idempotency.
3. **Human-in-the-loop**: `(checkpoint id msg)` compiles to suspension.
4. **Serialization format**: JSON default, binary opt-in.
5. **Tool serialization**: MFA tuples (no registry needed).
6. **Multi-instance naming**: Default + explicit `:name` override.
7. **Session lifecycle**: Idle timeout + pending-aware + explicit termination.

---

## Open Questions

1. **Task serialization scope**: Include full task results or summarized?
2. **Parallel error handling**: Cancel siblings on failure or wait for all?
3. **Hierarchical tasks**: How to scope parent/child task IDs?
4. **Backpressure**: How to handle LLM rate limits in streaming?
5. **Pool implementation**: Poolboy, NimblePool, or custom?

---

## References

- Architecture: `lib/ptc_runner/sub_agent/` (Loop, Telemetry, ToolNormalizer)
- Step struct: `lib/ptc_runner/step.ex`
- Sandbox: `lib/ptc_runner/sandbox.ex`
- Issue #700: Idempotency motivation
- Issue #703: Unified Task System epic
