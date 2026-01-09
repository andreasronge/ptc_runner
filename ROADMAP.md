# PtcRunner Roadmap (Brain Dump)

This document captures potential enhancements for ptc_runner, driven by real-world usage in production Phoenix applications (particularly an email/voice/calendar app).

## Current State

ptc_runner already has:
- Sandboxed BEAM execution with memory/timeout limits
- PTC-Lisp DSL for safe LLM-generated programs
- Step chaining for pipeline composition
- Comprehensive telemetry events (`[:ptc_runner, :sub_agent, :turn|:tool|:llm, :start|:stop]`)
- SubAgent composition via `as_tool/2`

## Known Gaps

### Tool Call Tracking Not Captured in Traces

The trace infrastructure exists but `tool_calls` is always `[]`. Tool execution happens inside the Sandbox/Lisp eval layer without collection. Fix would involve:
1. Capture tool calls inside eval context
2. Track name, args, result, duration per call
3. Return tool_calls list to Loop
4. Pass to `Metrics.build_trace_entry`

---

## Tier 1: Foundational Features

### 1. Async/Long-Running Tool Support

**Problem**: Many real-world tools take minutes (phone calls, human approval, slow APIs). Current model is fully synchronous.

**Use Cases**:
- Voice calls that take 1-5 minutes
- Human-in-the-loop approval workflows
- Webhook-based external APIs
- Background job integration (Oban)

**Proposed API**:

```elixir
# Option A: Explicit async wrapper
"make_phone_call" => PtcRunner.Tool.async(fn args ->
  call_id = initiate_call(args)
  {:pending, call_id, %{status: "dialing", call_id: call_id}}
end)

# Option B: Declarative metadata
tools: %{
  "make_phone_call" => {&initiate_call/1, async: true}
}

# SubAgent returns pending state
{:pending, %PtcRunner.PendingStep{
  pending_ops: %{"call_123" => %{tool: "make_phone_call", args: %{...}}},
  state: serializable_state,
  immediate_response: "I'm calling Alice now..."
}}

# Resume when async op completes
{:ok, step} = PtcRunner.SubAgent.resume(pending_step, "call_123", %{
  status: "completed",
  transcript: "..."
})
```

**Design Considerations**:
- Multiple async ops can be pending simultaneously
- Resume feeds results back into LLM context
- PTC-Lisp might need `(await call_id)` form or implicit suspension
- Consider: should async tools be callable from Lisp, or only at SubAgent level?

**BEAM-Native Approach**:
- Could model as GenServer that receives messages
- Or continuation-based: save/restore execution state
- Or event-sourcing: record decisions, replay with new info

### 2. State Serialization

**Problem**: Production apps need crash recovery, horizontal scaling, session hibernation.

**Use Cases**:
- Persist conversation to PostgreSQL
- Resume on different node after crash
- Hibernate long-idle sessions
- Debug by inspecting serialized state

**Proposed API**:

```elixir
# Serialize for storage
{:ok, binary} = PtcRunner.SubAgent.serialize(step)
# or
{:ok, binary} = PtcRunner.SubAgent.serialize(pending_step)

# Deserialize for recovery
{:ok, step} = PtcRunner.SubAgent.deserialize(binary)

# Continue execution
{:ok, final_step} = PtcRunner.SubAgent.run(agent,
  resume_from: step,
  llm: llm
)
```

**Design Considerations**:
- What's serializable? Step fields, memory, pending ops, message history
- Use `:erlang.term_to_binary` with safe options? Or JSON for portability?
- Version the serialization format for migrations
- Consider: anonymous functions in tools aren't serializable - need registry approach

**Relationship to Async**:
- Required for async to work (pending state must be persistable)
- But also useful standalone for crash recovery

---

## Tier 2: UX & Debugging

### 3. Streaming Support

**Problem**: Chat UX expects to see responses as they generate.

**Complexity**: PTC-Lisp programs can have multiple tool calls before user-facing output. Need to distinguish:
- LLM token streaming (reasoning/code generation phase)
- Tool progress callbacks (during execution)
- Final result streaming

**Proposed API**:

```elixir
SubAgent.run(agent,
  llm: streaming_llm,
  on_token: fn token -> send(live_view_pid, {:token, token}) end,
  on_tool_start: fn name, args -> log_tool_start(name) end,
  on_tool_end: fn name, result, duration_ms -> log_tool_end(name, result) end
)
```

