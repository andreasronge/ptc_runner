# Plan: Tracing & Observability Review

## Overview

A comprehensive review of ptc_runner's tracing and logging system covering code quality, memory/performance, configuration, documentation, BEAM best practices, and OpenTelemetry readiness. The system has three overlapping tracing mechanisms (Tracer, TraceLog, PlanTracer) that are architecturally sound but have grown organically and need hardening.

## Current Architecture

```
lib/ptc_runner/
├── tracer.ex              # Immutable struct-based trace recorder (in-memory)
├── tracer/timeline.ex     # ASCII timeline rendering
├── trace_log.ex           # JSONL event capture framework (file-based)
├── trace_log/
│   ├── collector.ex       # GenServer writing events to JSONL files
│   ├── handler.ex         # Telemetry event handler → Collector
│   ├── event.ex           # Safe JSON encoding with sanitization
│   └── analyzer.ex        # Offline analysis, tree loading, Chrome export
├── plan_tracer.ex         # Real-time terminal visualization for PlanExecutor
└── sub_agent/telemetry.ex # Telemetry event emission with span correlation
```

**Flow**: SubAgent.Loop emits `:telemetry` events → Handler captures them → Collector writes JSONL → Analyzer loads/visualizes offline.

**Three tracing layers**:
1. **Tracer** (struct) — in-memory, built into SubAgent execution, stored in Step results
2. **TraceLog** (telemetry+JSONL) — file-based, opt-in via `with_trace/2`, offline analysis
3. **PlanTracer** (Agent) — real-time terminal UI for PlanExecutor events

---

## Part 1: Code-Level Findings

### HIGH Priority

#### F7: Missing Collector `terminate/2` callback
- **File**: `lib/ptc_runner/trace_log/collector.ex`
- **Severity**: HIGH | **Effort**: LOW
- **Problem**: If the Collector GenServer crashes, the file handle is never explicitly closed. The BEAM will eventually GC it, but the file may not be flushed, resulting in truncated/incomplete trace files with no `trace.stop` event.
- **Solution**: Add a `terminate/2` callback:
  ```elixir
  @impl true
  def terminate(_reason, %{file: file}) when not is_nil(file) do
    File.close(file)
    :ok
  end
  def terminate(_reason, _state), do: :ok
  ```

#### F4: Duplicate tool telemetry events
- **File**: `lib/ptc_runner/sub_agent/loop.ex:1497-1536`
- **Severity**: HIGH | **Effort**: LOW
- **Problem**: Tool events are emitted both inside the sandbox process (via `wrap_with_telemetry` in tool_normalizer) AND re-emitted post-sandbox via `emit_tool_telemetry/2`. Every tool call generates 2x start + 2x stop events. Tests explicitly expect this duplication (`telemetry_test.exs:473`).
- **Solution**: Now that sandbox trace propagation works (via `TraceLog.join` in `sandbox.ex:91-92`), remove the post-sandbox re-emission and rely solely on the in-sandbox span events. Update tests accordingly.

#### F20: Missing `replan.stop` telemetry on error paths
- **File**: `lib/ptc_runner/plan_executor.ex:589-614`
- **Severity**: HIGH | **Effort**: LOW
- **Problem**: `do_replan/5` emits `[:ptc_runner, :plan_executor, :replan, :start]` telemetry at line 541, but `[:ptc_runner, :plan_executor, :replan, :stop]` is only emitted on the success path (line 567-572). The two error branches (`{:error, {:repair_plan_invalid, ...}}` and `{:error, reason}`) skip the stop event entirely, leaving an unpaired `replan.start` in the trace. Confirmed in real trace: `examples/page_index/traces/minimal_1770885465.jsonl` line 123 has `replan.start` with no matching `replan.stop`.
- **Solution**: Emit `[:ptc_runner, :plan_executor, :replan, :stop]` on all exit paths of `do_replan/5`, including error branches. Include `status: :error` and the error reason in metadata.

#### F21: `execution.stop` metadata stale after replan failure
- **File**: `lib/ptc_runner/plan_executor.ex:596`
- **Severity**: HIGH | **Effort**: LOW
- **Problem**: On the replan error paths, `build_metadata(state, state.completed_results)` is called with `state` before `replan_count` is incremented (increment only happens on success at line 582). This produces `replan_count: 0` in the `execution.stop` event even though a replan was attempted. The `results` and `task_ids` fields are also empty because the error path uses the pre-replan state. Confirmed in real trace: line 136 shows `execution.stop` with `replan_count: 0`, `results: {}`, `task_ids: []` despite a replan having occurred.
- **Solution**: Update `replan_count` and merge `completed_results` in state before calling `build_metadata` on error paths, or pass adjusted values directly.

### MEDIUM Priority

