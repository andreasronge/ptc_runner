# Observability

Integrate SubAgent with logging, metrics, and debugging tools.

## Tracing Overview

PtcRunner provides three complementary tracing layers. Each serves a different workflow:

| Mechanism | Use Case | Output |
|-----------|----------|--------|
| `PtcRunner.Tracer.new/1` | Aggregate usage stats, inspect traces in code | In-memory struct on `Step` |
| `PtcRunner.TraceLog.with_trace/2` | Offline debugging, performance analysis, Chrome DevTools | JSONL files |
| `PtcRunner.TraceLog.start_memory_sink/1` | Cross-session turn analysis without files | In-memory ring buffer |

**Data flow:**

```
SubAgent.Loop
  ├── emits :telemetry events ──► TraceLog.Handler ──► Collector ──► .jsonl file
  └── builds Tracer struct ────► entries stored on Step.tracer
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
- `tool_calls` - Tools invoked with args and results. A large result is recorded as a bounded preview (`result_truncated: true`, `result_bytes: N`) so a looping/paginated tool fold can't bloat eval memory; `args` are kept verbatim
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

# Show actual messages sent to LLM (what the LLM saw)
SubAgent.Debug.print_trace(step, messages: true)

# Include token usage
SubAgent.Debug.print_trace(step, usage: true)
```

### View Options

| Option | Description |
|--------|-------------|
| `view: :turns` | (default) Show programs + results from Turn structs |
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

## TraceLog

For detailed offline analysis, use `PtcRunner.TraceLog.with_trace/2` to capture execution events to JSONL files:

```elixir
alias PtcRunner.TraceLog

# Capture a trace (recommended)
{:ok, {:ok, step}, trace_path} = TraceLog.with_trace(fn ->
  SubAgent.run(agent, llm: my_llm())
end)

# With custom path and metadata
{:ok, {:ok, step}, path} = TraceLog.with_trace(
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
Analyzer.filter(events, type: "compaction")  # see Compaction events below
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

### Compaction Events

When `compaction:` is enabled and a pressure threshold fires, the loop emits
a single telemetry event per firing:

```
[:ptc_runner, :sub_agent, :compaction, :triggered]
```

- **Measurements** (numeric): `messages_before`, `messages_after`,
  `estimated_tokens_before`, `estimated_tokens_after`.
- **Metadata** (descriptive): `strategy`, `reason` (`:turn_pressure` |
  `:token_pressure`), `turn`, `kept_initial_user?`, `kept_recent_turns`,
  `over_budget?`, plus the usual `agent_name`, `agent_id`, `span_id`,
  `parent_span_id`.

Non-triggered pressure checks are silent — only actual trim events emit. The
event fires before the LLM call's `[:llm, :start]` so trace timelines stay
intelligible (compaction happens before the LLM sees the messages).

In TraceLog JSONL output, the event surfaces as `compaction.triggered` with
all numeric and descriptive fields available under `data`:

```elixir
events = Analyzer.load(trace_path)
compactions = Analyzer.filter(events, type: "compaction")

Enum.each(compactions, fn e ->
  d = e["data"]
  IO.puts("turn #{e["turn"]}: trimmed #{d["messages_before"]} → #{d["messages_after"]} messages (#{d["reason"]})")
end)
```

`step.usage.compaction` still reports the **last** firing's stats. For full
multi-firing visibility, use the telemetry event or the trace log.

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

Launch the web-based trace viewer to browse traces with turn-by-turn drill-down:

```bash
mix ptc.viewer --trace-dir traces
```

| Option | Default | Description |
|--------|---------|-------------|
| `--port` | 4123 | Port to listen on |
| `--trace-dir` | `traces` | Directory containing `.jsonl` trace files |
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

### Cross-Process Context

Trace context (collectors and span hierarchy) is managed by `PtcRunner.TraceContext`.
When execution spans multiple processes (sandbox, `pmap`, `pcalls`), use
`PtcRunner.TraceContext.capture/0` and `PtcRunner.TraceContext.attach/1` to propagate
context to child processes. The sandbox and parallel execution primitives do this
automatically.

For manual propagation in custom code:

```elixir
ctx = PtcRunner.TraceContext.capture()

