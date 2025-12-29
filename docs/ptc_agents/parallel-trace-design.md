# Parallel Trace Aggregation Design

> **Status:** Planned
> **Scope:** Observability for concurrent SubAgent execution

This document specifies the trace structure and aggregation strategy for parallel SubAgent execution.

> **Note:** `Step.trace` is always a list `[trace_entry()]`. The enhanced map structure in this document (`%{root_trace_id, entries, metadata}`) is a **separate aggregation result** returned by `Tracer.merge_parallel/2` - it does not replace `Step.trace`. Use it when you need to combine traces from multiple parallel agents into a unified timeline.

---

## Problem Statement

When SubAgents run in parallel via `Task.async_stream`, their traces are generated concurrently:

```elixir
agents
|> Task.async_stream(fn agent -> SubAgent.run(agent, llm: llm) end)
|> Enum.map(fn {:ok, result} -> result end)
```

**Challenges:**
1. No correlation between parent task and child traces
2. Timestamp interleaving makes timeline reconstruction ambiguous
3. Race conditions if using shared mutable state (e.g., Agent)
4. Lost causality between parent invocation and child execution

---

## Design Goals

1. **Immutable traces** - No shared mutable state
2. **Correlation IDs** - Link parent and child executions
3. **Timestamp ordering** - Reconstruct parallel timelines
4. **Process isolation** - Each SubAgent owns its trace
5. **Safe aggregation** - Merge traces without race conditions

---

## Enhanced Trace Structure

### trace_entry Type

```elixir
@type trace_entry :: %{
  # Identity
  trace_id: String.t(),           # Unique ID for this execution path (UUID)
  parent_trace_id: String.t() | nil,  # Links to parent step's trace_id
  agent_id: String.t() | nil,     # Name/identifier of the agent

  # Causality & Ordering
  turn: pos_integer(),            # Local turn counter (per agent)
  timestamp: DateTime.t(),        # When this step started
  duration_ms: non_neg_integer(), # How long this turn took

  # Execution Details
  program: String.t() | nil,      # PTC-Lisp program text
  result: term() | nil,           # Program execution result
  error: String.t() | nil,        # Error message if failed

  # Tool Calls
  tool_calls: [tool_call()],      # Recorded tool invocations

  # Metrics
  usage: usage() | nil            # Token usage for this turn
}

@type tool_call :: %{
  name: String.t(),
  args: map(),
  result: term() | nil,
  error: String.t() | nil,
  timestamp: DateTime.t(),
  duration_ms: non_neg_integer()
}
```

### Enhanced Step Struct

```elixir
@type Step.t :: %{
  return: term() | nil,
  fail: fail() | nil,
  memory: map(),
  memory_delta: map() | nil,
  signature: String.t() | nil,
  usage: usage() | nil,

  # Enhanced tracing fields
  trace: trace(),
  trace_id: String.t(),            # This execution's trace ID
  parent_trace_id: String.t() | nil,  # Parent's trace ID (nil if root)
  agent_id: String.t() | nil,      # Agent identifier
  execution_start: DateTime.t(),   # When execution began
  execution_duration_ms: non_neg_integer()  # Total wall time
}

@type trace :: %{
  root_trace_id: String.t(),       # Top-level execution ID
  entries: [trace_entry()],        # All trace entries
  metadata: trace_metadata()
}

@type trace_metadata :: %{
  agent_count: non_neg_integer(),  # Number of agents involved
  parallel: boolean(),             # Whether parallel execution occurred
  wall_time_ms: non_neg_integer(), # Total wall clock time
  total_turns: non_neg_integer()   # Sum of all turns
}
```

---

## Trace ID Generation

```elixir
defmodule PtcRunner.Tracer do
  @doc """
  Generate a new trace ID.

  Uses UUID v4 for uniqueness across distributed systems.
  """
  @spec generate_trace_id() :: String.t()
  def generate_trace_id do
    UUID.uuid4()
  end

  @doc """
  Create a new trace context for an agent execution.
  """
  @spec new_trace(keyword()) :: trace_context()
  def new_trace(opts \\ []) do
    %{
      trace_id: generate_trace_id(),
      parent_trace_id: opts[:parent_trace_id],
      agent_id: opts[:agent_id],
      entries: [],
      start_time: DateTime.utc_now()
    }
  end
end
```

---

## Immutable Recording Pattern

Replace Agent-based recording with immutable trace threading:

### Current (Mutable - NOT Safe)

