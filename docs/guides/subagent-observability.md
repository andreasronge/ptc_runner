# Observability

Integrate SubAgent with logging, metrics, and debugging tools.

## Tracing Overview

PtcRunner provides three complementary tracing layers. Each serves a different workflow:

| Mechanism | Use Case | Output |
|-----------|----------|--------|
| `PtcRunner.Tracer.new/1` | Aggregate usage stats, inspect traces in code | In-memory struct on `Step` |
| `PtcRunner.TraceLog.with_trace/2` | Offline debugging, performance analysis, Chrome DevTools | JSONL files |
| `PtcRunner.PlanTracer.log_event/1` | Watch PlanExecutor runs in the terminal | ANSI-colored terminal output |

**Data flow:**

```
SubAgent.Loop
  ├── emits :telemetry events ──► TraceLog.Handler ──► Collector ──► .jsonl file
  ├── builds Tracer struct ────► entries stored on Step.tracer
  └── (via PlanExecutor)
        └── fires on_event callbacks ──► PlanTracer ──► terminal output
```

Tracer and TraceLog operate independently — you can use both, either, or neither.

## Turn History

Every `Step` includes a `turns` field with immutable per-turn execution history:

```elixir
{:ok, step} = SubAgent.run(agent, llm: llm)

for turn <- step.turns do
  IO.puts("Turn #{turn.number}: #{turn.program}")
  IO.puts("  Tools: #{inspect(Enum.map(turn.tool_calls, & &1.name))}")
end

# Aggregated metrics
step.usage.duration_ms
step.usage.total_tokens
```

Each `Turn` struct captures:
- `number` - Turn index (1-based)
- `raw_response` - Full LLM output including reasoning
- `program` - Extracted PTC-Lisp code
- `result` - Execution result
- `prints` - Output from `println` calls
- `tool_calls` - Tools invoked with args and results
- `memory` - State snapshot after this turn
- `success?` - Whether the turn succeeded

## Debug Mode

Use `print_trace/2` to visualize execution:

```elixir
{:ok, step} = SubAgent.run(agent, llm: llm)

# Default: show programs and results
SubAgent.Debug.print_trace(step)

# Include raw LLM output (reasoning/commentary)
SubAgent.Debug.print_trace(step, raw: true)

# Show what the LLM sees (compressed format)
SubAgent.Debug.print_trace(step, view: :compressed)

# Show actual messages sent to LLM
SubAgent.Debug.print_trace(step, messages: true)

# Include token usage
SubAgent.Debug.print_trace(step, usage: true)
```

### View Options

| Option | Description |
|--------|-------------|
| `view: :turns` | (default) Show programs + results from Turn structs |
| `view: :compressed` | Show what LLM sees when compression is enabled |
| `raw: true` | Include `raw_response` in turns view |
| `messages: true` | Show full messages sent to LLM each turn |
| `usage: true` | Add token statistics after trace |
| `system: :section` | Show a system prompt section (e.g., `:mission`) |
| `system: :all` | Show the full system prompt per turn |

Options can be combined: `print_trace(step, messages: true, usage: true)`.

### System Prompt Sections

Inspect specific sections of the system prompt by markdown header:

```elixir
Debug.print_trace(step, system: :mission)       # just the Mission section
Debug.print_trace(step, system: :mission_log)    # just the Mission Log
Debug.print_trace(step, system: :all)            # full system prompt
Debug.print_trace(step, system: :nope)           # lists available section names
```

Sections are parsed from both system prompt and user messages. Known sections: `:role`, `:ptc_lisp`, `:output_format`, `:mission`, `:mission_log`, `:expected_output`, `:error`. Unrecognized headers are converted to snake_case atoms.

> **Full API:** See `PtcRunner.SubAgent.Debug.print_trace/2`.

## Trace Filtering

Control trace collection for production optimization:

```elixir
# Only keep trace on failure
SubAgent.run(agent, llm: llm, trace: :on_error)

# Disable tracing entirely
SubAgent.run(agent, llm: llm, trace: false)
```

## Message Compression

By default, multi-turn agents send full conversation history to the LLM. Enable compression to reduce token usage:

```elixir
SubAgent.run(agent, llm: llm, compression: true)
```

