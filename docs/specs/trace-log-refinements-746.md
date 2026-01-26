# TraceLog Nested Agent Refinements for #746

Review of the existing spec with refinements needed for the RLM/pmap use case.

## Current State

- **#745** (core TraceLog + Analyzer) - CLOSED (implemented)
- **#748** (span correlation in telemetry) - MERGED
- **#746** (nested agent support) - OPEN (this issue)

## The RLM/pmap Problem

The existing spec assumes SubAgentTool is called directly from Elixir code. But in RLM patterns:

```
Planner (Sonnet)
  └── pmap #(tool/worker {:chunk %}) data/chunks
        ├── Worker 1 (Haiku) - Task process
        ├── Worker 2 (Haiku) - Task process
        └── ... 28 workers
```

**Three layers of process isolation:**

1. **Sandbox process** - Lisp code runs in `PtcRunner.Sandbox.execute/3`
2. **pmap Task processes** - Each worker runs in `Task.async_stream`
3. **Worker SubAgent** - Each SubAgentTool.run spawns its own processes

The current TraceLog uses process dictionary for collector state. None of these child processes inherit it.

## Current Limitation (from trace_log.ex)

> **Note:** Tool telemetry events (`tool.start`, `tool.stop`) are currently not captured because tool execution runs inside a sandboxed process that doesn't inherit the trace collector.

## Spec Gaps

### Gap 1: No trace context propagation through Lisp execution

The spec's "Nested Agent Context Propagation" section (lines 995-1010) shows:

```elixir
SubAgent.run(agent, context,
  trace_context: %{parent_trace_id: "aaaa...", parent_span_id: "44444444", depth: 1}
)
```

But this only works for direct Elixir calls. When the LLM writes `(tool/worker {:chunk %})`, there's no way to inject trace_context.

**Refinement needed:** The Lisp interpreter must carry trace context in EvalContext and pass it to tool executors.

### Gap 2: pmap parallel execution creates orphaned traces

The spec's "Parallel Sub-Agent Pattern" (lines 1217-1263) shows user-controlled parallel execution. But for pmap:

- The user doesn't control process spawning - pmap does
- Each Task.async_stream worker needs its own trace file
- Parent needs to collect all child_trace_ids

**Refinement needed:** ToolNormalizer must automatically wrap SubAgentTools with trace context propagation when running inside a traced execution.

### Gap 3: Aggregated pmap results in parent trace

For `tool.stop` with SubAgentTool, the spec shows:

```json
{"event": "tool.stop", "tool": "researcher", "child_trace_id": "f9e8d7c6b5a43210"}
```

But pmap calls the same tool N times. The parent needs:

```json
{"event": "pmap.stop", "tool": "worker", "child_trace_ids": ["aaaa", "bbbb", "cccc", ...], "count": 28}
```

**Refinement needed:** Either a special `pmap.stop` event, or aggregate child_trace_ids in the turn's tool_calls.

## Proposed Refinements

### 1. Add trace_context to EvalContext

```elixir
# lib/ptc_runner/lisp/eval/context.ex
defstruct [
  # ... existing fields ...
  trace_context: nil  # %{trace_id: ..., parent_span_id: ..., depth: ...}
]
```

Lisp.run accepts `:trace_context` option and passes it through.

### 2. ToolNormalizer propagates trace context to SubAgentTools

```elixir
# In ToolNormalizer.normalize/3
defp wrap_sub_agent_tool(tool, state, agent) do
  fn args ->
    trace_context = build_child_trace_context(state)

    # Each SubAgentTool execution gets its own trace file
    trace_opts = if trace_context do
      [
        path: child_trace_path(trace_context),
        meta: %{parent_trace_id: trace_context.trace_id, depth: trace_context.depth + 1}
      ]
    end

    {result, child_trace_id} = if trace_opts do
      {:ok, step, path} = TraceLog.with_trace(
        fn -> execute_sub_agent(tool, args, state) end,
        trace_opts
      )
      {step.return, extract_trace_id(path)}
    else
      {execute_sub_agent(tool, args, state).return, nil}
    end

    # Record child_trace_id for later collection
    if child_trace_id do
      record_child_trace(state, child_trace_id)
    end

    result
  end
end
```

### 3. Trace context flows through run_opts to Loop to Lisp

