# TraceLog Specification

Structured trace logging for offline analysis and debugging of SubAgent executions.

## Overview

TraceLog captures SubAgent execution events to JSONL files for offline analysis. It integrates with the existing Telemetry system as an optional handler, requiring no changes to SubAgent code.

### Goals

1. **Development debugging** - Understand what happened during agent execution
2. **Performance analysis** - Compare different configurations (presets, models, prompts)
3. **Offline analysis** - Query and visualize traces after execution
4. **Optional adoption** - Zero overhead when not enabled

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
#      llm_calls: 3,
#      tool_calls: 5,
#      tokens: %{input: 4500, output: 890, total: 5390}
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
  "config": {"max_turns": 5, "model": "claude-3-haiku"}
}
```

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
  "tokens": {"input": 4500, "output": 890}
}
```

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
  "tokens": {"input": 3200, "output": 450},
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
  "turn": 1
}
```

#### `turn.stop`
```json
{
  "ts": "2024-01-15T10:30:01.500Z",
  "event": "turn.stop",
  "trace_id": "a1b2c3d4e5f67890",
  "span_id": "22222222",
  "duration_ms": 1400,
  "turn": 1,
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
# Returns: %{duration_ms, turns, llm_calls, tool_calls, tokens: %{input, output, total}}

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
# ┌──────────┬──────────┬───────┬────────┬─────────┐
# │ Preset   │ Duration │ Turns │ Tokens │ Status  │
# ├──────────┼──────────┼───────┼────────┼─────────┤
# │ simple   │ 7.8s     │ 1     │ 620    │ success │
# │ adaptive │ 11.2s    │ 2     │ 1240   │ success │
# │ planned  │ 12.5s    │ 3     │ 1850   │ empty   │
# └──────────┴──────────┴───────┴────────┴─────────┘

# Show slowest operations
mix git.query.analyze traces/my-trace.jsonl --slowest 5
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
| **Tool args/results summarized** | Truncated if >1KB | Large tool data not captured | Acceptable trade-off for memory |
| **No span_id in events** | Not included | Cannot correlate start/stop pairs | TraceLog must track via process dict |
| **No parent_span_id** | Not included | Cannot build hierarchy | TraceLog must track via process dict |

### Recommended Telemetry Enhancements

#### Immediate Follow-up (Strongly Recommended)

**Add span correlation to Telemetry** - Include `span_id` and `parent_span_id` in all telemetry events.

This is the **right architectural fix** that benefits all telemetry consumers:
- Simplifies TraceLog implementation significantly
- Makes APM/observability tools more reliable
- Removes brittle process dictionary tracking
- Enables correlation across any handler

Implementation: Update `PtcRunner.SubAgent.Telemetry.span/3` to generate and propagate span IDs in metadata.

#### Optional Enhancements

1. **Add program to turn.stop** - Pass actual program code in metadata (avoids brittle LLM response parsing)
2. **Add turn result preview** - Include truncated result in turn.stop

### Workarounds (if telemetry not enhanced)

TraceLog can work around gaps, but with caveats:

| Gap | Workaround | Caveat |
|-----|------------|--------|
| Missing program | Parse code block from `llm.stop` response | Brittle - LLMs may format differently, multiple code blocks, etc. |
| Missing result | Get from `run.stop` step.turns | Only available at end, not per-turn |
| No span_id | Track via process dict stack | Works but adds complexity, potential for bugs |

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

## Future Considerations

These are explicitly out of scope for initial implementation but the design should not preclude them:

- **File rotation** - Split files when size exceeds threshold
- **Compression** - Gzip output files
- **Sampling** - Capture only N% of traces
- **Remote storage** - Write to S3 or similar
- **Chrome trace export** - Convert JSONL to chrome://tracing format
- **Cost tracking** - Calculate LLM costs from token counts

## See Also

- [Observability Guide](../guides/subagent-observability.md) - Existing observability features
- [Telemetry Module](../../lib/ptc_runner/sub_agent/telemetry.ex) - Event definitions
- [Git Query README](../../examples/git_query/README.md) - Example application