To see what the LLM receives with compression:

```elixir
SubAgent.Debug.print_trace(step, view: :compressed)
```

Full turn history is always preserved in `step.turns` regardless of compression.

> **Full guide:** See [Message Compression](subagent-compression.md) for details on how compression works and implementing custom strategies.

## TraceLog

For detailed offline analysis, use `PtcRunner.TraceLog.with_trace/2` to capture execution events to JSONL files:

```elixir
alias PtcRunner.TraceLog

# Capture a trace (recommended)
{:ok, step, trace_path} = TraceLog.with_trace(fn ->
  SubAgent.run(agent, llm: my_llm())
end)

# With custom path and metadata
{:ok, step, path} = TraceLog.with_trace(
  fn -> SubAgent.run(agent, llm: my_llm()) end,
  path: "traces/debug.jsonl",
  meta: %{query: "test query", preset: "simple"}
)
```

### Analyzing Traces

Use `PtcRunner.TraceLog.Analyzer.load/1` and related functions to inspect captured traces:

```elixir
alias PtcRunner.TraceLog.Analyzer

# Load and summarize
events = Analyzer.load(trace_path)
summary = Analyzer.summary(events)
# => %{duration_ms: 1234, turns: 3, llm_calls: 3, tool_calls: 5, tokens: %{...}}

# Find slowest operations
Analyzer.slowest(events, 5)

# Filter by event type
Analyzer.filter(events, type: "llm")
Analyzer.filter(events, min_duration_ms: 100)

# Print timeline
Analyzer.print_timeline(events)
# [0ms] run.start
# [10ms] turn.start
# [15ms] llm.start
# [850ms] llm.stop (835ms)
# ...
```

### Use Cases

- **Debugging** - Understand what happened during agent execution
- **Performance analysis** - Identify slow LLM calls or bottlenecks
- **Comparison** - Compare traces across different configurations or models

### Chrome DevTools Export

Export traces to Chrome Trace Event format for flame chart visualization:

```elixir
alias PtcRunner.TraceLog.Analyzer

{:ok, tree} = Analyzer.load_tree("trace.jsonl")
:ok = Analyzer.export_chrome_trace(tree, "trace.json")
```

Then view in Chrome:
1. Open DevTools (F12) → **Performance** tab → **Load profile...**
2. Or navigate to `chrome://tracing` and load the file

The flame chart shows execution timing with nested spans. Click any span to see details including arguments and results.

### Interactive Trace Viewer

Launch the web-based trace viewer to browse traces with DAG visualization and turn-by-turn drill-down:

```bash
mix ptc.viewer --trace-dir traces --plan-dir data
```

| Option | Default | Description |
|--------|---------|-------------|
| `--port` | 4123 | Port to listen on |
| `--trace-dir` | `traces` | Directory containing `.jsonl` trace files |
| `--plan-dir` | `data` | Directory containing `.json` plan files |
| `--no-open` | false | Don't auto-open browser |

The viewer is a separate package (`ptc_viewer`). See its README for architecture and drag-and-drop usage.

### Configuration

TraceLog sanitization limits are configurable via application config:

| Key | Default | Description |
|-----|---------|-------------|
| `:trace_max_string_size` | `65_536` | Max string size in bytes before truncation |
| `:trace_max_list_size` | `100` | Max list length before summarizing |
| `:trace_preserve_full_keys` | `["system_prompt"]` | Map keys whose strings are never truncated |
| `:trace_dir` | CWD | Default directory for trace JSONL files |

```elixir
config :ptc_runner,
  trace_max_string_size: 128_000,
  trace_dir: "traces"
```

Limit in-memory Tracer entries with `PtcRunner.Tracer.new/1`:

```elixir
Tracer.new(max_entries: 100)
```

### Known Limitations

Tool telemetry events (`tool.start`, `tool.stop`) are captured from inside the sandboxed process via trace collector propagation (`TraceLog.join/2`). All event types (`run`, `turn`, `llm`, `tool`) are captured correctly.

> **Full API:** See `PtcRunner.TraceLog.with_trace/2`, `PtcRunner.TraceLog.Analyzer.summary/1`, and `PtcRunner.TraceLog.Analyzer.export_chrome_trace/2`.

