# Message History Optimization Specification

## Prerequisites

- [#603 - Messages should be stored in Step](https://github.com/andreasronge/ptc_runner/issues/603) must be completed first.

## Problem Statement

In multi-turn PTC-Lisp execution, the message array accumulates full programs from each turn:

```
Turn 1: assistant generates (def x 1) (println x)
Turn 2: assistant generates (def x 1) (def y 2) (println (+ x y))  # repeats turn 1
Turn 3: assistant generates (def x 1) (def y 2) (def z 3) ...      # repeats turn 1+2
```

The LLM sees all previous versions of its evolving program. This wastes tokens and can confuse the model about current state.

**Key insight from testing:** The LLM does NOT need to see its previous code. It only needs to know:
- What was defined (symbols available in memory)
- What actions were taken (tool calls, even if they returned nil)
- What was observed (println output)
- Whether execution succeeded or failed

## Core Concepts

### Turn

A `Turn` represents a single LLM interaction cycle. Turns are **immutable** once created - the turns list is **append-only**.

```elixir
%Turn{
  number: pos_integer(),
  program: String.t(),
  result: term(),
  prints: [String.t()],
  tool_calls: [tool_call()],
  memory: map(),           # snapshot after this turn
  success?: boolean()
}
```

### Compression as a Render Function

Compression is a **pure function** that transforms turns into messages:

```
turns (immutable history) → to_messages() → messages for LLM
```

The same turns can be rendered differently:
- Compressed view (for LLM prompts)
- Full view (for debugging)
- Custom strategies (future)

### Compression Strategies

Different strategies can render turns into messages differently. The default strategy is `SingleUserCoalesced`.

```elixir
# Behaviour
defmodule PtcRunner.SubAgent.Compression do
  @callback name() :: String.t()
  @callback to_messages(turns :: [Turn.t()], memory :: map(), opts :: keyword()) :: [message()]
end
```

## API

```elixir
# Enable with default strategy (SingleUserCoalesced)
compression: true

# Explicit strategy selection
compression: SingleUserCoalesced

# Strategy with options
compression: {SingleUserCoalesced, println_limit: 10, tool_call_limit: 15}

# Disabled (default)
compression: false
```

| Option | Default | Description |
|--------|---------|-------------|
| `println_limit` | 15 | Most recent println calls shown |
| `tool_call_limit` | 20 | Most recent tool calls shown |

Note: `max_turns` defaults to 5. Turn count comes from `length(turns)`, not message count.

## SingleUserCoalesced Strategy

The default compression strategy. Accumulates all successful turn context into a **single USER message**.

### Why Single USER Message?

If summaries appeared in ASSISTANT messages, the LLM might try to output `; Defined: ...` instead of code. By keeping summaries in the USER message:
- **USER** = "Here's your mission + what you've learned + turns remaining"
- **ASSISTANT** = "Here's my PTC-Lisp code"

The LLM never sees a previous ASSISTANT message with summary format, so there's no template to mimic.

### Message Structure

```
[SYSTEM, USER(mission + accumulated context + turns left), ASSISTANT(current code)]
```

**Mission format**: The original mission text appears first, followed by a blank line, then the accumulated context:

```
Find well-reviewed products in stock

; Tool calls:
;   search-reviews("Electronics")
; Defined: ...

Turns left: 4
```

### Before (Full History)

```
[SYSTEM] System prompt...

[USER] Find well-reviewed products in stock

[ASSISTANT]
```lisp
(def electronics (filter (fn [p] (= (:category p) "Electronics")) data/products))
(def reviews (tool/search-reviews "Electronics"))
(println "Reviews:" reviews)
```

[USER]
Reviews: Customer Review Summary for Electronics...
Turn 2 of 5

[ASSISTANT]
```lisp
(def electronics (filter ...))  ; repeated
(def reviews (tool/search-reviews "Electronics"))  ; repeated
(return (filter ...))
```
```

### After (SingleUserCoalesced)

```
[SYSTEM] System prompt...

[USER] Find well-reviewed products in stock

; Tool calls:
;   search-reviews("Electronics")
; Defined: electronics = list[4], sample: {:name "Laptop", :price 1200, ...}
; Defined: reviews = string
; Output:
Reviews: Customer Review Summary for Electronics...

Turns left: 4

[ASSISTANT]
```lisp
(def well-reviewed ["Laptop" "Monitor" "Keyboard"])
(return (filter (fn [p] (some (fn [name] (= (:name p) name)) well-reviewed)) electronics))
```
```

## Compressed Turn Format

Successful turns are replaced with a summary showing:

```
; Tool calls:
;   search-reviews("Electronics")
;   send-notification({:to "alice@example.com" :subject "Update"})
; Function: fetch-users - "Fetches users by category, returns list of user maps"
; Defined: users - "Active users from API" = list[5], sample: {:name "Alice", :email "..."}
; Output:
Found 5 users
Processing complete
```

Without docstrings or tool calls:
```
; Function: helper-fn
; Defined: users = list[5], sample: {:name "Alice", :email "..."}
```

If no tool calls have been made across any turns:
```
; No tool calls made
; Defined: ...
```

### Format Templates

| Component | Format Template |
|-----------|-----------------|
| Tool calls header | `; Tool calls:` |
| Tool call entry | `;   {name}({args})` |
| No tool calls | `; No tool calls made` |
| Function with docstring | `; Function: {name} - "{docstring}"` |
| Function without docstring | `; Function: {name}` |
| Defined with docstring + sample | `; Defined: {name} - "{docstring}" = {type}, sample: {sample}` |
| Defined with sample (no docstring) | `; Defined: {name} = {type}, sample: {sample}` |
| Defined without sample | `; Defined: {name} = {type}` |
| Output header | `; Output:` |
| Output line | `{line}` (no prefix, preserves original output) |

**Section ordering** (empty sections omitted):
1. Tool calls (or "No tool calls made")
2. Functions
3. Defined
4. Output

### Type Vocabulary

| Elixir Value | Type Label | Example |
|--------------|------------|---------|
| `[]` | `list[0]` | `; Defined: items = list[0]` |
| `[1, 2, 3]` | `list[3]` | `; Defined: items = list[3], sample: 1` |
| `%{}` | `map[0]` | `; Defined: data = map[0]` |
| `%{a: 1}` | `map[1]` | `; Defined: data = map[1], sample: {:a 1}` |
| `"hello"` | `string` | `; Defined: name = string, sample: "hello"` |
| `42` | `integer` | `; Defined: count = integer, sample: 42` |
| `3.14` | `float` | `; Defined: ratio = float, sample: 3.14` |
| `true`/`false` | `boolean` | `; Defined: flag = boolean, sample: true` |
| `:keyword` | `keyword` | `; Defined: status = keyword, sample: :active` |
| `nil` | `nil` | `; Defined: result = nil` |
| closure | `#fn[...]` | `; Function: helper` |

### Truncation

All value truncation uses `Format.to_clojure/2`:

```elixir
# For samples in Defined lines
Format.to_clojure(value, limit: 3, printable_limit: 80)

# For tool call arguments
Format.to_clojure(args, limit: 3, printable_limit: 60)
```

**Tool call format**: Tool calls show the tool name and arguments in Clojure syntax. Tool results are NOT shown in the tool call list - they appear as defined values if stored via `def`.

**println output truncation**: Each `(println ...)` call counts as one call regardless of arguments. The limit applies to calls, not lines.

## Samples vs Output

To avoid showing data twice, summaries use either automatic samples or explicit println output:

| Turn has println? | Defined shows | Output shows |
|-------------------|---------------|--------------|
| No | `name = type, sample: ...` | (nothing) |
| Yes | `name = type` (no sample) | println output |

**Exploration mode** (no println):
```clojure
(def reviews (tool/search-reviews "Electronics"))
(def inventory (tool/get-inventory))
```
```
; Defined: reviews = string, sample: "Customer Review Summary for Elec..."
; Defined: inventory = string, sample: "Warehouse Inventory Report (as..."
```

**Explicit mode** (with println):
```clojure
(def reviews (tool/search-reviews "Electronics"))
(println "Reviews:" reviews)
```
```
; Defined: reviews = string
; Output:
Reviews: Customer Review Summary for Electronics...
```

This forces intentionality - the LLM either explores (automatic samples) or explicitly prints what it wants to see.

## Tool Calls Are Critical

Many tools perform actions (send emails, make API calls) and return nil. Without tool call history, the LLM loses track of what actions it already took.

```clojure
(tool/make-call {:to "Alice" :message "Meeting at 3pm"})
(tool/make-call {:to "Bob" :message "Bring documents"})
```

**With tool call history:**
```
; Tool calls:
;   make-call({:to "Alice" :message "Meeting at 3pm"})
;   make-call({:to "Bob" :message "Bring documents"})
```

Essential for:
- **Avoiding duplicate actions**: LLM knows it already called Alice
- **Tracking progress**: LLM knows 2 of 5 calls completed
- **Error recovery**: If turn 3 fails, LLM sees what succeeded in turns 1-2

## Failed Turns

**Failed turns are NOT compressed.** When a turn fails, the full code is preserved so the LLM sees exactly what it tried and why it failed.

```
{mission}

; Tool calls:
;   fetch-data("users")
; Defined: users = list[5], ...

---
Your previous attempt:
```clojure
(def x (broken-code))
```

Error: undefined symbol 'broken-code'
---

Turns left: 3
```

Multiple failed turns each keep their full code blocks.

## Compression Rules

| Content | Handling |
|---------|----------|
| Mission (original task) | Always at the top of USER message |
| Successful turn results | Compressed to summary |
| Failed turn code | Kept full (LLM needs to see broken code) |
| Tool calls | Accumulated, limited to most recent N |
| println output | Accumulated, limited to most recent N calls |
| SYSTEM prompt | Unchanged |

**CRITICAL: The mission is NEVER removed.**

## Namespace Design

Clear namespace separation helps the LLM distinguish between different types of symbols:

| Namespace | Meaning | Example |
|-----------|---------|---------|
| `tool/` | Provided tools (side effects) | `(tool/fetch-users "admin")` |
| `data/` | Provided input data (read-only) | `(filter ... data/products)` |
| (bare) | User definitions | `(my-helper x)` |

**Auto-fallback**: If the LLM writes `fetch-users` without namespace and no local definition exists, it resolves to `tool/fetch-users` (same for `data/`). Local definitions always take precedence. If both `tool/foo` and `data/foo` exist, bare `foo` raises a runtime exception (ambiguous reference).

## Debug and Tracing

Compression is for the **LLM prompt only**. Full history is always preserved:

| Purpose | Data Source |
|---------|-------------|
| LLM prompt | `Compression.to_messages(turns, memory, opts)` |
| Debugging | `step.turns` (full Turn structs) |
| Turn count | `length(step.turns)` |

The turns list contains complete history:
```elixir
turns: [
  %Turn{number: 1, program: "(def x ...)", prints: [...], ...},
  %Turn{number: 2, program: "(return y)", prints: [...], ...}
]
```

When building the LLM prompt, we render turns via the compression strategy. When debugging, we use the full turns directly.

## Resolved Design Decisions

**Append-only turns**: Turns are immutable once created. The compression strategy is a pure render function that transforms turns to messages on demand.

**Turn count source**: Always `length(turns)`, never derived from message count (which varies by compression strategy).

**Error handling**: All failed turns keep their full code. This prevents the LLM from cycling through the same mistakes.

**Accumulated definitions**: Show all definitions from all previous turns, except when redefined - only show the latest. Order follows definition order.

**println history limit**: FIFO truncation. Most recent N println calls shown. Older dropped from summaries but preserved in turns.

**Tool call history limit**: FIFO truncation. Most recent N tool calls shown with truncated args.

**Single USER message**: Default strategy (`SingleUserCoalesced`) accumulates all context into one USER message to prevent format confusion.

**Default value**: `compression` defaults to `false` (opt-in).

## Validated by Testing

These findings come from spike testing with real LLMs:

1. **Data exploration task**: LLM completed in 3 turns using compressed format. It used data samples from summaries to understand structure.

2. **Tool-based task**: LLM completed in 2 turns. It used println to inspect tool results, then processed them without seeing the tool-calling code.

3. **Key finding**: LLMs don't need their previous code - they need the **results** of their previous code.
