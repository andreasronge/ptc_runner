# TraceLog Specification

Structured trace logging for offline analysis and debugging of SubAgent executions.

## Overview

TraceLog captures SubAgent execution events to JSONL files for offline analysis. It integrates with the existing Telemetry system as an optional handler, requiring no changes to SubAgent code.

### Goals

1. **Development debugging** - Understand what happened during agent execution
2. **Performance analysis** - Compare different configurations (presets, models, prompts)
3. **Offline analysis** - Query and visualize traces after execution
4. **Benchmark support** - Aggregate and compare traces across multiple runs/models
5. **Optional adoption** - Zero overhead when not enabled

### Non-Goals

- Production observability (use Telemetry + APM for that)
- Real-time streaming (use Telemetry handlers)
- Log aggregation across multiple processes/nodes

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         SubAgent.run/2                          │
│                              │                                  │
│                              ▼                                  │
│                    ┌─────────────────┐                         │
│                    │    Telemetry    │ (existing)              │
│                    │  event emitter  │                         │
│                    └────────┬────────┘                         │
│                             │                                  │
│              ┌──────────────┼──────────────┐                   │
│              ▼              ▼              ▼                   │
│     ┌──────────────┐ ┌────────────┐ ┌────────────┐            │
│     │ APM handlers │ │ TraceLog   │ │   Custom   │            │
│     │  (existing)  │ │  handler   │ │  handlers  │            │
│     └──────────────┘ └─────┬──────┘ └────────────┘            │
│                            │                                   │
│                            ▼                                   │
│                    ┌──────────────┐                            │
│                    │  JSONL file  │                            │
│                    └──────────────┘                            │
└─────────────────────────────────────────────────────────────────┘

                    Offline Analysis
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │ summary  │ │ timeline │ │ jq/grep  │
        └──────────┘ └──────────┘ └──────────┘
```

## Core Components

### 1. TraceLog (Event Collector)

Telemetry handler that writes events to a JSONL file.

```elixir
# Start collecting (attaches telemetry handlers)
{:ok, collector} = PtcRunner.TraceLog.start(path: "traces/my-trace.jsonl")

# Run your agent (events are captured automatically)
{:ok, step} = SubAgent.run(agent, context)

# Stop collecting (detaches handlers, closes file)
{:ok, path} = PtcRunner.TraceLog.stop(collector)
```

**Convenience wrapper:**

```elixir
# Automatically starts/stops around the function
{:ok, step, trace_path} = PtcRunner.TraceLog.with_trace(
  fn -> SubAgent.run(agent, context) end,
  path: "traces/my-trace.jsonl"
)
```

### 2. TraceLog.Analyzer (Offline Analysis)

Query and analyze JSONL trace files.

```elixir
# Load trace file
events = PtcRunner.TraceLog.Analyzer.load("traces/my-trace.jsonl")

# Get execution summary
summary = PtcRunner.TraceLog.Analyzer.summary(events)
# => %{
#      duration_ms: 5200,
#      turns: 3,
#      retries: 1,
#      llm_calls: 3,
#      tool_calls: 5,
#      tokens: %{input: 4500, output: 890, total: 5390},
#      cost: 0.0123
#    }

# Build span tree (hierarchical view)
tree = PtcRunner.TraceLog.Analyzer.build_tree(events)

# Render ASCII timeline
PtcRunner.TraceLog.Analyzer.print_timeline(events)

# Find slowest operations
slowest = PtcRunner.TraceLog.Analyzer.slowest(events, 5)

