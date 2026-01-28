# TraceLog Integration Simplifications

How implementing TraceLog could simplify existing code in Debug and the demo benchmark.

## Overview

TraceLog (see `trace-log-specification.md`) provides structured trace logging via Telemetry. This document identifies reuse opportunities and simplifications once TraceLog is implemented.

## Debug Module Simplifications

**Current state:** `SubAgent.Debug` provides interactive console debugging with ANSI formatting.

**Keep separate:** Debug serves real-time interactive use; TraceLog serves offline analysis. Different purposes, both needed.

### Potential Enhancements

| Enhancement | Description |
|-------------|-------------|
| `timeline: true` option | Add `print_trace(step, timeline: true)` that calls `Analyzer.print_timeline()` internally |
| Shared formatting | Extract `format_number/1`, `format_duration/1`, `format_bytes/1` to shared module |

### No Changes Needed

| Feature | Reason |
|---------|--------|
| ANSI box-drawing | TraceLog outputs JSONL, not console |
| Compressed view | Requires compression strategy details not in Telemetry |
| print_chain | Specific to interactive debugging |

## Demo Benchmark Simplifications

**Status:** ✅ Complete

The following custom serialization was removed from `Agent.ex` and replaced with TraceLog:

| Component | Status | Replacement |
|-----------|--------|-------------|
| `serialize_turns_for_json/1` | ✅ Removed | TraceLog captures via `turn.stop` events |
| `serialize_tool_calls/1` | ✅ Removed | TraceLog captures via `tool.start/stop` |
| `safe_inspect/1` | ✅ Removed | TraceLog handles serialization |
| `last_trace` state field | ✅ Changed | `last_trace_path` + read from JSONL file |

**Actual change:** -53 lines removed, +47 lines added (net -6 lines)

### Must Keep (Test-Specific Logic)

| Component | Reason |
|-----------|--------|
| Constraint validation | Test-level logic, not execution tracing |
| Pass/fail aggregation | Test results, not SubAgent results |
| Cross-model comparison tables | Report formatting beyond TraceLog scope |
| Retry counting | Requires turn type in Telemetry (see below) |

### Integration Pattern

```elixir
# Before: Custom trace capture
def run_test(query, agent_mod) do
  result = agent_mod.run(query)
  trace = agent_mod.last_trace()  # Custom serialization
  %{result: result, trace: trace}
end

# After: Use TraceLog
def run_test(query, agent_mod) do
  {:ok, result, trace_path} = TraceLog.with_trace(
    fn -> agent_mod.run(query) end,
    path: "traces/test-#{query_id}.jsonl",
    meta: %{query: query, test_type: :single_turn}
  )
  %{result: result, trace_path: trace_path}
end

# Analysis phase
summaries = paths |> Enum.map(&Analyzer.load/1) |> Enum.map(&Analyzer.summary/1)
Analyzer.print_comparison(paths, group_by: :model)
```

### Report Generation

| Current | With TraceLog |
|---------|---------------|
| `Report.generate/2` builds from custom trace | Could read from JSONL via `Analyzer.summary/1` |
| `build_summary/5` aggregates manually | `Analyzer.aggregate/1` provides totals |
| JSON report with custom trace format | JSONL files are already JSON, can reference directly |

## Prerequisites

These TraceLog features are needed for full benchmark integration:

| Feature | Status | Impact |
|---------|--------|--------|
| Turn type in Telemetry | ✅ Complete | Required for retry counting |
| Cost calculation | Spec'd | Required for cost reports |
| Custom metadata | ✅ Complete | Required for test context |
| `aggregate_stream/1` | Spec'd | Required for large test suites |

## Migration Path

1. **Phase 1:** Implement TraceLog core (start/stop, JSONL writing) ✅
2. **Phase 2:** Implement Analyzer (summary, compare, aggregate) ✅
3. **Phase 3:** Add Telemetry enhancements (turn type, program, result_preview) ✅
4. **Phase 4:** Update demo benchmark to use TraceLog ✅
5. **Phase 5:** Remove deprecated custom tracing code from Agent.ex ✅

## Non-Goals

- Replacing Debug.print_trace entirely (different use case)
- Changing test constraint logic (orthogonal to tracing)
- Modifying report Markdown format (keep existing)