#### F6: `with_trace` double-stop masks errors
- **File**: `lib/ptc_runner/trace_log.ex:194-204`
- **Severity**: MEDIUM | **Effort**: LOW
- **Problem**: `with_trace/2` calls `stop/1` in both the `try` block and the `after` block. On the happy path, stop is called twice. The second call returns `{:ok, "unknown", 0}` silently — masking actual errors if the first stop fails.
- **Solution**: Restructure to use try/rescue instead of after:
  ```elixir
  try do
    result = fun.()
    {:ok, path, _errors} = stop(collector)
    {:ok, result, path}
  rescue
    e ->
      stop(collector)
      reraise e, __STACKTRACE__
  end
  ```

#### F1: Unbounded Tracer.entries growth
- **File**: `lib/ptc_runner/tracer.ex:187-189`
- **Severity**: MEDIUM | **Effort**: LOW
- **Problem**: `add_entry/2` prepends to an unbounded list. Long-running agents with many turns accumulate entries without limit. Each entry can contain full LLM responses and tool results.
- **Solution**: Add optional `max_entries` field to Tracer struct. When exceeded, drop oldest entries or summarize them. Default to a sensible limit (e.g., 1000).

#### F11: Hardcoded sanitization limits
- **File**: `lib/ptc_runner/trace_log/event.ex:14-15`
- **Severity**: MEDIUM | **Effort**: LOW
- **Problem**: `@max_string_size` (64KB) and `@max_list_size` (100) are compile-time constants. These have been bumped from 8KB to 32KB to 64KB, suggesting different use cases need different limits.
- **Solution**: Make configurable via application config:
  ```elixir
  Application.get_env(:ptc_runner, :trace_max_string_size, 65_536)
  Application.get_env(:ptc_runner, :trace_max_list_size, 100)
  ```

#### F15: Dual tracing system confusion
- **File**: `tracer.ex`, `trace_log.ex`, `plan_tracer.ex`
- **Severity**: MEDIUM | **Effort**: HIGH
- **Problem**: Three independent tracing mechanisms overlap without documented boundaries. Tracer uses entry_type atoms (`:llm_call`, `:tool_call`), TraceLog uses string event names (`"llm.start"`, `"tool.stop"`), and PlanTracer is a separate Agent for terminal display. A developer new to the codebase would struggle to know which to use when.
- **Solution**: Add architecture doc explaining when to use each. Consider whether Tracer (the struct) is still needed given TraceLog captures the same information more comprehensively.

#### F17: Process dictionary coupling
- **File**: Multiple (`:ptc_trace_collectors`, `:ptc_telemetry_span_stack`)
- **Severity**: MEDIUM | **Effort**: HIGH
- **Problem**: The entire TraceLog system relies on process dictionary keys for trace context propagation. Manual propagation required when spawning processes (`TraceLog.join/2`). Easy to forget in new code paths. No compile-time safety.
- **Solution**: Wrap process dictionary access behind a formal context API module. This is a common BEAM pattern (OpenTelemetry does similar) but encapsulating it would reduce bugs.

### LOW Priority

#### F5: No back-pressure on Collector GenServer
- **File**: `lib/ptc_runner/trace_log/collector.ex:49-51`
- **Problem**: `GenServer.cast/2` is fire-and-forget. If events arrive faster than file writes, mailbox grows unboundedly.
- **Solution**: Add mailbox size monitoring or max_queue_size check.

#### F8: Collector write errors are silent
- **File**: `lib/ptc_runner/trace_log/collector.ex:129-135`
- **Problem**: Write failures increment a counter but never log or alert.
- **Solution**: `Logger.warning` on first write error.

#### F9: Handler swallows all exceptions
- **File**: `lib/ptc_runner/trace_log/handler.ex:104-115`
- **Problem**: `rescue _ -> :ok` makes debugging trace collection issues invisible.
- **Solution**: Log at `:debug` level.

#### F2: Event.sanitize has no depth limit
- **File**: `lib/ptc_runner/trace_log/event.ex:110-146`
- **Problem**: Deep recursion on nested structures with no maximum depth.
- **Solution**: Add depth parameter, `inspect/1` values beyond max depth (e.g., 10).

#### F3: Analyzer.load materializes entire file
- **File**: `lib/ptc_runner/trace_log/analyzer.ex:34-40`
- **Problem**: `File.stream! |> Enum.map(...)` loads full file into memory.
- **Solution**: Provide streaming API for large traces. Current approach is fine for typical use.

#### F12: Hardcoded `preserve_full_keys`
- **File**: `lib/ptc_runner/trace_log/event.ex:121`
- **Problem**: `~w(system_prompt)` only. Users may need other keys preserved.
- **Solution**: Make configurable.

#### F13: Default trace path writes to CWD
- **File**: `lib/ptc_runner/trace_log/collector.ex:168-171`
- **Problem**: In containers, CWD could be anywhere.
- **Solution**: `config :ptc_runner, :trace_dir, "/tmp/traces"`.