# Filter events
llm_events = PtcRunner.TraceLog.Analyzer.filter(events, type: "llm")
```

## JSONL Format

Each line is a self-contained JSON object with these fields:

### Common Fields (All Events)

| Field | Type | Description |
|-------|------|-------------|
| `ts` | ISO8601 string | Event timestamp |
| `event` | string | Event type (e.g., `"llm.start"`, `"tool.stop"`) |
| `trace_id` | string | Unique trace identifier (hex, 16 chars) |
| `span_id` | string | Unique span identifier (hex, 8 chars) |
| `parent_span_id` | string \| null | Parent span for hierarchy |

**Note on span_id length:** 8-character hex IDs (32 bits) provide ~4 billion unique values, sufficient for single execution trees. For production systems with massive traces or long-running collectors, consider 16-character IDs to avoid collisions. The `parent_span_id` linkage provides ordering guarantees independent of ID uniqueness.

### Optional Fields

| Field | Type | Events | Description |
|-------|------|--------|-------------|
| `meta` | object | `run.start` | User-defined metadata (test context, query info, etc.) |
| `type` | string | `turn.*` | Turn type: `"normal"`, `"retry"`, or `"chained"` |
| `cost` | float | `run.stop` | Calculated LLM cost in USD |
| `retries` | integer | `run.stop` | Count of retry turns |
| `parent_trace_id` | string | `run.start` | Parent agent's trace_id (nested agents only) |
| `parent_span_id` | string | `run.start` | Parent's tool.start span_id (nested agents only) |
| `depth` | integer | `run.start` | Nesting level (0 = root, 1 = child, etc.) |
| `child_trace_id` | string | `tool.stop` | Child agent's trace_id (SubAgentTool only) |

### Event-Specific Data

#### `run.start`
```json
{
  "ts": "2024-01-15T10:30:00.000Z",
  "event": "run.start",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "11111111",
  "parent_span_id": null,
  "agent": "planner",
  "config": {"max_turns": 5, "model": "claude-3-haiku"},
  "meta": {"query": "Who contributed most?", "test_type": "single_turn"}
}
```

The `meta` field is optional and can contain arbitrary user-defined context (test metadata, query info, etc.).

#### `run.start` (nested agent)
```json
{
  "ts": "2024-01-15T10:30:01.500Z",
  "event": "run.start",
  "trace_id": "f9e8d7c6b5a43210",
  "span_id": "88888888",
  "parent_span_id": null,
  "parent_trace_id": "a1b2c3d4e5f67890",
  "parent_span_id": "44444444",
  "depth": 1,
  "agent": "researcher",
  "config": {"max_turns": 3, "model": "claude-3-haiku"}
}
```

For nested agents (SubAgentTool), `parent_trace_id` links to the parent agent's trace, and `parent_span_id` links to the parent's `tool.start` span. The `depth` field indicates nesting level (0 = root).

#### `run.stop`
```json
{
  "ts": "2024-01-15T10:30:05.200Z",
  "event": "run.stop",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "11111111",
  "duration_ms": 5200,
  "status": "ok",
  "turns": 3,
  "retries": 1,
  "tokens": {"input": 4500, "output": 890},
  "cost": 0.0123
}
```

The `retries` field counts turns with `type: "retry"`. The `cost` field is calculated from token counts and model pricing (see Cost Calculation below).

#### `run.stop` (error case)
```json
{
  "ts": "2024-01-15T10:30:05.200Z",
  "event": "run.stop",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "11111111",
  "duration_ms": 5200,
  "status": "error",
  "turns": 2,
  "retries": 0,
  "tokens": {"input": 3200, "output": 450},
  "cost": 0.0089,
  "error": {
    "reason": "turn_budget_exhausted",
    "message": "Turn budget exhausted after 2 turns"
  }
}
```

#### `turn.start`
```json
{
  "ts": "2024-01-15T10:30:00.100Z",
  "event": "turn.start",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "22222222",
  "parent_span_id": "11111111",
  "turn": 1,
  "type": "normal"
}
```

The `type` field indicates the turn type: `"normal"`, `"retry"`, or `"chained"`. This enables tracking retry attempts for reliability analysis.

#### `turn.stop`
```json
{
  "ts": "2024-01-15T10:30:01.500Z",
  "event": "turn.stop",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "22222222",
  "duration_ms": 1400,
  "turn": 1,
  "type": "normal",
  "success": true,
  "program": "(get_author_stats)",
  "result_preview": "[{author: \"alice\", commits: 42}, ...]"
}
```

#### `llm.start`
```json
{
  "ts": "2024-01-15T10:30:00.100Z",
  "event": "llm.start",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "33333333",
  "parent_span_id": "22222222",
  "turn": 1,
  "model": "claude-3-haiku",
  "messages": [
    {"role": "system", "content": "You are a git query assistant..."},
    {"role": "user", "content": "Who contributed most this month?"}
  ]
}
```

#### `llm.stop`
```json
{
  "ts": "2024-01-15T10:30:01.400Z",
  "event": "llm.stop",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "33333333",
  "duration_ms": 1300,
  "tokens": {"input": 500, "output": 120},
  "response": "I'll find the top contributor.\n\n```ptc-lisp\n(get_author_stats)\n```"
}
```

#### `tool.start`
```json
{
  "ts": "2024-01-15T10:30:01.410Z",
  "event": "tool.start",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "44444444",
  "parent_span_id": "22222222",
  "tool": "get_author_stats",
  "args": {"since": "2024-01-01"}
}
```

#### `tool.stop`
```json
{
  "ts": "2024-01-15T10:30:01.450Z",
  "event": "tool.stop",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "44444444",
  "duration_ms": 40,
  "tool": "get_author_stats",
  "result": [{"author": "alice", "commits": 42}, {"author": "bob", "commits": 28}]
}
```

#### `tool.stop` (SubAgentTool)
```json
{
  "ts": "2024-01-15T10:30:03.200Z",
  "event": "tool.stop",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "44444444",
  "duration_ms": 1700,
  "tool": "researcher",
  "child_trace_id": "f9e8d7c6b5a43210",
  "result": {"findings": "Alice contributed 42 commits..."}
}
```

When a tool is a `SubAgentTool`, `child_trace_id` links to the child agent's trace file for tree reconstruction.

#### `tool.error`
```json
{
  "ts": "2024-01-15T10:30:01.450Z",
  "event": "tool.error",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "44444444",
  "duration_ms": 40,
  "tool": "get_commits",
  "error": "Invalid date format",
  "args": {"since": "yesterday"}
}
```

### Span Hierarchy Example

```
trace_id: "a1b2c3d4e5f67890"
│
├── run (span: 11111111, parent: null)
│   │
│   ├── turn.1 (span: 22222222, parent: 11111111)
│   │   ├── llm (span: 33333333, parent: 22222222)
│   │   └── tool: get_author_stats (span: 44444444, parent: 22222222)
│   │
│   └── turn.2 (span: 55555555, parent: 11111111)
│       ├── llm (span: 66666666, parent: 55555555)
│       └── tool: get_commits (span: 77777777, parent: 55555555)
```

### Nested Agent Hierarchy

When agents call other agents via `SubAgentTool`, each agent has its own trace file linked by `parent_trace_id` and `child_trace_id`:

```
orchestrator.jsonl (trace_id: "aaaa...", depth: 0)
│
├── run (span: 11111111)
│   ├── turn.1 (span: 22222222)
│   │   ├── llm (span: 33333333)
│   │   └── tool: researcher (span: 44444444)
│   │       │
│   │       └── child_trace_id: "bbbb..." ──────────────────┐
│   │                                                        │
│   └── turn.2 (span: 55555555)                             │
│       ├── llm (span: 66666666)                            │
│       └── tool: summarizer (span: 77777777)               │
│           │                                                │
│           └── child_trace_id: "cccc..." ────────┐         │
                                                   │         │