**Design Considerations**:
- LLM callback would need to support streaming mode
- How to handle streaming + async tools together?
- Phoenix.Channel / LiveView integration helpers?

### 4. Conversation History Access

**Problem**: Apps want OpenAI-format message history for debugging, context, UI.

**Current State**: Messages are internal to Loop, not exposed in Step.

**Proposed API**:

```elixir
# Option A: Add to Step
%Step{
  # ... existing fields
  messages: [
    %{role: :system, content: "..."},
    %{role: :user, content: "..."},
    %{role: :assistant, content: "```ptc-lisp\n...```"}
  ]
}

# Option B: Callback during execution
SubAgent.run(agent,
  llm: llm,
  on_turn: fn %{turn: n, messages: msgs, program: code, result: res} ->
    persist_turn(conversation_id, n, msgs)
  end
)
```

**Design Considerations**:
- Memory cost of keeping full history in Step
- Privacy: some apps may not want to persist LLM outputs
- Format: OpenAI-style maps vs custom structs?

---

## Tier 3: Nice-to-Have

### 5. Tool Timeout with Partial Results

**Problem**: Long-running tools should return partial results on timeout rather than fail completely.

**Can Be User-Land Today**:

```elixir
"slow_tool" => fn args ->
  task = Task.async(fn -> do_slow_work(args) end)
  case Task.yield(task, 60_000) || Task.shutdown(task) do
    {:ok, result} -> result
    nil -> %{status: "timed_out", partial: get_partial_state()}
  end
end
```

**If Built-In**:

```elixir
"slow_tool" => {fn args -> ... end,
  timeout: 60_000,
  on_timeout: fn args, partial_state ->
    %{status: "timed_out", partial: partial_state}
  end
}
```

### 6. Pre/Post Hooks

**Problem**: No lifecycle callbacks beyond telemetry.

**Proposed API**:

```elixir
SubAgent.run(agent,
  before_turn: fn state -> modified_state end,
  after_turn: fn state, result -> :ok end,
  before_tool: fn name, args -> modified_args end,
  after_tool: fn name, args, result -> :ok end
)
```

**Use Cases**:
- Inject context before each turn
- Log/audit all tool calls
- Rate limiting
- Cost tracking

---

## BEAM-Native Differentiators

Features that would make ptc_runner unique in the LLM tooling ecosystem:

### Distributed Execution
- Serialize state, resume on different node
- Unique to BEAM - not possible in Python frameworks

### Supervision Integration
- SubAgent as supervised GenServer child
- Restart strategies for long-running agents
- Link to parent process for cleanup

### Phoenix Integration
- `PtcRunner.LiveView` - streaming to LiveView
- `PtcRunner.Channel` - WebSocket streaming
- `PtcRunner.Presence` - track active agents

### Oban Integration
- `PtcRunner.Oban.Worker` - run SubAgent as background job
- Automatic state persistence
- Retry with exponential backoff

---

## Suggested Release Plan

```
v0.5: Observability & Debugging
  - Fix tool call tracking in traces
  - Add messages to Step (opt-in)
  - Document existing telemetry

v0.6: State Management
  - State serialization (Step <-> binary)
  - Resume from serialized state
  - Version format for migrations

v0.7: Async Tools
  - {:async, id, immediate_result} pattern
  - PendingStep struct
  - SubAgent.resume/3
  - PTC-Lisp await form (if needed)

v0.8: Streaming
  - on_token callback
  - on_tool_start/end callbacks
  - LiveView helper module

v1.0: Production Ready
  - Stable serialization format
  - Phoenix/Oban integration guides
  - Performance benchmarks
```

---

## Open Questions

1. **Async tool design**: Should async be at Lisp level (`(await id)`) or SubAgent level only?

2. **Serialization format**: `:erlang.term_to_binary` (efficient, BEAM-only) vs JSON (portable, inspectable)?

3. **Message history**: Always collect, opt-in, or opt-out?

4. **GenServer mode**: Should SubAgent optionally run as a process that receives messages?

5. **Backpressure**: How to handle LLM rate limits in streaming mode?

---

## References

- Current architecture: `lib/ptc_runner/sub_agent/` (Loop, Telemetry, ToolNormalizer)
- Step struct: `lib/ptc_runner/step.ex`
- Sandbox execution: `lib/ptc_runner/sandbox.ex`
