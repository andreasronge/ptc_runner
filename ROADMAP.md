# PtcRunner Roadmap (Brain Dump)

This document captures potential enhancements for ptc_runner, driven by real-world usage in production Phoenix applications (particularly an email/voice/calendar app).

## Current State

ptc_runner already has:
- Sandboxed BEAM execution with memory/timeout limits
- PTC-Lisp DSL for safe LLM-generated programs
- Step chaining for pipeline composition
- Comprehensive telemetry events (`[:ptc_runner, :sub_agent, :turn|:tool|:llm, :start|:stop]`)
- SubAgent composition via `as_tool/2`
- **v0.5 Observability**: Turn struct with tool_calls/prints, Debug API, message compression

## Known Gaps

_No critical gaps at this time. See v0.6+ for planned features._

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

**Decision: Lisp-level `(await)` is required**

The question "should async be at Lisp level or SubAgent level only?" is answered by real use cases:

```lisp
;; Use case: "Call Alice and Bob in parallel, then summarize both"
;; This REQUIRES Lisp-level await:
(let [transcript-a (await call-alice)
      transcript-b (await call-bob)]
  (summarize (concat transcript-a transcript-b)))

;; Without Lisp-level await, this requires:
;; 1. First SubAgent run -> starts calls -> suspends
;; 2. Resume with Alice result -> suspends again (can't reference Bob yet)
;; 3. Resume with Bob result -> another LLM turn to combine
;; That's 3 LLM round-trips instead of 1
```

Lisp-level await enables the LLM to express "wait for multiple async results, then combine" in a single program. SubAgent-level-only would force multiple round-trips for common patterns.

**Lisp suspension serialization**: When `(await)` suspends mid-execution, we need to serialize the continuation. Since PTC-Lisp is interpreted, serialize AST + environment (variable bindings), not closures. Resume by continuing interpretation from suspension point.

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
- Version the serialization format for migrations

**Decision: JSON as default format**

Leaning toward JSON over `:erlang.term_to_binary`:
- Async state may sit in Postgres for minutes/hours (human-in-the-loop)
- Debuggability matters: `jq` a suspended state to understand what's happening
- Efficiency matters less than correctness during 0.x development
- Can add binary as optional optimization later for high-throughput cases

```elixir
# Default: JSON for debuggability
{:ok, json} = PtcRunner.SubAgent.serialize(step, format: :json)
# Inspect with jq, store in JSONB column, debug easily

# Optional: binary for performance-critical paths
{:ok, binary} = PtcRunner.SubAgent.serialize(step, format: :binary)
```

**Decision: MFA tuples for serializable tools**

Anonymous functions aren't serializable. Two approaches:

```elixir
# Option A: Tool registry (adds global state)
PtcRunner.register_tool(:make_call, &MyApp.Phone.call/1)
# Serialize stores :make_call, deserialize looks up

# Option B: MFA tuples (no registry, already serializable) ← Preferred
tools: %{
  "make_call" => {MyApp.Phone, :call, []},
  "send_email" => {MyApp.Email, :send, []}
}
```

MFA tuples are simpler - no registry, no global state, naturally serializable. Less ergonomic than anonymous functions, but the trade-off is worth it for crash recovery and distributed resume.

**Relationship to Async**:
- Required for async to work (pending state must be persistable)
- But also useful standalone for crash recovery

---

## OTP Application Architecture

**Current**: Pure library. `SubAgent.run/2` is synchronous, sandboxes are ephemeral.

**Trigger**: Async tools + state persistence (v0.6-v0.7) require shared state → processes.

### Pattern: child_spec Without Auto-Start

```elixir
# User explicitly opts in
children = [
  {PtcRunner.Supervisor, name: :ptc, pool_size: 10},
]
```

No surprise processes on dependency add. Host app controls the tree.

### What to Supervise

- ✅ Agent sessions, pending ops registry, pool manager
- ❌ Sandbox processes (short-lived, meant to crash, disposable)

### Potential Tree

```
PtcRunner.Supervisor
├── AgentRegistry
├── PendingOps
├── SandboxPool (manager only, not individual sandboxes)
└── SessionSupervisor (DynamicSupervisor)
    └── Session (GenServer per long-lived agent)
```

All components optional. Multi-instance via `:name` option

---

## Tier 2: UX & Debugging

### 3. Debugging & Inspectability

**Problem**: When things go wrong (LLM generates bad Lisp, async resume fails, state corrupted), developers need visibility.

**Challenges unique to PTC**:
- LLM-generated code errors need clear attribution (line/column in generated Lisp)
- Suspended async state may sit in storage - need to inspect it
- Multi-turn conversations have complex message history

**Proposed Features**:

```elixir
# 1. Lisp execution tracing
SubAgent.run(agent,
  trace_lisp: true,  # Captures each form evaluated
  on_lisp_error: fn error, source, line, col ->
    Logger.error("Lisp error at #{line}:#{col}: #{error}")
  end
)

# 2. JSON state inspection (enabled by JSON serialization decision)
{:ok, json} = SubAgent.serialize(pending_step)
# In shell: cat state.json | jq '.pending_ops'
# In Elixir: Jason.decode!(json) |> get_in(["pending_ops"])

# 3. Step introspection
%Step{
  trace: %{
    turns: [...],           # Each LLM turn with timing
    tool_calls: [...],      # Every tool invocation
    lisp_forms: [...]       # Optional: each evaluated form
  }
}
```