```elixir
# ❌ Bad: Shared mutable state
{:ok, recorder} = Agent.start_link(fn -> [] end)
wrapped_tools = Map.new(tools, fn {name, fun} ->
  {name, fn args ->
    res = fun.(args)
    Agent.update(recorder, &[%{name: name, args: args, result: res} | &1])
    res
  end}
end)
```

### Proposed (Immutable - Safe)

```elixir
# ✓ Good: Immutable trace passed through execution
defmodule PtcRunner.SubAgent.Loop do
  def run(prompt, opts) do
    trace = Tracer.new_trace(
      parent_trace_id: opts[:parent_trace_id],
      agent_id: opts[:agent_id]
    )

    {result, final_trace} = execute_loop(prompt, opts, trace)

    %Step{
      return: result,
      trace_id: trace.trace_id,
      trace: Tracer.finalize(final_trace)
    }
  end

  defp execute_loop(prompt, opts, trace) do
    # Each turn returns updated trace
    {turn_result, trace} = execute_turn(prompt, opts, trace)
    # ...
  end

  defp execute_turn(prompt, opts, trace) do
    entry = %{
      trace_id: trace.trace_id,
      turn: current_turn(trace),
      timestamp: DateTime.utc_now(),
      tool_calls: []
    }

    # Tool wrapper captures calls immutably
    {result, tool_calls} = execute_with_recording(program, tools)

    entry = %{entry |
      result: result,
      tool_calls: tool_calls,
      duration_ms: elapsed_ms(entry.timestamp)
    }

    {result, Tracer.add_entry(trace, entry)}
  end
end
```

---

## Parallel Execution Pattern

```elixir
defmodule MyApp.Orchestrator do
  def run_parallel(agents, llm) do
    # Generate correlation ID for this parallel batch
    batch_trace_id = Tracer.generate_trace_id()

    # Run agents in parallel, each with parent_trace_id set
    results =
      agents
      |> Task.async_stream(fn agent ->
        SubAgent.run(agent,
          llm: llm,
          parent_trace_id: batch_trace_id,
          agent_id: agent.name || "agent-#{:rand.uniform(1000)}"
        )
      end, max_concurrency: 3)
      |> Enum.map(fn {:ok, {:ok, step}} -> step end)

    # Aggregate traces safely
    aggregated_trace = Tracer.merge_parallel(
      Enum.map(results, & &1.trace),
      batch_trace_id
    )

    %{
      results: results,
      trace: aggregated_trace
    }
  end
end
```

---

## Trace Aggregation

### Merging Parallel Traces

```elixir
defmodule PtcRunner.Tracer do
  @doc """
  Merge multiple traces from parallel execution.

  Sorts entries by timestamp for timeline reconstruction.
  """
  @spec merge_parallel([trace()], String.t()) :: trace()
  def merge_parallel(traces, root_trace_id) do
    # Collect all entries from all traces
    all_entries =
      traces
      |> Enum.flat_map(& &1.entries)
      |> Enum.sort_by(& &1.timestamp, DateTime)

    # Calculate metadata
    start_times = Enum.map(traces, & hd(&1.entries).timestamp)
    end_times = Enum.map(traces, & List.last(&1.entries).timestamp)

    %{
      root_trace_id: root_trace_id,
      entries: all_entries,
      metadata: %{
        agent_count: length(traces),
        parallel: true,
        wall_time_ms: DateTime.diff(
          Enum.max(end_times, DateTime),
          Enum.min(start_times, DateTime),
          :millisecond
        ),
        total_turns: Enum.sum(Enum.map(traces, &length(&1.entries)))
      }
    }
  end
end
```

### Nested Trace Aggregation

When SubAgents call other SubAgents via `as_tool`:

```elixir
defmodule PtcRunner.Tracer do
  @doc """
  Record a nested SubAgent execution within a tool call.
  """
  @spec record_nested_call(trace(), tool_call(), Step.t()) :: trace()
  def record_nested_call(parent_trace, tool_call, child_step) do
    # Embed child trace in tool call result
    nested_tool_call = %{tool_call |
      result: %{
        return: child_step.return,
        nested_trace: child_step.trace
      }
    }

    # Update the current entry's tool_calls
    update_last_entry(parent_trace, fn entry ->
      %{entry | tool_calls: entry.tool_calls ++ [nested_tool_call]}
    end)
  end
end
```

---

## Visualization Support

### Timeline Reconstruction