researcher.jsonl (trace_id: "bbbb...", depth: 1) <─│─────────┘
│  parent_trace_id: "aaaa..."                      │
│  parent_span_id: "44444444"                      │
│                                                   │
├── run (span: 88888888)                           │
│   ├── turn.1: search docs                        │
│   └── turn.2: analyze results                    │
                                                   │
summarizer.jsonl (trace_id: "cccc...", depth: 1) <─┘
│  parent_trace_id: "aaaa..."
│  parent_span_id: "77777777"
│
├── run (span: 99999999)
│   └── turn.1: condense findings
```

**Key points:**
- Each agent writes to its own JSONL file
- `child_trace_id` in `tool.stop` links parent → child
- `parent_trace_id` in `run.start` links child → parent
- `depth` indicates nesting level for easy filtering

### Data Handling

#### Summarization Strategy

Tool args and results are summarized when they exceed 1KB (inherited from existing telemetry behavior in `tool_normalizer.ex`). The summarization format preserves type information:

| Original Value | Summarized Form |
|----------------|-----------------|
| Long list | `"List(42)"` - shows count |
| Large string | `"String(10240 bytes)"` - shows size |
| Large map | Keys preserved, values summarized recursively |
| Nested structures | Recursively summarized |

Example:
```json
{
  "args": {
    "query": "String(2048 bytes)",
    "options": {"limit": 100, "format": "json"}
  },
  "result": "List(500)"
}
```

This approach preserves structure for debugging while preventing memory bloat.

#### Binary Data Handling

Binary data (images, files, raw bytes) cannot be directly serialized to JSON. TraceLog handles binary data as follows:

| Data Type | Handling |
|-----------|----------|
| Binary (raw bytes) | Replaced with `{"__binary__": true, "size": 1024}` |
| Large binary (>10KB) | Same, but also logs warning |
| Bitstrings | Converted to binary, then handled as above |

Example:
```json
{
  "tool": "read_file",
  "result": {"__binary__": true, "size": 102400}
}
```

**Note:** If full binary data is needed for debugging, use the `Step.turns` data which preserves original values.

### Cost Calculation

TraceLog calculates LLM costs from token counts and model pricing. Cost is included in `run.stop` events and `Analyzer.summary()`.

**Pricing lookup:**

```elixir
# Pricing is looked up from model name in config
# Uses PtcRunner.LLMClient pricing data (same as demo benchmark)
cost = (input_tokens * input_price + output_tokens * output_price) / 1_000_000
```

**Fallback behavior:**

| Scenario | Handling |
|----------|----------|
| Model not in pricing table | `cost: null` in output |
| Tokens missing | `cost: null` (distinguishes from "free") |
| Custom/local models | `cost: null` (no pricing available) |

**Provider sensitivity:** Model pricing can differ by provider (e.g., `anthropic/claude-3` vs `bedrock/claude-3`). The cost calculation uses a default pricing table based on model name. If provider-specific pricing is needed, the provider should be included in the model identifier or a custom pricing table should be used (see Future Considerations).

**Cost scoping (local vs recursive):**

| Location | Scope | Description |
|----------|-------|-------------|
| `run.stop.cost` | Local | This agent's tokens only (excludes children) |
| `Analyzer.summary().cost` | Local | Same as `run.stop.cost` |
| `Analyzer.tree_summary().total_cost` | Recursive | Sum of all agents in tree |

This keeps each JSONL file as the "source of truth" for its own execution. Recursive aggregation is handled by tree analysis functions.

**Cost in summary:**

```elixir
# Local cost (this agent only)
summary = Analyzer.summary(events)
# => %{..., cost: 0.0123}

# Aggregate across multiple independent traces
aggregate = Analyzer.aggregate(paths)
# => %{..., total_cost: 1.23, avg_cost: 0.0123}

# Recursive cost (entire agent tree)
{:ok, tree} = Analyzer.load_tree("traces/trace-aaaa.jsonl")
tree_summary = Analyzer.tree_summary(tree)
# => %{..., total_cost: 0.0456}  # includes all nested agents
```

### Custom Metadata

The optional `meta` field in `run.start` allows attaching arbitrary context for later analysis:

```elixir
# Attach metadata when starting trace
{:ok, collector} = TraceLog.start(
  path: "traces/test-1.jsonl",
  meta: %{
    query: "Who contributed most?",
    test_type: "single_turn",
    expected: "alice",
    preset: "adaptive"
  }
)
```

**IMPORTANT:** The `meta` value must be a JSON-encodable map. Anonymous functions, PIDs, references, and non-JSON-serializable Elixir structs will cause serialization errors.

**Recommended keys for benchmarks:**

| Key | Type | Description |
|-----|------|-------------|
| `preset` | string | Configuration preset name (e.g., `"simple"`, `"adaptive"`) |
| `model` | string | Model identifier (for cross-model comparisons) |
| `query` | string | The test query or question |
| `test_type` | string | Test category (e.g., `"single_turn"`, `"multi_turn"`) |
| `expected` | any | Expected result for validation |

Using these standardized keys enables `Analyzer.print_comparison/2` grouping via `group_by: :preset | :model | :query`.

Metadata flows through to:
- `run.start` event (stored in trace)
- `Analyzer.summary()` output (returned in `meta` field)
- `Analyzer.compare()` output (for grouping/filtering)

This enables benchmark scenarios where test context must be preserved for later analysis.

## API Reference

### PtcRunner.TraceLog

```elixir
@moduledoc """
Telemetry-based trace collector that writes to JSONL files.

## Usage

    # Manual start/stop
    {:ok, collector} = TraceLog.start(path: "trace.jsonl")
    SubAgent.run(agent, context)
    {:ok, path} = TraceLog.stop(collector)

    # Convenience wrapper
    {:ok, result, path} = TraceLog.with_trace(fn ->
      SubAgent.run(agent, context)
    end)
"""

