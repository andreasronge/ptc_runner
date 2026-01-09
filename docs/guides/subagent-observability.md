# Observability

Integrate SubAgent with logging, metrics, and debugging tools.

## Trace Inspection

Every `Step` includes a `trace` field with per-turn execution history:

```elixir
{:ok, step} = SubAgent.run(agent, llm: llm)

for entry <- step.trace do
  IO.puts("Turn #{entry.turn}: #{entry.program}")
  IO.puts("  Tools: #{inspect(Enum.map(entry.tool_calls, & &1.name))}")
end

# Aggregated metrics
step.usage.duration_ms
step.usage.total_tokens
```

## Debug Mode

Enable debug mode to capture full LLM messages for troubleshooting:

```elixir
{:ok, step} = SubAgent.run(agent, llm: llm, debug: true)

# Compact view
SubAgent.Debug.print_trace(step)

# Full LLM messages (what was sent/received)
SubAgent.Debug.print_trace(step, messages: true)

# Include token usage
SubAgent.Debug.print_trace(step, messages: true, usage: true)
```

With `messages: true`, each turn shows:
- **Assistant Message** - Raw LLM output
- **Program** - Extracted PTC-Lisp code
- **Result** - Full execution result (before truncation)
- **User Message** - Feedback sent to LLM (after truncation)

> **Full API:** See `PtcRunner.SubAgent.Debug.print_trace/2`.

## Trace Filtering

Control trace collection for production optimization:

```elixir
# Only keep trace on failure
SubAgent.run(agent, llm: llm, trace: :on_error)

# Disable tracing entirely
SubAgent.run(agent, llm: llm, trace: false)
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

- [Troubleshooting](subagent-troubleshooting.md) - Common issues and debugging
- [Testing](subagent-testing.md) - Mock LLMs and test strategies
- `PtcRunner.SubAgent.Telemetry.span/3` - Telemetry module with event reference
- `PtcRunner.SubAgent.Debug.print_trace/2` - Trace inspection API
