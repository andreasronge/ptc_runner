# Specification: Return Retries

**Status:** Draft (v2)

## Summary

Add `return_retries` option to SubAgent that grants extra turns when the LLM is in "must return" mode and produces invalid output. This enables single-shot agents to self-correct without enabling full multi-turn investigation.

## Motivation

Current behavior with `max_turns: 1` (single-shot):
- LLM receives prompt with "you must return directly"
- If LLM produces invalid PTC-Lisp syntax or fails schema validation → immediate failure
- No opportunity to self-correct using the existing error feedback mechanism

This is problematic because:
- PTC-Lisp produces excellent error messages that could enable self-correction
- Single-shot is desirable (no investigation turns) but fragile (no error recovery)
- Users must choose between reliability (multi-turn) and efficiency (single-shot)

## Design

### API

```elixir
# Single-shot, no correction (current default)
SubAgent.run(ctx, max_turns: 1)

# Single-shot + 1 correction turn for return errors
SubAgent.run(ctx, max_turns: 1, return_retries: 1)

# Multi-turn + correction on final turn
SubAgent.run(ctx, max_turns: 3, return_retries: 2)
```

### Semantics

| Option | Purpose | Default |
|--------|---------|---------|
| `max_turns` | Investigation/tool-use budget | 5 |
| `return_retries` | Extra turns in must-return mode | 0 |

**Key distinction:**
- `max_turns` = turns for doing work (tool calls, data gathering, reasoning)
- `return_retries` = extra turns granted only when in must-return mode (final turn phase)

### Unified Budget Model

Use a single budget counter with two tracking variables:

```elixir
# Initial state
work_turns_remaining = max_turns
retry_turns_remaining = return_retries

# Before each turn
must_return_mode = (work_turns_remaining <= 1)
tools_available = (work_turns_remaining > 1)  # Tools stripped on final work turn and retries
```

**State machine:**

```
┌─────────────────────────────────────────────────────────────┐
│  NORMAL MODE (work_turns_remaining > 1)                     │
│  - Tools available                                          │
│  - Can investigate, call tools, gather data                 │
│  - On error: feed back, decrement work_turns_remaining      │
│  - On (return ...): validate, if valid → SUCCESS            │
│                      if invalid → feed back, decrement      │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ work_turns_remaining == 1
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  MUST-RETURN MODE (work_turns_remaining <= 1)               │
│  - Tools STRIPPED from prompt                               │
│  - LLM told "you MUST return now"                           │
│  - On valid return: SUCCESS                                 │
│  - On error/invalid:                                        │
│      if retry_turns_remaining > 0: decrement, stay in mode  │
│      else: FAIL                                             │
│  - On (fail reason): FAIL (no retry)                        │
└─────────────────────────────────────────────────────────────┘
```

### Early Returns (Resolved: Option B)

If LLM calls `(return ...)` before the final turn and it fails validation:
- **Consume a work turn**, not a retry turn
- Rationale: The LLM still has investigation budget; let it use that first
- `return_retries` is the "emergency" budget for when work turns are exhausted

Example with `max_turns: 5, return_retries: 1`:
```
Turn 1: LLM calls (return {:x "bad"}) → validation fails
        work_turns_remaining: 5 → 4 (consumed a work turn, NOT a retry)
Turn 2: LLM calls (return {:x 42}) → valid → SUCCESS
```

### Tool Stripping in Must-Return Mode