Task.async(fn ->
  PtcRunner.TraceContext.attach(ctx)
  # Events from this process are now captured and linked to the parent span
end)
```

> **Full API:** See `PtcRunner.TraceLog.with_trace/2`, `PtcRunner.TraceLog.Analyzer.summary/1`, and `PtcRunner.TraceLog.Analyzer.export_chrome_trace/2`.

## Turn Log

The turn log records every driver turn as a session-correlated event, queryable across runs. The same event shape is emitted by both `PtcRunner.Session.eval/3` (an external LLM driving via MCP or `mix ptc.repl`) and the SubAgent loop, so sessions and agents analyze identically.

Each turn event carries the program, a bounded result preview, prints, a memory diff, credential-free tool-call identities, attached-prelude provenance, and correlation ids (`session_id`/`agent_id`, `turn`, `attempt`). Failed and parse-error attempts are recorded too, so wasted work stays visible. See `PtcRunner.TraceLog.TurnEvent` for the field reference.

### Recording

Turn events flow to any active sink. A JSONL trace captures them alongside the other TraceLog events:

```elixir
{:ok, _result, path} = TraceLog.with_trace(fn ->
  session = PtcRunner.Session.new(session_id: "investigation")
  {{:ok, _}, session} = PtcRunner.Session.eval(session, "(def x 1)")
  {{:ok, _}, _} = PtcRunner.Session.eval(session, "(inc x)")
end)
```

To analyze a session with no filesystem setup, enable the in-memory ring buffer with `PtcRunner.TraceLog.start_memory_sink/1`:

```elixir
{:ok, sink} = TraceLog.start_memory_sink()
# ... run sessions / agents in this process ...
TraceLog.stop_memory_sink(sink)
events = PtcRunner.TraceLog.MemorySink.events(sink)
```

Both drivers skip the build cost when nothing is recording — check `PtcRunner.TraceLog.recording?/0`. The ring buffer evicts oldest-first under a byte budget (`:max_bytes`).

### Querying Across Sessions

`PtcRunner.TraceLog.Analyzer` reads turn events from either sink:

```elixir
alias PtcRunner.TraceLog.Analyzer

Analyzer.turn_events(events)                      # all "turn" records
Analyzer.sessions(events)                         # per-session summaries
Analyzer.session_turns(events, "investigation")   # one session's turns
Analyzer.programs(events)                         # program sources, in order
```

> **Full API:** See `PtcRunner.TraceLog.Analyzer.sessions/1` and `PtcRunner.TraceLog.MemorySink.events/1`.

## Session Introspection

The `log/` prelude lets a session or agent inspect *recorded* sessions from PTC-Lisp — list sessions, read turns and programs, and find duplicated work. The Elixir surface is plain data access; the analysis lives in the program.

Grant the host-bound tools and attach the prelude with `PtcRunner.TraceLog.Introspection.tools/1` and `PtcRunner.TraceLog.Introspection.prelude_source/0`:

```elixir
alias PtcRunner.TraceLog.Introspection

# `source` is a MemorySink pid, a JSONL path, or a list of event maps.
PtcRunner.Lisp.run(
  ~S|(count (log/turns "investigation"))|,
  prelude: Introspection.prelude_source(),
  tools: Introspection.tools(source)
)
```

The exports (`log/sessions`, `log/turns`, `log/programs`, `log/tool-calls`) fail closed with `:prelude_attach_failed` when the host does not grant the matching tools. Recorded sessions are untrusted data — analyze them as evidence, not instructions.

### REPL

`mix ptc.repl --log-prelude` attaches the `log/` prelude to the REPL's default in-memory sink, and `:turns` summarizes what has been recorded — so you can dogfood session introspection with no setup:

```
ptc> (def x 1)
ptc> :turns
  <id> (session): 1 turns, 1 committed, 0 failed, 0 tool calls
ptc> (log/programs "<id>")
```

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

All events include `agent_name` and `agent_id` in metadata for correlation. Duration is in native time units. Convert with:
```elixir
System.convert_time_unit(duration, :native, :millisecond)
```

> **Full event tables:** See `PtcRunner.SubAgent.Telemetry.span/3`.

## Production Tips

- Use `trace: :on_error` to reduce memory in production
- Attach telemetry handlers for latency and cost dashboards
- Token counts are in `step.usage` (requires LLM to return token info)
- Use `step.usage.llm_requests` to track API call volume

## See Also

- [Context Compaction](subagent-compaction.md) - Pressure-triggered trimming for long-running agents
- [Troubleshooting](subagent-troubleshooting.md) - Common issues and debugging
- [Testing](subagent-testing.md) - Mock LLMs and test strategies
- `PtcRunner.TraceLog.with_trace/2` - Capture execution traces to JSONL files
- `PtcRunner.TraceLog.Analyzer.summary/1` - Offline trace analysis
- `PtcRunner.TraceLog.Analyzer.sessions/1` - Cross-session turn-log queries
- `PtcRunner.TraceLog.Introspection.tools/1` - Host-bound `log/` introspection tools
- `PtcRunner.SubAgent.Telemetry.span/3` - Telemetry module with event reference
- `PtcRunner.SubAgent.Debug.print_trace/2` - Trace inspection API