**Why this matters**:
- "Why did the agent do X?" → inspect message history and tool calls
- "Why did async resume fail?" → `jq` the serialized state
- "Why did Lisp crash?" → line/column error with source context

### 4. Streaming Support

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

### 5. Conversation History & Serialization

**Problem**: Track conversation state for serialization and multi-turn context.

**Internal message struct (for serialization, not OpenAI-compatible):**

```elixir
@type turn_summary :: %{
  definitions: [%{name: String.t(), kind: :data | :function, arity: integer() | nil, doc: String.t() | nil}],
  output: [String.t()],  # println
  status: :ok | {:error, String.t()},
  program: String.t() | nil  # only on error
}

@type message :: %{
  role: :system | :user | :assistant,
  content: String.t() | nil,
  turn: turn_summary() | nil
}
```

**Purpose:** Internal state + serialization. LLM sees transformed view:
- Old turns → summaries (docstrings + println)
- Full program only on errors
- Memory: `Data: {x, emails} Functions: {fetch/1, filter/2}`

---

## Tier 3: Nice-to-Have

### 6. Tool Timeout with Partial Results

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

### 7. Pre/Post Hooks

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
v0.5: Observability & Debugging ✅ COMPLETE
  - Fix tool call tracking in traces ✅
  - Add messages to Step (opt-in via collect_messages: true) ✅
  - Document existing telemetry ✅
  - Lisp error attribution (line/column in error messages) ✅
  - Step introspection (step.turns with Turn structs, tool_calls, prints) ✅
  - Message compression (SingleUserCoalesced strategy, compression: option) ✅
  - Turn struct for immutable per-turn history ✅
  - Debug API (print_trace with view: :compressed, messages: true, etc.) ✅
  Architecture: Pure library (no processes)

v0.6: State Management
  - JSON serialization as default (Step <-> JSON)
  - Binary serialization as opt-in for high-throughput
  - Resume from serialized state
  - MFA tuple tool format for serializability
  - Version format for migrations
  - Optional: AgentRegistry with child_spec/1 (user-supervised)
  Architecture: First child_spec components (opt-in)

v0.7: Async Tools
  - {:async, id, immediate_result} pattern
  - PendingStep struct
  - SubAgent.resume/3
  - PTC-Lisp (await id) form (required for multi-async patterns)
  - PendingOps registry for tracking async operations
  - PtcRunner.Supervisor convenience module
  Architecture: Full child_spec suite (still opt-in)

v0.8: Streaming & Sessions
  - on_token callback
  - on_tool_start/end callbacks
  - LiveView helper module
  - Session GenServer for long-lived agents
  - SandboxPool for concurrency limiting
  Architecture: Complete supervision tree available

v1.0: Production Ready
  - Stable serialization format
  - Phoenix/Oban integration guides
  - Performance benchmarks
  - Decide: auto-start Application or stay opt-in
  Architecture: Evaluate user feedback on OTP adoption
```

---

## Decisions Made

These questions have been resolved based on real-world feedback:

1. **Async tool design**: ✅ **Lisp-level `(await)`** - Required for "call multiple async tools, combine results" patterns without multiple LLM round-trips.

2. **Serialization format**: ✅ **JSON as default** - Debuggability (`jq`) matters more than efficiency for async state that may sit in storage for minutes/hours. Binary available as opt-in for high-throughput.

3. **Tool serialization**: ✅ **MFA tuples** - No registry needed, naturally serializable, simpler than global tool registry.

4. **Multi-instance naming**: ✅ **Default + explicit override** - Simple cases need no config; multi-instance passes `instance: :name` only when multiple supervisors exist.

5. **Session lifecycle**: ✅ **Idle timeout + pending-aware + explicit** - Terminate after configurable idle timeout, but not if async ops pending, and allow explicit termination.

---

## Integration Patterns

**Recommended: Use as pure library within your GenServer**

```
Your app supervision tree:
├── YourApp.SessionSupervisor
│   └── YourApp.Orchestrator (your GenServer - owns lifecycle, PubSub, persistence)
│       └── calls PtcRunner.SubAgent.run/2 (pure function, no processes)
```

ptc_runner shouldn't duplicate app-level orchestration. Your GenServer handles session lifecycle, persistence, PubSub - ptc_runner just runs the tool loop.

**Optional: Use ptc_runner supervision for async-heavy workloads**

Only adopt `PtcRunner.Supervisor` when you need:
- Sandbox pooling (limit concurrent LLM-generated code execution)
- Built-in pending ops tracking
- Session GenServer with idle timeout + async-awareness

Even then, your app may still own the outer session lifecycle.

---

## Open Questions

### Async & State

1. **Message history**: Always collect, opt-in, or opt-out?

2. **Backpressure**: How to handle LLM rate limits in streaming mode?

3. **Await semantics**: Does `(await id)` block the Lisp program until result arrives, or return a placeholder that suspends the whole SubAgent?

### OTP Architecture

4. **GenServer mode**: Should SubAgent optionally run as a process that receives messages? If yes, what's the API?

5. **Auto-start vs opt-in**: Should v1.0 auto-start an Application, or always require explicit `child_spec` in host app?

6. **Pool implementation**: Use existing library (Poolboy, NimblePool) or custom pool for sandbox workers?

7. **State persistence hooks**: Is persistence a GenServer responsibility, or a callback module the user provides?

---

## References

- Current architecture: `lib/ptc_runner/sub_agent/` (Loop, Telemetry, ToolNormalizer)
- Step struct: `lib/ptc_runner/step.ex`
- Sandbox execution: `lib/ptc_runner/sandbox.ex`