@type collector :: pid()

@doc "Start collecting telemetry events to a JSONL file"
@spec start(keyword()) :: {:ok, collector()} | {:error, term()}
def start(opts \\ [])
# Options:
#   - path: string - Output file path (default: "traces/{timestamp}.jsonl")
#   - meta: map - Custom metadata to attach to run.start event (default: nil)
#
# Default path is relative to CWD. The traces/ directory is created if needed.
# Timestamp format: "traces/2024-01-15T10-30-00.jsonl"

@doc "Stop collecting and close the file"
@spec stop(collector()) :: {:ok, Path.t()} | {:error, term()}
def stop(collector)

@doc """
Run function with automatic trace collection.

IMPORTANT: Uses try/after to guarantee cleanup even if the function crashes.
The collector is always stopped and the file descriptor is always closed.

Supports nested calls - each with_trace creates its own trace file and
maintains a separate span stack.
"""
@spec with_trace((-> result), keyword()) :: {:ok, result, Path.t()} | {:error, term()}
      when result: term()
def with_trace(fun, opts \\ [])
# Implementation MUST use try/after:
#
#   {:ok, collector} = start(opts)
#   try do
#     result = fun.()
#     {:ok, result, path}
#   after
#     stop(collector)
#   end
```

### PtcRunner.TraceLog.Analyzer

```elixir
@moduledoc """
Analyze JSONL trace files offline.

## Usage

    events = Analyzer.load("trace.jsonl")
    Analyzer.print_timeline(events)
    Analyzer.summary(events)
"""

@type event :: map()
@type events :: [event()]

@doc "Load events from a JSONL file"
@spec load(Path.t()) :: events()
def load(path)

@doc "Get execution summary statistics"
@spec summary(events()) :: map()
def summary(events)
# Returns: %{
#   duration_ms: integer,
#   turns: integer,
#   retries: integer,
#   llm_calls: integer,
#   tool_calls: integer,
#   tokens: %{input: integer, output: integer, total: integer},
#   cost: float,            # local cost only (this agent)
#   model: string | nil,
#   status: "ok" | "error",
#   meta: map | nil
# }
#
# Key naming convention: summary(), tree_summary(), and aggregate() use
# consistent key names for common metrics (tokens, turns, cost, duration_ms)
# to enable interchangeable use by reporting tools.

@doc "Build hierarchical span tree"
@spec build_tree(events()) :: [map()]
def build_tree(events)

@doc "Print ASCII timeline to stdout"
@spec print_timeline(events(), keyword()) :: :ok
def print_timeline(events, opts \\ [])
# Options:
#   - width: integer - Terminal width (default: 80)
#   - show_tokens: boolean - Include token counts (default: false)

@doc "Get N slowest operations"
@spec slowest(events(), pos_integer()) :: [event()]
def slowest(events, n \\ 5)

@doc "Filter events by criteria"
@spec filter(events(), keyword()) :: events()
def filter(events, criteria)
# Criteria:
#   - type: string - Event type prefix (e.g., "llm", "tool")
#   - span_id: string - Specific span
#   - min_duration_ms: integer - Minimum duration

@doc "Compare multiple trace files side by side"
@spec compare([Path.t() | {label :: String.t(), Path.t()}]) :: [map()]
def compare(paths)
# Accepts either plain paths or {label, path} tuples for readable output.
# Returns list of summaries with trace file info for tabular comparison.
#
# Example with labels:
# compare([{"Haiku", "trace1.jsonl"}, {"Sonnet", "trace2.jsonl"}])
#
# Example output:
# [
#   %{label: "Haiku", path: "trace1.jsonl", duration_ms: 7800, turns: 1, cost: 0.01, status: "ok"},
#   %{label: "Sonnet", path: "trace2.jsonl", duration_ms: 11200, turns: 2, cost: 0.02, status: "ok"}
# ]

@doc "Aggregate statistics across multiple trace files"
@spec aggregate([Path.t()]) :: map()
def aggregate(paths)
# Combines statistics from multiple traces into totals and averages.
#
# NOTE: This loads all events into memory. For very large trace sets (100+ files),
# consider using aggregate_stream/1 or processing in batches.
#
# Returns: %{
#   traces: integer,
#   total_duration_ms: integer,
#   avg_duration_ms: float,
#   total_turns: integer,
#   avg_turns: float,
#   total_retries: integer,
#   total_tokens: %{input: integer, output: integer, total: integer},
#   total_cost: float,
#   success_count: integer,
#   error_count: integer,
#   success_rate: float
# }

@doc "Stream-based aggregation for large trace sets"
@spec aggregate_stream([Path.t()]) :: map()
def aggregate_stream(paths)
# Memory-efficient alternative to aggregate/1. Processes one file at a time,
# extracting only run.stop events for statistics. Use for 100+ trace files.

@doc "Print comparison table to stdout"
@spec print_comparison([Path.t()], keyword()) :: :ok
def print_comparison(paths, opts \\ [])
# Options:
#   - group_by: :preset | :model | :query - Group traces by metadata field
#   - sort_by: :duration | :tokens | :cost - Sort order (default: :duration)