#### F19: Span ID collision risk
- **File**: `lib/ptc_runner/sub_agent/telemetry.ex:179-180`
- **Problem**: 8-char hex (32-bit) — 50% collision at ~65K concurrent spans.
- **Solution**: Increase to 16-char hex (64-bit), consistent with trace_id size.

---

## Part 2: Documentation Gaps

### HIGH Priority

| Gap | Location | Action |
|-----|----------|--------|
| PlanTracer not in observability guide | `docs/guides/subagent-observability.md` | Add new section between TraceLog and Telemetry Events |
| `mix ptc.viewer` not in observability guide | `docs/guides/subagent-observability.md` | Add Trace Viewer section |
| PlanExecutor telemetry events missing from guide | `docs/guides/subagent-observability.md` | Expand "Available Events" table with 8 plan_executor events |
| TraceLog.Event doctests may not be running | `test/` | Add `doctest PtcRunner.TraceLog.Event` line to test file |

### MEDIUM Priority

| Gap | Location | Action |
|-----|----------|--------|
| Cross-process tracing undiscoverable | `docs/guides/subagent-observability.md` | Add "Cross-Process Tracing" subsection under TraceLog |
| Tracer module not referenced in guide | `docs/guides/subagent-observability.md` | Add note clarifying Tracer vs TraceLog usage |
| PlanTracer has no cross-reference to observability guide | `lib/ptc_runner/plan_tracer.ex` | Add link in @moduledoc |
| No architecture doc for three tracing layers | `docs/` | New doc explaining Tracer vs TraceLog vs PlanTracer |

### LOW Priority

| Gap | Location | Action |
|-----|----------|--------|
| Truncation thresholds undocumented for users | `event.ex` / guide | Document that large outputs are truncated and why |
| Trace file cleanup not in guide | `docs/guides/subagent-observability.md` | Mention `Analyzer.delete_tree/1` |
| No trace format versioning | `collector.ex` | Add version field to `trace.start` event |

---

## Part 3: OpenTelemetry Assessment

### Current State of OTEL for Elixir (2025-2026)

The ecosystem is mature and production-ready:
- `opentelemetry_api` v1.5 — zero dependencies, 27.8M downloads
- `opentelemetry` SDK v1.7 — stable, implements OTEL Spec v1.8.0
- Phoenix, Ecto, Oban all have official OTEL instrumentation packages
- `opentelemetry_process_propagator` solves BEAM process isolation

### Recommendation: Follow the ecosystem pattern

The canonical Elixir library pattern has three tiers:

```
Tier 1: Library emits :telemetry events          ← ptc_runner already does this
Tier 2: Optional opentelemetry_api dependency     ← zero-cost, noop without SDK
Tier 3: Separate opentelemetry_ptc_runner package ← bridges telemetry → OTEL spans
```

**ptc_runner is already at Tier 1.** The `:telemetry` events are the correct abstraction. Users who want OTEL can bridge via a separate instrumentation package. Bundling the OTEL SDK would be anti-pattern for a library.

### OTEL vs Custom Tracing: Keep Both

| System | Purpose | Keep? |
|--------|---------|-------|
| Chrome Trace export | Local debugging, single-agent visualization, no infra needed | Yes — unique differentiator |
| `:telemetry` events | Universal contract for any observability backend | Yes — already correct |
| OTEL SDK | Distributed observability, cross-service tracing | No — let users bring their own |

### If OTEL Integration Is Desired Later

The bridge pattern used by Phoenix/Ecto/Oban:

```elixir
# Separate package: opentelemetry_ptc_runner
defmodule OpentelemetryPtcRunner do
  def setup do
    :telemetry.attach_many("otel-ptc-runner", [
      [:ptc_runner, :sub_agent, :run, :start],
      [:ptc_runner, :sub_agent, :run, :stop],
      [:ptc_runner, :sub_agent, :llm, :start],
      [:ptc_runner, :sub_agent, :llm, :stop],
      # ...
    ], &__MODULE__.handle_event/4, %{})
  end
end
```

Cross-process context propagation would use `opentelemetry_process_propagator`:
```elixir
alias OpentelemetryProcessPropagator.Task
Task.async_stream(items, fn item -> process(item) end)
```

---

## Part 4: BEAM Best Practices Comparison

### Where ptc_runner aligns well

- `:telemetry` events with hierarchical naming (`[:ptc_runner, :sub_agent, ...]`)
- Span pattern (start/stop/exception)
- Rich metadata in events
- Process-isolated trace collection
- JSONL format (crash-safe, appendable, standard)

### Where ptc_runner diverges from conventions