## PlanTracer

Real-time terminal visualization of `PtcRunner.PlanExecutor` runs. Use during development to see task progress with colored, hierarchical output.

### Quick Usage

For stateless logging via `Logger`:

```elixir
PlanExecutor.execute(plan, mission,
  llm: my_llm,
  on_event: &PlanTracer.log_event/1
)
```

For a stateful tree view with indentation and replan tracking:

```elixir
{:ok, tracer} = PlanTracer.start(output: :io)

PlanExecutor.execute(plan, mission,
  llm: my_llm,
  on_event: PlanTracer.handler(tracer)
)

PlanTracer.stop(tracer)
```

### Example Output

```
Mission: Research stock prices
  [START] fetch_symbols
  [✓] fetch_symbols (150ms)
  [START] fetch_prices
  [!] fetch_prices - Verification failed: "Count < 5"
REPLAN #1 (fetch_prices: "Count < 5")
  Repair plan: 2 tasks
  [✓] fetch_prices (400ms)
Execution finished: ok (1250ms)
```

Colors: green (success), yellow (verification failure/replan), red (error), cyan (skipped).

> **Full API:** See `PtcRunner.PlanTracer.start/1`, `PtcRunner.PlanTracer.handler/1`, and `PtcRunner.PlanTracer.log_event/1`.

## Telemetry Events

SubAgent emits `:telemetry` events for integration with Prometheus, OpenTelemetry, or custom handlers:

```elixir
:telemetry.attach_many(
  "my-handler",
  [
    [:ptc_runner, :sub_agent, :run, :stop],
    [:ptc_runner, :sub_agent, :llm, :stop],
    [:ptc_runner, :sub_agent, :tool, :stop]
  ],
  &MyApp.Telemetry.handle_event/4,
  nil
)
```

### Available Events

**SubAgent events** (prefix: `[:ptc_runner, :sub_agent, ...]`):

| Event | Measurements | Use Case |
|-------|--------------|----------|
| `run:start/stop` | duration | Total execution time |
| `turn:start/stop` | duration, tokens | Per-turn metrics |
| `llm:start/stop` | duration, tokens | LLM latency, cost tracking |
| `tool:start/stop/exception` | duration | Tool performance |

**PlanExecutor events** (prefix: `[:ptc_runner, :plan_executor, ...]`):

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `plan:generated` | system_time | plan, mission, task_count |
| `execution:start` | system_time | plan, mission, task_count, phases, attempt |
| `execution:stop` | duration | status, results, replan_count, total_tasks |
| `task:start` | system_time | task_id, task, attempt |
| `task:stop` | duration | task_id, status, result |
| `replan:start` | system_time | task_id, diagnosis, attempt |
| `replan:stop` | — | new_task_count (or status, reason on error) |
| `quality_gate:start` | system_time | task_id |
| `quality_gate:stop` | duration | task_id, status, evidence/missing/reason |

Duration is in native time units. Convert with:
```elixir
System.convert_time_unit(duration, :native, :millisecond)
```

> **Full event tables:** See `PtcRunner.SubAgent.Telemetry.span/3` and the `PtcRunner.PlanExecutor` moduledoc.

## Production Tips

- Use `trace: :on_error` to reduce memory in production
- Attach telemetry handlers for latency and cost dashboards
- Token counts are in `step.usage` (requires LLM to return token info)
- Use `step.usage.llm_requests` to track API call volume

## See Also

- [Message Compression](subagent-compression.md) - Reduce token usage in multi-turn agents
- [Troubleshooting](subagent-troubleshooting.md) - Common issues and debugging
- [Testing](subagent-testing.md) - Mock LLMs and test strategies
- `PtcRunner.TraceLog.with_trace/2` - Capture execution traces to JSONL files
- `PtcRunner.TraceLog.Analyzer.summary/1` - Offline trace analysis
- `PtcRunner.SubAgent.Telemetry.span/3` - Telemetry module with event reference
- `PtcRunner.SubAgent.Debug.print_trace/2` - Trace inspection API
- `PtcRunner.PlanTracer.start/1` - Real-time terminal visualization for PlanExecutor
- `PtcRunner.PlanTracer.handler/1` - Create bound event handler for PlanTracer