# ============================================================
# Nested Agent Tree Analysis
# ============================================================

@type tree :: %{
  root: events(),
  children: %{trace_id => tree()},
  metadata: %{
    total_agents: integer,
    max_depth: integer,
    trace_ids: [String.t()]
  }
}

@doc "Load execution tree starting from root trace file"
@spec load_tree(Path.t()) :: {:ok, tree()} | {:error, term()}
def load_tree(root_path)
# Recursively loads child traces by following child_trace_id links.
# Returns tree structure with all agents' events.
#
# Options:
#   - dir: directory to search for child traces (default: same as root)
#   - max_depth: maximum nesting depth to load (default: 10)
#
# Example:
#   {:ok, tree} = Analyzer.load_tree("traces/orchestrator.jsonl")
#   tree.metadata.total_agents  # => 3

@doc "Get all agents in execution tree"
@spec agents(tree()) :: [map()]
def agents(tree)
# Returns flat list of agent summaries from the tree.
#
# Example output:
# [
#   %{trace_id: "aaaa", agent: "orchestrator", depth: 0, duration_ms: 15200},
#   %{trace_id: "bbbb", agent: "researcher", depth: 1, duration_ms: 8300},
#   %{trace_id: "cccc", agent: "summarizer", depth: 1, duration_ms: 4100}
# ]

@doc "Aggregate statistics across entire execution tree"
@spec tree_summary(tree()) :: map()
def tree_summary(tree)
# Returns: %{
#   total_agents: integer,
#   total_turns: integer,
#   total_llm_calls: integer,
#   total_tool_calls: integer,
#   total_tokens: %{input: integer, output: integer, total: integer},
#   total_cost: float,        # recursive (sum of all agents)
#   total_duration_ms: integer,
#   max_depth: integer,
#   parallel_agents: integer  # agents that ran concurrently
# }
#
# Note: Uses `total_` prefix to distinguish recursive aggregates from
# single-agent metrics in summary(). The nested tokens/turns/cost are
# sums across all agents in the tree.

@doc "Find critical path (longest chain of sequential dependencies)"
@spec critical_path(tree()) :: [map()]
def critical_path(tree)
# Returns list of agents on the critical path (slowest sequential chain).
# Useful for identifying optimization opportunities.
#
# Parallel span handling: When a parent waits for multiple children in parallel,
# only the slowest child is included in the critical path. For example:
#
#   orchestrator (waits for A, B, C in parallel)
#   ├── agent_a: 5s
#   ├── agent_b: 8s  ← included in critical path (slowest)
#   └── agent_c: 3s
#
# The critical path would be: [orchestrator_before, agent_b, orchestrator_after]

@doc "Print tree visualization to stdout"
@spec print_tree(tree(), keyword()) :: :ok
def print_tree(tree, opts \\ [])
# Options:
#   - show_turns: boolean - Show individual turns (default: false)
#   - show_tokens: boolean - Show token counts (default: false)
#   - width: integer - Terminal width (default: 80)
#
# Example output:
#
# Execution Tree (3 agents, 8 turns, 15.2s)
# ═══════════════════════════════════════════
# orchestrator [aaaa] ████████████████████████████████████ 15.2s
# ├── turn 1: plan query
# ├── turn 2: delegate to researcher
# │   └── researcher [bbbb] ████████████░░░░░░░░░░░░░░░░░░ 8.3s
# │       ├── turn 1: search docs
# │       └── turn 2: return findings
# └── turn 3: summarize
#     └── summarizer [cccc] ░░░░░░░░░░░░████████░░░░░░░░░░ 4.1s
#         └── turn 1: condense
```

## Git Query Integration

Git Query serves as the reference implementation showing how to use TraceLog.

### CLI Options

```bash
# Basic trace (writes to traces/{timestamp}.jsonl)
mix git.query "commits from last week" --trace

# Custom trace path
mix git.query "commits from last week" --trace traces/experiment1.jsonl

# Trace with immediate summary output
mix git.query "commits from last week" --trace --trace-summary

# Trace with timeline output
mix git.query "commits from last week" --trace --trace-timeline
```

### Benchmark Integration

```bash
# Run benchmark with traces for each preset
mix git.query --benchmark --trace

# Output structure:
# traces/
#   benchmark-2024-01-15/
#     simple-q1.jsonl
#     simple-q2.jsonl
#     adaptive-q1.jsonl
#     adaptive-q2.jsonl
#     ...
```

### Analysis Task

`mix git.query.analyze` is a **separate mix task** for offline analysis of trace files.
It reads JSONL files and produces analysis output - it does not run queries.

```bash
# Summary of a single trace
mix git.query.analyze traces/my-trace.jsonl
# Output:
# Trace: my-trace.jsonl
# Duration: 5.2s | Turns: 3 | LLM calls: 3 | Tool calls: 5
# Tokens: 4500 in / 890 out / 5390 total

# Timeline view
mix git.query.analyze traces/my-trace.jsonl --timeline
# Output:
# run ████████████████████████████████████████ 5200ms
#   turn.1 ████████████████                     2300ms
#     llm  ██████████████                       2100ms (500→120 tokens)
#     tool ░█                                     50ms get_author_stats
#   turn.2                 ████████████████     2000ms
#     llm                  ███████████████      1800ms (800→180 tokens)