```elixir
# SubAgent.run/2 accepts trace_context
SubAgent.run(agent,
  llm: my_llm(),
  trace_context: %{trace_id: "parent", depth: 0}
)

# Loop passes to Lisp.run
lisp_opts = [
  # ... existing opts ...
  trace_context: state.trace_context
]
```

### 4. Automatic trace context when inside TraceLog.with_trace

When `SubAgent.run` is called inside `TraceLog.with_trace`, automatically inject trace context:

```elixir
# In SubAgent.run/2
def run(agent, opts) do
  # Check if we're inside a traced execution
  opts = maybe_inject_trace_context(opts)
  # ... rest of run
end

defp maybe_inject_trace_context(opts) do
  if TraceLog.current_collector() && !Keyword.has_key?(opts, :trace_context) do
    collector = TraceLog.current_collector()
    trace_id = Collector.trace_id(collector)
    Keyword.put(opts, :trace_context, %{trace_id: trace_id, depth: 0})
  else
    opts
  end
end
```

### 5. Child trace collection in Step

Add `child_traces` to Step struct for aggregation:

```elixir
# Step struct
defstruct [
  # ... existing fields ...
  child_traces: []  # [{tool_name, trace_id, duration_ms}, ...]
]
```

### 6. Tree loading discovers pmap children

The existing `load_tree/1` algorithm works if:
- Each child writes to `trace-{trace_id}.jsonl`
- Parent's tool.stop (or a new pmap.stop) includes child_trace_ids
- For pmap, multiple child_trace_ids per tool invocation

## Implementation Order

1. **Add trace_context to EvalContext** - Simple addition, no behavior change
2. **Thread trace_context through SubAgent.run → Loop → Lisp.run** - Plumbing
3. **ToolNormalizer wraps SubAgentTools with trace propagation** - Core feature
4. **Automatic trace context injection** - Convenience
5. **Child trace collection in Step** - Reporting
6. **Analyzer.load_tree handles multiple children** - Already in spec

## Questions for Review

1. **Should pmap emit its own telemetry event?** Currently tool calls inside sandbox don't emit telemetry. Should we add `pmap.start/stop` events that run outside the sandbox?

2. **File naming convention for parallel children?** The spec suggests `trace-{trace_id}.jsonl`. For 28 pmap workers, that's 28 files. Should we support a single-file mode for simpler debugging?

3. **Memory overhead of trace context?** If trace_context is passed through every Lisp evaluation, is there measurable overhead? (Probably negligible, but worth measuring.)

4. **What if workers call workers?** The spec supports arbitrary depth. With pmap, we could have Planner → Worker → Sub-worker. Does the depth limit (default 10) apply correctly?

## Acceptance Criteria Additions

Add to #746 acceptance criteria:

- [ ] Trace context flows through EvalContext to tool executors
- [ ] SubAgentTool calls from pmap automatically create child trace files
- [ ] Parent Step.child_traces contains all child trace IDs from pmap
- [ ] Analyzer.load_tree correctly discovers pmap children (multiple per tool)
- [ ] RLM example produces full trace tree showing all 28 workers

## Example: RLM Trace Output

After implementation, running the RLM example with tracing:

```elixir
{:ok, step, path} = TraceLog.with_trace(fn ->
  SubAgent.run(planner_prompt, run_opts)
end)

{:ok, tree} = Analyzer.load_tree(path)
Analyzer.print_tree(tree)
```

Expected output:
```
Execution Tree (29 agents, 32 turns, 55.2s)
═══════════════════════════════════════════
planner [aaaa] ████████████████████████████████████ 55.2s
├── turn 1: pmap workers
│   ├── worker [bb01] ████████░░░░░░░░░░░░░░░░░░░░░░░░ 12.3s
│   ├── worker [bb02] ██████████░░░░░░░░░░░░░░░░░░░░░░ 14.1s
│   ├── worker [bb03] ████████████░░░░░░░░░░░░░░░░░░░░ 15.8s  ← slowest
│   │   └── turn 1: analyze chunk
│   ├── ... (25 more workers)
│   └── worker [bb28] ████████░░░░░░░░░░░░░░░░░░░░░░░░ 11.9s
├── turn 2: error recovery (mapcat undefined)
├── turn 3: aggregate results
└── turn 4: return

Tree Summary:
  Agents: 29 (1 planner + 28 workers)
  Total turns: 32
  Total tokens: 45,200
  Total cost: $0.12
  Critical path: planner.turn1 → worker[bb03] → planner.turn2-4 (23.5s)
```
