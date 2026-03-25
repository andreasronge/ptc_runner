# Trace Analyzer

An agentic tool that uses ptc_runner to investigate its own execution traces. Ask natural language questions about agent runs and get explanations backed by structured trace data.

## Quick Start

```bash
# From demo/
mix trace_analyze "Which traces are available and which ones failed?"

# Point at a specific trace directory
mix trace_analyze "Why did the planned condition use more tokens?" --trace-dir traces

# Verbose mode shows turns and token usage
mix trace_analyze "Compare the two most recent traces" -v
```

## Usage

```
mix trace_analyze "your question" [options]

Options:
  --trace-dir, -d   Directory containing .jsonl traces (default: traces)
  --max-turns        Maximum agent turns (default: 8)
  --verbose, -v      Show debug output (turns, tokens)
```

### Programmatic

```elixir
{:ok, step} = PtcDemo.TraceAnalyzer.Agent.ask(
  "Find traces where budget was exhausted",
  trace_dir: "traces"
)

IO.puts(step.return)
```

## How It Works

The trace analyzer is a multi-turn SubAgent (PTC-Lisp mode) with six tools organized in two layers. The agent writes PTC-Lisp code to call tools, inspect results, and build an answer across multiple turns.

### Tool Layers

**High-level domain tools** — encode common joins and event semantics:

| Tool | Purpose |
|------|---------|
| `list_traces` | List available traces with status, turns, tokens, trace_kind, query, model. Filter by status, trace_kind, or filename substring. |
| `trace_summary` | Per-turn breakdown: programs, results, tool calls, errors, token usage, plus trace header (kind, query, model). |
| `turn_detail` | Full detail for one turn: program code, tool call args, prints, result. Optional `include_messages: true` for full LLM prompts. |
| `diff_traces` | Compare two traces: token/turn deltas, tool sequence match, first point of divergence. |

**Low-level streaming primitives** — memory-efficient line-by-line file reading for flexible drill-down:

| Tool | Purpose |
|------|---------|
| `query_events` | Filter events with where clauses, project specific fields, paginate. For targeted inspection without loading the full file. |
| `aggregate_events` | Group matching events and compute metrics (count, sum, avg, min, max). For summaries over large traces. |

### query_events

Filter and project events from a trace file. Reads line-by-line — safe for large files.

**Where clause syntax:**
- Exact match: `{"tool_name": "search"}`
- Prefix match: `{"event": "tool.*"}`
- Numeric comparison: `{"duration_ms": ">1000"}`
- Existence check: `{"tool_name": "*"}`

**Select:** List of fields to return. Supports dot paths (e.g., `"data.result"`). Omit to return all fields — use select to avoid large data payloads.

```
query_events("trace.jsonl",
  where: {"event": "tool.stop", "duration_ms": ">500"},
  select: ["tool_name", "duration_ms", "turn"],
  limit: 10)
```

### aggregate_events

Group and aggregate events with streaming computation.

**Metrics:** `"count"`, `"sum(field)"`, `"avg(field)"`, `"min(field)"`, `"max(field)"`

```
aggregate_events("trace.jsonl",
  where: {"event": "turn.stop"},
  group_by: ["turn"],
  metrics: ["sum(total_tokens)", "max(duration_ms)"])
```

### Investigation Flow

The system prompt guides the agent toward a cheap-first exploration strategy:

1. `list_traces` to find relevant files (filter by trace_kind, status)
2. `trace_summary` for overview
3. `turn_detail` for specific turn code or errors
4. `query_events` / `aggregate_events` for flexible drill-down
5. `diff_traces` for comparing runs

### Example Questions

```bash
# Overview
mix trace_analyze "List all benchmark traces and summarize pass/fail rates"
mix trace_analyze "Which models were used and how many traces per model?"

# Filtering by trace kind
mix trace_analyze "Show only benchmark traces that failed"
mix trace_analyze "List all analysis traces"

# Debugging
mix trace_analyze "Why did this run take 3 turns instead of 1?"
mix trace_analyze "Show me what happened on turn 2 of the latest failed trace"

# Performance
mix trace_analyze "Which tool calls took the longest across all traces?"
mix trace_analyze "What is the average token usage per turn?"

# Comparison
mix trace_analyze "Compare the two most recent benchmark traces"
mix trace_analyze "What's different between the planner trace and the executor trace?"

# Flexible queries
mix trace_analyze "Find all events where duration exceeded 2 seconds"
mix trace_analyze "Show token breakdown by event type for the latest trace"
```

## Trace Format (v2)

Traces are JSONL files written by `PtcRunner.TraceLog` using a flat event envelope (schema version 2). Commonly-queried fields are top-level for efficient filtering.

### trace.start — typed header

Every trace starts with a discriminated header:

```json
{
  "schema_version": 2,
  "event": "trace.start",
  "trace_id": "...",
  "seq": 0,
  "trace_kind": "benchmark",
  "producer": "demo.benchmark",
  "trace_label": "Count products",
  "model": "claude-haiku-4-5",
  "query": "How many products are there?",
  "data": { "prompt_profile": "single_shot", "signature": "..." }
}
```

| Field | Description |
|-------|-------------|
| `trace_kind` | Trace type discriminator: `benchmark`, `analysis`, `planning` |
| `producer` | Component that created this trace |
| `trace_label` | Human-readable label (e.g., test case name) |
| `model` | LLM model identifier |
| `query` | Input query or question |
| `data` | Producer-specific metadata |

### Event types

| Event | Key top-level fields |
|-------|---------------------|
| `agent.config` | `agent_id`, `agent_name`, `config` (emitted once per agent) |
| `run.start/stop` | `agent_name`, `agent_id`, `status`, `duration_ms` |
| `turn.start/stop` | `turn`, `duration_ms`, `total_tokens`, `input_tokens`, `output_tokens` |
| `llm.start/stop` | `turn`, `model`, `duration_ms`, tokens |
| `tool.start/stop` | `tool_name`, `turn`, `duration_ms` |
| `pmap.start/stop` | `duration_ms` (parallel execution) |

Bulky payloads (messages, response, program, result, args) are in the `data` bag.

## Generating Traces

Any SubAgent run wrapped in `TraceLog.with_trace` produces traces. The demo benchmark generates them automatically:

```bash
# Run benchmark (generates traces in demo/traces/)
mix benchmark "How many products are there?"

# Run planning benchmark
mix planning --conditions=direct,planned,specified --tests=25 --runs=1

# Then analyze
mix trace_analyze "Summarize what happened in each trace" --trace-dir traces
```

The trace analyzer generates its own traces (prefixed `analyzer_`) so you can inspect how the analyzer itself works.