| Convention | Current State | Recommendation |
|-----------|--------------|----------------|
| Centralized telemetry docs | Events scattered across Telemetry and Handler | Consolidate event catalog in one place |
| Measurements in native time units | Some events use milliseconds directly | Standardize on native, let consumers convert |
| No direct Logger calls from library | PlanTracer uses `Logger.info` | Make output sink configurable |
| Bounded storage | Tracer entries + Collector mailbox unbounded | Add configurable limits |
| Configurable telemetry prefix | Hardcoded `[:ptc_runner, :sub_agent]` | Consider making configurable for multi-instance |
| Test telemetry as public API | Good SubAgent coverage | Also test PlanExecutor events |

### Patterns from Phoenix / Ecto / Oban

1. Always emit `:telemetry` — it is the universal contract
2. Use `[:lib, :component, :start/:stop/:exception]` naming
3. Include rich metadata — let consumers decide what to use
4. Never be opinionated about the backend/reporter
5. Provide optional convenience handlers but don't require them
6. Measurements in native time units

---

## Part 5: Prioritized Recommendations

### Phase 1: Quick Wins (LOW effort, HIGH/MEDIUM impact) — DONE

All 5 items completed. Changes verified: 3740 tests, 0 failures, credo clean, dialyzer clean.

1. ~~Add `terminate/2` to Collector~~ — Added with `trap_exit`, handles `file: nil` case
2. ~~Fix `with_trace` double-stop~~ — Replaced `try/after` with `try/catch` pattern
3. ~~Remove duplicate tool telemetry~~ — Removed `emit_tool_telemetry/2` from loop.ex (~45 lines deleted)
4. ~~Log first Collector write error~~ — `Logger.warning` on first failure, silent thereafter
5. ~~Log Handler exceptions at `:debug` level~~ — Replaces silent `rescue _ -> :ok`

Additional fixes applied during review:
- Added `handle_info({:EXIT, ...})` to Collector to suppress noisy GenServer warnings
- Updated `subagent-observability.md` Known Limitations (tool events are now captured)
- Updated `trace_log.ex` moduledoc about sandbox trace propagation

### Phase 1b: Quick Wins from Trace Sanity Check (LOW effort, HIGH impact) — DONE

6. ~~Fix missing `replan.stop` telemetry on error paths (F20)~~ — Both error branches now emit `replan.stop` with `status: :error`
7. ~~Fix stale `execution.stop` metadata after replan failure (F21)~~ — Error paths use merged `completed_results` and incremented `replan_count`

### Phase 2: Configuration (LOW-MEDIUM effort) — DONE

All 4 items completed. Changes verified: 3755 tests, 0 failures, credo clean, dialyzer clean.

8. ~~Make sanitization limits runtime-configurable~~ — `:trace_max_string_size` and `:trace_max_list_size` via Application env
9. ~~Make `preserve_full_keys` configurable~~ — `:trace_preserve_full_keys` via Application env
10. ~~Add configurable default trace directory~~ — `:trace_dir` via Application env, falls back to CWD
11. ~~Add `max_entries` option to Tracer~~ — `Tracer.new(max_entries: 1000)`, tracks count to avoid `length/1`

### Phase 3: Documentation (MEDIUM effort) — DONE

All 5 items completed. Reviewed against documentation-guidelines.md.

12. ~~Add PlanTracer section to observability guide~~ — Quick usage, stateful tree view, example output, color legend
13. ~~Add `mix ptc.viewer` section to observability guide~~ — Command, options table, separate package note
14. ~~Document PlanExecutor telemetry events in guide~~ — 9 events added to Available Events table
15. ~~Add architecture doc~~ — `subagent-tracing-architecture.md`: decision table, data flow diagram, config reference
16. ~~Fix TraceLog.Event doctests~~ — Already present; added cross-references between all tracing modules

### Phase 4: Architecture (HIGH effort, long-term)

17. ~~Formal context API~~ — `PtcRunner.TraceContext` module wraps all process dictionary access
18. Evaluate if Tracer struct is still needed vs TraceLog
19. ETS-backed bounded storage for high-throughput scenarios
20. Trace file rotation — configurable max file size + count
21. Optional `opentelemetry_ptc_runner` bridge package (when demand warrants)

---

## Test Coverage Gaps

- ~~No tests for Collector crash/recovery scenarios~~ — Added in Phase 1 (5 tests: terminate, write error logging, IO crash)
- ~~No tests for `with_trace` error masking~~ — Added in Phase 1
- No tests for `Analyzer.build_tree` or `export_chrome_trace`
- No tests for `TraceLog.join/2` cross-process propagation
- No stress tests for high-volume event scenarios
- No tests for `Analyzer.load_tree` cycle detection
- ~~No test verifying `replan.stop` is emitted on replan error paths (F20)~~ — Added in Phase 1b (3 tests)
- ~~No test verifying `execution.stop` metadata accuracy after replan failure (F21)~~ — Added in Phase 1b