```elixir
defmodule PtcRunner.Tracer.Timeline do
  @doc """
  Generate a timeline view of parallel execution.
  """
  @spec to_timeline(trace()) :: [timeline_event()]
  def to_timeline(trace) do
    trace.entries
    |> Enum.flat_map(fn entry ->
      [
        %{
          time: entry.timestamp,
          type: :turn_start,
          agent: entry.agent_id,
          turn: entry.turn
        },
        %{
          time: DateTime.add(entry.timestamp, entry.duration_ms, :millisecond),
          type: :turn_end,
          agent: entry.agent_id,
          turn: entry.turn,
          result: entry.result
        }
      ] ++
      Enum.flat_map(entry.tool_calls, fn call ->
        [
          %{
            time: call.timestamp,
            type: :tool_call,
            agent: entry.agent_id,
            tool: call.name
          }
        ]
      end)
    end)
    |> Enum.sort_by(& &1.time, DateTime)
  end
end
```

### ASCII Timeline Output

```
Timeline for batch_trace_id: abc-123
═════════════════════════════════════════════════════════════════
Agent A  │████████████│                    │██████│
Agent B  │      │█████████████████│        │
Agent C  │            │    │███████████████████████│
─────────┴──────┴────┴────┴────────────────┴──────┴─────────────
         T0    T1   T2   T3              T4     T5

Legend: █ = active turn, │ = tool call
```

---

## Observability Queries

With the enhanced trace structure, answer common questions:

### "Did agents run in parallel?"

```elixir
def parallel?(trace) do
  trace.metadata.parallel
end
```

### "What was the slowest agent?"

```elixir
def slowest_agent(trace) do
  trace.entries
  |> Enum.group_by(& &1.agent_id)
  |> Enum.map(fn {agent_id, entries} ->
    {agent_id, Enum.sum(Enum.map(entries, & &1.duration_ms))}
  end)
  |> Enum.max_by(fn {_, duration} -> duration end)
end
```

### "Were there tool conflicts?"

```elixir
def tool_call_overlap?(trace) do
  all_tool_calls =
    trace.entries
    |> Enum.flat_map(& &1.tool_calls)
    |> Enum.sort_by(& &1.timestamp, DateTime)

  # Check for overlapping time ranges
  check_overlaps(all_tool_calls)
end
```

### "Reconstruct execution order"

```elixir
def execution_order(trace) do
  trace.entries
  |> Enum.sort_by(& &1.timestamp, DateTime)
  |> Enum.map(fn entry ->
    %{
      agent: entry.agent_id,
      turn: entry.turn,
      time: entry.timestamp,
      program: String.slice(entry.program || "", 0..50)
    }
  end)
end
```

---

## Telemetry Integration

Emit telemetry events for external monitoring:

```elixir
defmodule PtcRunner.Tracer.Telemetry do
  def emit_turn_start(trace_entry) do
    :telemetry.execute(
      [:ptc_runner, :agent, :turn, :start],
      %{timestamp: trace_entry.timestamp},
      %{
        trace_id: trace_entry.trace_id,
        agent_id: trace_entry.agent_id,
        turn: trace_entry.turn
      }
    )
  end

  def emit_turn_end(trace_entry) do
    :telemetry.execute(
      [:ptc_runner, :agent, :turn, :stop],
      %{
        duration_ms: trace_entry.duration_ms,
        tool_call_count: length(trace_entry.tool_calls)
      },
      %{
        trace_id: trace_entry.trace_id,
        agent_id: trace_entry.agent_id,
        turn: trace_entry.turn,
        success: is_nil(trace_entry.error)
      }
    )
  end

  def emit_tool_call(trace_id, tool_call) do
    :telemetry.execute(
      [:ptc_runner, :tool, :call],
      %{duration_ms: tool_call.duration_ms},
      %{
        trace_id: trace_id,
        tool_name: tool_call.name,
        success: is_nil(tool_call.error)
      }
    )
  end
end
```

---

## Implementation Checklist

- [ ] Add `trace_id`, `parent_trace_id`, `agent_id` to Step struct
- [ ] Create `PtcRunner.Tracer` module with immutable operations
- [ ] Update `Loop.run/2` to thread trace through execution
- [ ] Implement `Tracer.merge_parallel/2` for aggregation
- [ ] Add `:telemetry` events for observability
- [ ] Update `SubAgent.run/2` to accept `parent_trace_id` option
- [ ] Add timeline visualization helper
- [ ] Test concurrent execution with 3+ agents

---

## Related Documents

- [specification.md](specification.md) - SubAgent API reference
- [guides/](guides/) - Usage guides and patterns
- [step.md](step.md) - Step struct specification
- [signature-syntax.md](signature-syntax.md) - Signature syntax reference
- [spike-summary.md](spike-summary.md) - Historical spike validation results
