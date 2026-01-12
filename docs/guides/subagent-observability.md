# Observability

Integrate SubAgent with logging, metrics, and debugging tools.

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

Options can be combined: `print_trace(step, messages: true, usage: true)`.

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

| Event | Measurements | Use Case |
|-------|--------------|----------|
| `run:start/stop` | duration | Total execution time |
| `turn:start/stop` | duration, tokens | Per-turn metrics |
| `llm:start/stop` | duration, tokens | LLM latency, cost tracking |
| `tool:start/stop/exception` | duration | Tool performance |

Duration is in native time units. Convert with:
```elixir
System.convert_time_unit(duration, :native, :millisecond)
```

> **Full event table:** See `PtcRunner.SubAgent.Telemetry.span/3`.

## Production Tips

- Use `trace: :on_error` to reduce memory in production
- Attach telemetry handlers for latency and cost dashboards
- Token counts are in `step.usage` (requires LLM to return token info)
- Use `step.usage.llm_requests` to track API call volume

## See Also

- [Message Compression](subagent-compression.md) - Reduce token usage in multi-turn agents
- [Troubleshooting](subagent-troubleshooting.md) - Common issues and debugging
- [Testing](subagent-testing.md) - Mock LLMs and test strategies
- `PtcRunner.SubAgent.Telemetry.span/3` - Telemetry module with event reference
- `PtcRunner.SubAgent.Debug.print_trace/2` - Trace inspection API
