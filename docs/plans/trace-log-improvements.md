# TraceLog Improvements

Analysis of `examples/page_index/traces/planner_1770306907.jsonl` — a MetaPlanner run answering "Is 3M capital-intensive?" against a financial document.

## What Happened

The trace captures 45 events across a full MetaPlanner execution:

1. **Planning phase** (7s): LLM generated a plan with 2 agents (`fetcher`, `analyzer`) and 4 tasks
2. **Parallel fetch phase** (3.5s): 3 fetcher tasks ran concurrently — `fetch_balance_sheet`, `fetch_income_statement`, `fetch_cash_flow` — each calling `fetch_section` tool
3. **Synthesis phase** (4.1s): `analyze_capital_intensity` ran in JSON mode, received all 3 results
4. **Final status**: **error** — the analyzer returned `"<UNKNOWN>"` strings where floats were expected, causing a `validation_error`

The fetchers returned the wrong sections (e.g. `fetch_balance_sheet` got "Statement of Changes in Equity", `fetch_cash_flow` got "Note 1: Significant Accounting Policies"). The analyzer couldn't compute ratios and used `"<UNKNOWN>"` placeholders, which failed schema validation.

## What Worked Well

- **Structural completeness**: All 45 events form a coherent trace — `trace.start` through `execution.stop`, with proper nesting (run -> turn -> llm/tool)
- **Span correlation**: Every event has `span_id` and `parent_span_id` in metadata, enabling tree reconstruction
- **Parallel execution visible**: 3 tasks started ~simultaneously, LLM calls overlapped, finished staggered (2.1s, 2.8s, 3.5s)
- **Duration tracking**: `duration_ms` present on all `.stop` events — LLM latencies, tool execution, total task time
- **Token counts**: `measurements.tokens` captured on `llm.stop` events (e.g. 6054, 4164, 4082)
- **Plan structure captured**: `plan.generated` event includes the full plan with task ids, agents, dependencies, and types

## Improvements

### 1. No data in `task.start` input field

Task starts have `task_id` and `agent` but the task `input` is buried inside a nested `task` map in metadata, not surfaced as a top-level field. The input should be a first-class metadata field.

### 2. `run.stop` has no result/return value

`run.stop` for the fetchers shows `step.result: ""` (empty) and `step.status: None`. The actual fetched content is only visible in `tool.stop` result fields. The run's final return value should be captured so you can see what each SubAgent produced.

### 3. No `tool.start` events

There are `tool.stop` events but no corresponding `tool.start` events in the trace. This breaks the expected start/stop symmetry and means tool duration can only be read from `tool.stop.duration_ms`, not computed from event pairs.

### 4. Missing phase/dependency information

`execution.start` doesn't include `phases` — the resolved dependency graph showing which tasks run in parallel vs sequentially. You can infer it from timestamps, but explicit phase info would make the trace self-documenting.

### 5. No LLM prompt/system message in trace

`llm.start` events have only span metadata — no `messages`, `system` prompt, or `model` info. `llm.stop` has `response` (useful), but without the prompt you can't debug why the LLM chose the wrong section IDs. This is the biggest debugging gap.

### 6. Agent config is a giant blob

`run.start` metadata includes the full agent config (prompt, format_options, parsed_signature, etc.) as a deeply nested map. This is useful but noisy. Consider separating agent configuration from runtime context.

### 7. Error chain is hard to follow

The synthesis task failed with `validation_error`, but there's no event connecting why — the fact that fetchers returned wrong sections is only discoverable by reading `tool.stop` results and comparing to task inputs. A task verification or result validation event type would help.

### 8. No `replan` events

The execution ended with `error` and `replan_count: 0`. If replanning was attempted or deliberately skipped, that should be logged.

### 9. Token/cost aggregation not in final event

`execution.stop` has `status` and `results` but no aggregate token count or total LLM cost. You'd need to sum across all `llm.stop` events manually (~18,505 tokens across 5 LLM calls).

### 10. Context passed to synthesis is not logged

The `run.start` for the synthesis task has `context.results` with fetcher outputs, but this is inside the opaque agent config blob. A dedicated event like `task.context_injected` showing what dependency results were passed would be clearer.