When `must_return_mode` is active:
- Tools are **removed from the prompt entirely**
- This structurally enforces the constraint (LLM can't "wander off")
- The LLM sees only the task, data, and the requirement to return

### Context Management for Retries

To prevent context window inflation during retries, collapse previous failed attempts:

**First retry feedback:**
```
Your previous response had an error:
{error_message}

Retry 1 of {N}. Please fix the error and call (return ...).
```

**Subsequent retry feedback (replaces previous):**
```
Your previous response still had an error:
{error_message}

Retry {M} of {N}. Please fix the error and call (return ...).
```

Previous failed responses are **not** accumulated in message history. Only the most recent error is shown.

### Turn Counting Examples

```elixir
# Example 1: max_turns=1, return_retries=0 (single-shot, no retry)
# Turn 1: must-return mode, tools stripped
#         LLM returns → syntax error → FAIL (no retries)
# Total LLM calls: 1

# Example 2: max_turns=1, return_retries=1 (single-shot with retry)
# Turn 1: must-return mode, tools stripped
#         LLM returns → syntax error → retry
# Turn 2: must-return mode, error feedback
#         LLM returns → valid → SUCCESS
# Total LLM calls: 2

# Example 3: max_turns=3, return_retries=1 (multi-turn with retry)
# Turn 1: normal mode, tools available
#         LLM investigates with tools
# Turn 2: normal mode, tools available
#         LLM investigates more
# Turn 3: must-return mode, tools stripped
#         LLM returns → schema error → retry
# Turn 4: must-return mode, error feedback
#         LLM returns → valid → SUCCESS
# Total LLM calls: 4

# Example 4: max_turns=5, return_retries=0, early return fails
# Turn 1: normal mode
#         LLM calls (return {:x "bad"}) → validation error
#         work_turns: 5 → 4 (consumed work turn)
# Turn 2: normal mode (still has 4 work turns)
#         LLM calls (return {:x 42}) → valid → SUCCESS
# Total LLM calls: 2
```

### Maximum Total LLM Calls

```
max_total_calls = max_turns + return_retries
```

For `max_turns: 3, return_retries: 2`, worst case is 5 LLM calls.

## Prompt Changes

All prompt strings are defined in `priv/prompts/` using Mustache templates for maintainability.

### Template: `priv/prompts/must_return_warning.md`

```markdown
{{#has_retries}}
IMPORTANT: This is your final turn. You MUST call (return ...) with your result.
If your response has errors, you will have {{retry_count}} correction attempt(s).
{{/has_retries}}
{{^has_retries}}
IMPORTANT: This is your final turn. You MUST call (return ...) with your result.
{{/has_retries}}
```

### Template: `priv/prompts/retry_feedback.md`

```markdown
Your previous response had an error:
{{error_message}}

Correction attempt {{current_retry}} of {{total_retries}}. Please fix the error and call (return ...).
```

## Turn Type Marking

Add a `type` field to the Turn struct to distinguish turn phases:

```elixir
defmodule PtcRunner.SubAgent.Loop.Turn do
  defstruct [
    # ... existing fields
    type: :normal  # :normal | :must_return | :retry
  ]
end
```

| Type | Meaning |
|------|---------|
| `:normal` | Investigation turn with tools available |
| `:must_return` | Final work turn, tools stripped |
| `:retry` | Retry turn after failed return |

This enables:
- Clear tracing/debugging ("the agent struggled on retry turns")
- UI differentiation in observability tools
- Analytics on retry frequency

## Error Handling Flow

```
┌─────────────────────────────────────────────────────────────┐
│  Single Loop: while (work_turns_remaining > 0 OR            │
│                      retry_turns_remaining > 0)             │
│                                                             │
│    must_return = (work_turns_remaining <= 1)                │
│    in_retry = (work_turns_remaining == 0)                   │
│                                                             │
│    1. Generate prompt:                                      │
│       - If must_return: strip tools, add warning            │
│       - If in_retry: add retry feedback (collapsed)         │
│    2. Call LLM                                              │
│    3. Parse & execute                                       │
│    4. Handle result:                                        │
│       SUCCESS (valid return):                               │
│         → done, return {:ok, step}                          │
│                                                             │
│       EXPLICIT FAIL (fail reason):                          │
│         → done, return {:error, step} (no retry)            │
│                                                             │
│       ERROR (syntax, runtime, validation):                  │
│         → if in_retry:                                      │
│             retry_turns_remaining -= 1                      │
│           else:                                             │
│             work_turns_remaining -= 1                       │
│         → store error for feedback                          │
│         → continue loop                                     │
│                                                             │
│  If loop exits with no success:                             │
│    → {:error, step} with reason :budget_exhausted           │
└─────────────────────────────────────────────────────────────┘
```

## State Changes

### Loop State

```elixir
%{
  # Counters
  work_turns_remaining: integer(),   # Starts at max_turns
  retry_turns_remaining: integer(),  # Starts at return_retries

  # Derived (computed each iteration)
  must_return_mode: boolean(),
  in_retry_phase: boolean(),

  # Error tracking (for collapsed feedback)
  last_error: String.t() | nil
}
```

### Step Result

No changes to `Step` struct. Turn type is reflected in individual turns:

```elixir
%Step{
  turns: [
    %Turn{type: :normal, ...},
    %Turn{type: :normal, ...},
    %Turn{type: :must_return, ...},
    %Turn{type: :retry, ...}
  ],
  # ...
}
```

### Failure Reasons

Single failure reason for exhausted budget:

```elixir
:budget_exhausted  # Both work turns and retry turns consumed
```

This replaces the need for separate `:max_turns_exceeded` and `:return_retries_exhausted` reasons.

## Configuration Validation

```elixir
# Valid configurations
max_turns: 1, return_retries: 0   # Single-shot, no retry
max_turns: 1, return_retries: 3   # Single-shot with retries
max_turns: 5, return_retries: 1   # Multi-turn with final retry
max_turns: 5, return_retries: 0   # Multi-turn, no retry (current behavior)

# Invalid configurations
return_retries: -1                # Error: must be >= 0
return_retries: "1"               # Error: must be integer
max_turns: 0                      # Error: must be >= 1
```

## Tracer Events

Add distinct trace events for retry phases:

```elixir
# Normal turn
{:trace, :turn_start, %{turn: 1, type: :normal, tools_count: 5}}
{:trace, :turn_end, %{turn: 1, type: :normal, result: :continue}}

# Must-return turn
{:trace, :turn_start, %{turn: 3, type: :must_return, tools_count: 0}}
{:trace, :turn_end, %{turn: 3, type: :must_return, result: :error}}

# Retry turn
{:trace, :turn_start, %{turn: 4, type: :retry, attempt: 1, remaining: 1}}
{:trace, :turn_end, %{turn: 4, type: :retry, result: :success}}
```

The tracer should show "error evolution" across retries to help debug constraint issues.

## Implementation Plan

### Phase 1: Core Loop Changes

**File: `lib/ptc_runner/sub_agent/loop.ex`**

1. Add `return_retries` to options parsing with default `0`
2. Replace `remaining_turns` with `work_turns_remaining` and `retry_turns_remaining`
3. Compute `must_return_mode` and `in_retry_phase` each iteration
4. Implement single unified loop with the state machine logic
5. Strip tools from prompt when `must_return_mode` is true

### Phase 2: Prompt Templates

**Files:**
- `priv/prompts/must_return_warning.md` (new)
- `priv/prompts/retry_feedback.md` (new)

**File: `lib/ptc_runner/sub_agent/loop/turn_feedback.ex`**

1. Load and render new templates
2. Implement context collapsing for retry feedback
3. Add retry count to must-return warning

### Phase 3: Turn Type Tracking

**File: `lib/ptc_runner/sub_agent/loop/turn.ex`**

1. Add `type` field with values `:normal | :must_return | :retry`
2. Set type based on loop state when creating Turn

**File: `lib/ptc_runner/tracer.ex`**

1. Include turn type in trace events
2. Add retry-specific metadata (attempt number, remaining)

### Phase 4: Documentation

1. Update `docs/guides/subagent-getting-started.md` - add return_retries option
2. Update `docs/guides/subagent-advanced.md` - detailed retry behavior
3. Add examples to livebooks

## Files to Modify

| File | Changes |
|------|---------|
| `lib/ptc_runner/sub_agent/loop.ex` | Unified loop with work/retry counters, tool stripping |
| `lib/ptc_runner/sub_agent/loop/turn_feedback.ex` | Template rendering, context collapsing |
| `lib/ptc_runner/sub_agent/loop/turn.ex` | Add `type` field |
| `lib/ptc_runner/tracer.ex` | Turn type in events, retry metadata |
| `priv/prompts/must_return_warning.md` | New template |
| `priv/prompts/retry_feedback.md` | New template |

## Testing Strategy

### Unit Tests

```elixir
test "return_retries defaults to 0"

test "return_retries: 1 allows one correction attempt in must-return mode" do
  agent = SubAgent.new(prompt: "Return data", signature: "() -> {x :int}", max_turns: 1)

  llm = mock_sequence([
    {:ok, "(return {:x \"not_int\"})"},  # Schema error
    {:ok, "(return {:x 42})"}             # Valid
  ])

  {:ok, step} = SubAgent.run(agent, llm: llm, return_retries: 1)
  assert step.return == %{x: 42}
  assert length(step.turns) == 2
  assert Enum.at(step.turns, 0).type == :must_return
  assert Enum.at(step.turns, 1).type == :retry
end

test "early return failure consumes work turn, not retry" do
  agent = SubAgent.new(prompt: "...", signature: "() -> {x :int}", max_turns: 5)

  llm = mock_sequence([
    {:ok, "(return {:x \"bad\"})"},  # Early return fails
    {:ok, "(return {:x 42})"}         # Retry succeeds
  ])

  {:ok, step} = SubAgent.run(agent, llm: llm, return_retries: 0)
  assert step.return == %{x: 42}
  assert length(step.turns) == 2
  # Both are normal turns (not retry) because work budget was used
  assert Enum.at(step.turns, 0).type == :normal
  assert Enum.at(step.turns, 1).type == :normal
end

test "tools are stripped in must-return mode" do
  agent = SubAgent.new(
    prompt: "...",
    signature: "() -> {x :int}",
    tools: %{foo: fn -> "bar" end},
    max_turns: 1
  )

  llm = fn req ->
    # Verify tools are not in the prompt
    refute String.contains?(req.system, "foo")
    {:ok, "(return {:x 42})"}
  end

  {:ok, _step} = SubAgent.run(agent, llm: llm)
end

test "budget_exhausted when all turns consumed" do
  agent = SubAgent.new(prompt: "...", signature: "() -> {x :int}", max_turns: 1)

  llm = mock_sequence([
    {:ok, "(return {:x \"bad\"})"},
    {:ok, "(return {:x \"still_bad\"})"}
  ])

  {:error, step} = SubAgent.run(agent, llm: llm, return_retries: 1)
  assert step.fail.reason == :budget_exhausted
end

test "explicit (fail) does not trigger retry" do
  agent = SubAgent.new(prompt: "...", max_turns: 1)

  llm = fn _ -> {:ok, "(fail \"intentional\")"} end

  {:error, step} = SubAgent.run(agent, llm: llm, return_retries: 5)
  assert step.fail.reason == :explicit_fail
  assert length(step.turns) == 1
end

test "context is collapsed across retries" do
  agent = SubAgent.new(prompt: "...", signature: "() -> {x :int}", max_turns: 1)

  messages_received = []
  llm = fn req ->
    # Track message count to verify no accumulation
    send(self(), {:messages, length(req.messages)})
    {:ok, "(return {:x \"bad\"})"}
  end

  {:error, _} = SubAgent.run(agent, llm: llm, return_retries: 3)

  # Each retry should have same message count (collapsed, not accumulated)
  # Implementation detail: verify messages don't grow unboundedly
end
```

### Integration Tests

```elixir
test "return_retries works with JSON output mode" do
  agent = SubAgent.new(
    prompt: "Return a number",
    output: :json,
    signature: "() -> {x :int}",
    max_turns: 1
  )

  llm = mock_sequence([
    {:ok, ~s|{"x": "not_int"}|},  # Invalid
    {:ok, ~s|{"x": 42}|}          # Valid
  ])

  {:ok, step} = SubAgent.run(agent, llm: llm, return_retries: 1)
  assert step.return == %{"x" => 42}
end

test "turn types are correctly traced" do
  # Verify tracer receives correct turn type metadata
end
```

### E2E Tests

```elixir
@tag :e2e
test "real LLM self-corrects with return_retries" do
  # Use a prompt that's likely to cause initial errors
  # Verify LLM can recover using error feedback
end
```

## Success Criteria

1. `return_retries: 0` maintains current behavior (no retries)
2. Early return failures consume work turns first (Option B)
3. Tools are stripped in must-return mode (structural enforcement)
4. Context is collapsed across retries (no inflation)
5. Turn types are clearly marked (`:normal`, `:must_return`, `:retry`)
6. Traces show error evolution across retries
7. Works with both `:ptc_lisp` and `:json` output modes
8. Explicit `(fail)` bypasses retry mechanism
9. All prompt strings in `priv/prompts/` templates

## Design Decisions Summary

| Decision | Resolution | Rationale |
|----------|------------|-----------|
| Early return failures | Consume work turns first | More intuitive; retries are "emergency" budget |
| Tool availability | Strip tools in must-return mode | Structural enforcement > behavioral |
| Context management | Collapse previous failures | Prevent context inflation |
| Loop structure | Single unified loop | Simpler than two separate loops |
| Turn marking | Add `type` field to Turn | Clear tracing and debugging |
| Prompt strings | Mustache templates in `priv/prompts/` | Maintainability |
| Failure reason | Single `:budget_exhausted` | Simpler than multiple reasons |