# Compare multiple traces (e.g., different presets)
mix git.query.analyze traces/benchmark-2024-01-15/*.jsonl --compare
# Output:
# Query: "commits from last week"
# ┌──────────┬──────────┬───────┬─────────┬────────┬──────────┐
# │ Preset   │ Duration │ Turns │ Retries │ Tokens │ Cost     │
# ├──────────┼──────────┼───────┼─────────┼────────┼──────────┤
# │ simple   │ 7.8s     │ 1     │ 0       │ 620    │ $0.0012  │
# │ adaptive │ 11.2s    │ 2     │ 1       │ 1240   │ $0.0024  │
# │ planned  │ 12.5s    │ 3     │ 0       │ 1850   │ $0.0036  │
# └──────────┴──────────┴───────┴─────────┴────────┴──────────┘

# Aggregate statistics across multiple traces
mix git.query.analyze traces/benchmark-2024-01-15/*.jsonl --aggregate
# Output:
# Aggregate Statistics (15 traces)
# ─────────────────────────────────
# Total duration:  142.5s
# Avg duration:    9.5s
# Total tokens:    18,500
# Total cost:      $0.037
# Success rate:    93.3% (14/15)
# Total retries:   3

# Show slowest operations
mix git.query.analyze traces/my-trace.jsonl --slowest 5

# Nested agent tree visualization
mix git.query.analyze traces/orchestrator.jsonl --tree
# Output:
# Execution Tree (3 agents, 8 turns, 15.2s, $0.042)
# ═══════════════════════════════════════════════════
# orchestrator [aaaa] ████████████████████████████████████ 15.2s
# ├── turn 1: plan query
# ├── turn 2: delegate to researcher
# │   └── researcher [bbbb] ████████████░░░░░░░░░░░░░░░░░░ 8.3s
# │       ├── turn 1: search docs
# │       └── turn 2: return findings
# └── turn 3: summarize
#     └── summarizer [cccc] ░░░░░░░░░░░░████████░░░░░░░░░░ 4.1s
#         └── turn 1: condense

# Tree summary statistics
mix git.query.analyze traces/orchestrator.jsonl --tree-summary
# Output:
# Tree Summary
# ────────────────────
# Agents:        3
# Max depth:     1
# Total turns:   8
# Total tokens:  12,400
# Total cost:    $0.042
# Critical path: orchestrator → researcher (23.5s)

# Show critical path (slowest sequential chain)
mix git.query.analyze traces/orchestrator.jsonl --critical-path
# Output:
# Critical Path (23.5s total)
# 1. orchestrator [aaaa] turn 1-2   8.2s
# 2. researcher [bbbb] turn 1-2     8.3s
# 3. orchestrator [aaaa] turn 3     7.0s
```

### Programmatic Usage

```elixir
# In git_query pipeline
defmodule GitQuery.Pipeline do
  def run(question, opts) do
    if opts[:trace] do
      PtcRunner.TraceLog.with_trace(
        fn -> do_run(question, opts) end,
        path: opts[:trace_path] || default_trace_path()
      )
    else
      {:ok, do_run(question, opts), nil}
    end
  end
end
```

## Implementation Notes

### Telemetry Integration

TraceLog attaches to these existing telemetry events:

| Event | Data Captured |
|-------|---------------|
| `[:ptc_runner, :sub_agent, :run, :start]` | Agent name, context |
| `[:ptc_runner, :sub_agent, :run, :stop]` | Duration, status, full step |
| `[:ptc_runner, :sub_agent, :turn, :start]` | Turn number |
| `[:ptc_runner, :sub_agent, :turn, :stop]` | Duration, tokens |
| `[:ptc_runner, :sub_agent, :llm, :start]` | Turn, full messages array |
| `[:ptc_runner, :sub_agent, :llm, :stop]` | Duration, tokens, full response |
| `[:ptc_runner, :sub_agent, :tool, :start]` | Tool name, args (summarized if >1KB) |
| `[:ptc_runner, :sub_agent, :tool, :stop]` | Duration, result (summarized if >1KB) |
| `[:ptc_runner, :sub_agent, :tool, :exception]` | Duration, kind, reason, stacktrace |

### Current Telemetry Gaps

The existing telemetry events have some gaps that affect trace completeness:

| Gap | Current State | Impact | Workaround |
|-----|---------------|--------|------------|
| **turn.stop missing program** | `program: nil` always | Cannot see which PTC-Lisp code executed per turn | Extract from `llm.stop` response (brittle) |
| **turn.stop missing result** | Not included | Cannot see turn execution result | Use `run.stop` step.turns |
| **turn type not included** | Not in telemetry | Cannot track retries | Count from step.turns post-hoc |
| **Tool args/results summarized** | Truncated if >1KB | Large tool data not captured | Acceptable trade-off for memory |
| **No span_id in events** | Not included | Cannot correlate start/stop pairs | TraceLog must track via process dict |
| **No parent_span_id** | Not included | Cannot build hierarchy | TraceLog must track via process dict |
| **No nested agent context** | Not propagated | Cannot link parent/child traces | Must pass context manually via SubAgent.run opts |

### Recommended Telemetry Enhancements

#### Immediate Follow-up (Strongly Recommended)

**Add span correlation to Telemetry** - Include `span_id` and `parent_span_id` in all telemetry events.

This is the **right architectural fix** that benefits all telemetry consumers:
- Simplifies TraceLog implementation significantly
- Makes APM/observability tools more reliable
- Removes brittle process dictionary tracking
- Enables correlation across any handler

Implementation: Update `PtcRunner.SubAgent.Telemetry.span/3` to generate and propagate span IDs in metadata.

#### High Priority Enhancements (turn.stop)

These enhancements to `[:ptc_runner, :sub_agent, :turn, :stop]` are strongly recommended for TraceLog stability:

1. **Add `program`** - Pass actual program code in metadata (avoids brittle LLM response parsing)
2. **Add `result_preview`** - Include truncated result for per-turn debugging
3. **Add `type`** - Include turn type (`:normal`, `:retry`, `:chained`) for retry tracking

Without these, TraceLog must use fragile workarounds that are prone to parsing errors. Implementing these in Telemetry makes TraceLog much simpler and more reliable.

#### Nested Agent Context Propagation

For nested SubAgentTool execution, add trace context to `SubAgent.run/2` options:

```elixir
# When calling SubAgent.run for a nested agent:
SubAgent.run(agent, context,
  trace_context: %{
    parent_trace_id: "aaaa...",
    parent_span_id: "44444444",
    depth: 1
  }
)
```

This allows TraceLog to automatically include `parent_trace_id`, `parent_span_id`, and `depth` in `run.start` events without manual propagation.

### Workarounds (if telemetry not enhanced)

TraceLog can work around gaps, but with caveats:

| Gap | Workaround | Caveat |
|-----|------------|--------|
| Missing program | Parse code block from `llm.stop` response | Brittle - LLMs may format differently, multiple code blocks, etc. |
| Missing result | Get from `run.stop` step.turns | Only available at end, not per-turn |
| Missing turn type | Count from `run.stop` step.turns | Only available at end; cannot track per-turn |
| No span_id | Track via process dict stack | Works but adds complexity, potential for bugs |

### Nested Agent Tracing

When a SubAgentTool is invoked, the child agent needs trace context from the parent.

**Context propagation:**

```elixir
# Parent agent's tool execution passes context to child
defp execute_sub_agent_tool(tool, args, trace_context) do
  child_opts = [
    parent_trace_id: trace_context.trace_id,
    parent_span_id: trace_context.current_span_id,
    depth: trace_context.depth + 1
  ]

  # Child creates its own JSONL file
  child_path = "#{trace_dir}/#{tool.agent.name}-#{generate_id()}.jsonl"

  {:ok, result, child_trace_id} = TraceLog.with_trace(
    fn -> SubAgent.run(tool.agent, args) end,
    path: child_path,
    context: child_opts
  )

  # Return child_trace_id for linking in tool.stop
  {result, child_trace_id}
end
```

**File naming convention:**

To enable fast tree discovery, use a standardized filename pattern:

```
trace-{trace_id}.jsonl
```

This allows `load_tree/1` to find children via simple glob: `trace-{child_trace_id}.jsonl`.

```
traces/
  trace-aaaa1111bbbb2222.jsonl    # root (orchestrator)
  trace-cccc3333dddd4444.jsonl    # child (researcher)
  trace-eeee5555ffff6666.jsonl    # child (summarizer)
```

**Tree discovery algorithm:**

```elixir
def load_tree(root_path, opts \\ []) do
  dir = opts[:dir] || Path.dirname(root_path)
  max_depth = opts[:max_depth] || 10

  case load_tree_recursive(root_path, dir, max_depth, 0, MapSet.new(), []) do
    {:ok, tree, []} -> {:ok, tree}
    {:ok, tree, warnings} -> {:ok, tree, warnings: warnings}
    {:error, reason} -> {:error, reason}
  end
end

defp load_tree_recursive(path, dir, max_depth, depth, visited, warnings) do
  cond do
    path in visited ->
      {:ok, nil, ["Cycle detected: #{path}" | warnings]}

    depth > max_depth ->
      {:ok, nil, ["Max depth exceeded at: #{path}" | warnings]}

    true ->
      events = load(path)
      child_trace_ids = extract_child_trace_ids(events)

      # Standardized filename lookup
      {children, new_warnings} =
        child_trace_ids
        |> Enum.map(fn id -> Path.join(dir, "trace-#{id}.jsonl") end)
        |> Enum.reduce({%{}, warnings}, fn child_path, {acc, warns} ->
          if File.exists?(child_path) do
            case load_tree_recursive(child_path, dir, max_depth, depth + 1, MapSet.put(visited, path), warns) do
              {:ok, child_tree, child_warns} -> {Map.put(acc, child_path, child_tree), child_warns}
              {:error, _} = err -> {acc, ["Failed to load #{child_path}" | warns]}
            end
          else
            # Try orphan discovery (child claims this parent)
            {acc, ["Missing child trace: #{child_path}" | warns]}
          end
        end)

      {:ok, %{root: events, children: children}, new_warnings}
  end
end
```

**Orphan healing:** If `child_trace_id` is missing from parent's `tool.stop` (e.g., crash), the analyzer can discover orphans by scanning for traces where `parent_trace_id` matches the current trace.

**Edge cases:**

| Case | Handling |
|------|----------|
| Missing child trace file | Warn and continue with partial tree |
| Circular reference | Detect via visited set, warn and skip |
| Deep nesting (>10) | Configurable max_depth, warn and return partial |
| Parallel children | All loaded, sorted by start time |
| Orphan traces | Discover via `parent_trace_id` scan if `child_trace_id` missing |
| Child crash mid-execution | Parent's `tool.stop` may lack `child_trace_id`; use orphan healing |

### Span ID Tracking

Span IDs are tracked via process dictionary using a **stack-based approach** to support nested traces and prevent key collisions:

```elixir
# Process dictionary keys are collector-scoped to support nested with_trace calls
@span_stack_key {:ptc_trace_span_stack, collector_id}
@span_start_key {:ptc_trace_span_start, collector_id}

# On :start event - push to stack
defp push_span(collector_id) do
  span_id = generate_span_id()
  stack = Process.get({:ptc_trace_span_stack, collector_id}, [])
  parent_id = List.first(stack)

  Process.put({:ptc_trace_span_stack, collector_id}, [span_id | stack])
  Process.put({:ptc_trace_span_start, collector_id, span_id}, System.monotonic_time())

  {span_id, parent_id}
end

# On :stop event - pop from stack
defp pop_span(collector_id) do
  stack = Process.get({:ptc_trace_span_stack, collector_id}, [])

  case stack do
    [span_id | rest] ->
      start_time = Process.delete({:ptc_trace_span_start, collector_id, span_id})
      Process.put({:ptc_trace_span_stack, collector_id}, rest)
      duration = System.monotonic_time() - start_time
      {span_id, duration}

    [] ->
      {nil, 0}  # Unbalanced stop - should not happen
  end
end
```

**Why stack-based:**
- Supports nested `with_trace` calls (each gets its own collector_id)
- Prevents key collisions when multiple traces are active
- Correctly handles interleaved start/stop events within a trace

### File Writing

Events are written synchronously with buffered IO for simplicity.

**IMPORTANT: Error Resilience**

Telemetry handlers must never crash the caller. File system errors (disk full, permissions) are caught and logged but do not propagate:

```elixir
def handle_event(event, measurements, metadata, %{file: file} = state) do
  line = build_event_json(event, measurements, metadata, state)

  try do
    IO.write(file, line <> "\n")
    state
  rescue
    e ->
      # Log warning but don't crash - tracing is best-effort
      Logger.warning("TraceLog write failed: #{inspect(e)}")
      %{state | write_errors: state.write_errors + 1}
  end
end
```

On `stop/1`, if write errors occurred, return `{:ok, path, warnings: n}` to inform the caller that the trace may be incomplete.

### Process Isolation

Each `TraceLog.start/1` creates an isolated collector:
- Generates unique trace_id
- Attaches telemetry handlers with collector-specific state
- Only captures events from the calling process (via process dictionary check)

**Parallel benchmark limitation:** If a benchmark runner uses `Task.async` or `Task.async_stream` to run tests in parallel, the TraceLog collector won't see events from worker processes. This is by design to prevent interleaved output from concurrent traces.

**Workarounds for parallel execution:**

| Approach | Trade-off |
|----------|-----------|
| Sequential execution | Simple, no changes needed, slower |
| One trace file per test | Each parallel task uses its own `with_trace`, aggregate after |
| Propagate trace_id | Modify collector to accept events with matching `trace_id` from any process (requires implementation change) |

For most benchmark use cases, "one trace file per test" with post-hoc aggregation via `Analyzer.aggregate/1` is recommended.

### Parallel Sub-Agent Pattern

When a parent SubAgent needs to call multiple SubAgentTools in parallel (e.g., searching multiple data sources), special care is needed to ensure all child traces are captured.

**The problem:** If children run via `Task.async`, they execute in separate processes. The parent's TraceLog collector won't see their telemetry events.

**Recommended pattern:**

```elixir
defmodule ParallelAgentRunner do
  @doc """
  Run multiple SubAgentTools in parallel, each with its own trace file.
  Returns results with child_trace_ids for linking.
  """
  def run_parallel(tools, args_list, parent_context) do
    trace_dir = parent_context.trace_dir

    tools
    |> Enum.zip(args_list)
    |> Task.async_stream(fn {tool, args} ->
      # Each child gets its own trace file
      child_trace_id = generate_trace_id()
      child_path = Path.join(trace_dir, "trace-#{child_trace_id}.jsonl")

      {:ok, result, _path} = TraceLog.with_trace(
        fn -> SubAgent.run(tool.agent, args) end,
        path: child_path,
        context: %{
          parent_trace_id: parent_context.trace_id,
          parent_span_id: parent_context.current_span_id,
          depth: parent_context.depth + 1
        }
      )

      {result, child_trace_id}
    end, max_concurrency: 5, timeout: 60_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end
end
```

**Key points:**
- Each parallel child creates its own JSONL file
- Child trace context is passed via `with_trace/2` options
- Parent records `child_trace_id` in each `tool.stop` event
- `load_tree/1` discovers all children via `child_trace_id` links
- Timeline visualization shows parallel children with overlapping bars

### Span Stack Crash Recovery

If a crash occurs inside a nested call and the `:stop` event is never emitted, the process dictionary span stack may become unbalanced. The `with_trace/2` wrapper mitigates this at the top level via `try/after`, but internal telemetry events cannot be guaranteed.

**Behavior on unbalanced stack:**
- `pop_span/1` returns `{nil, 0}` for extra stops (logged as warning)
- Orphaned spans remain in process dict until process terminates (minimal leak)

If strict span accounting is required, consider clearing the span stack in `TraceLog.stop/1`.

## Future Considerations

These are explicitly out of scope for initial implementation but the design should not preclude them:

- **File rotation** - Split files when size exceeds threshold
- **Compression** - Gzip output files
- **Sampling** - Capture only N% of traces
- **Remote storage** - Write to S3 or similar
- **Chrome trace export** - Convert JSONL to chrome://tracing format
- **Custom pricing tables** - Allow users to provide pricing for custom/local models

## See Also

- [Observability Guide](../guides/subagent-observability.md) - Existing observability features
- [Telemetry Module](../../lib/ptc_runner/sub_agent/telemetry.ex) - Event definitions
- [Git Query README](../../examples/git_query/README.md) - Example application
