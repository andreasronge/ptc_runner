# Message History Optimization Specification

## Prerequisites

- ~~[#603 - Messages should be stored in Step](https://github.com/andreasronge/ptc_runner/issues/603)~~ ✅ Complete (closed 2026-01-09)

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
  raw_response: String.t(),  # full LLM output (always captured)
  program: String.t(),       # extracted code
  result: term(),
  prints: [String.t()],
  tool_calls: [tool_call()],
  memory: map(),             # snapshot after this turn
  success?: boolean()
}
```

Note: `raw_response` captures the complete LLM output including any reasoning/commentary outside the code block. This is always captured (no debug flag needed). The system prompt is NOT stored per-turn since it's static - use `SubAgent.SystemPrompt.generate_system/2` to view it.

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

### Message Responsibilities

| Location | Content | Cacheable? |
|----------|---------|------------|
| SYSTEM | PTC-Lisp syntax, return/fail usage, general instructions | Yes (static) |
| USER | Mission + all namespaces + execution history + turns left | Partial (tool/data stable) |
| ASSISTANT | LLM's PTC-Lisp code | No |

**Tools and data are NOT in SYSTEM prompt.** They're rendered in USER message alongside user definitions.

### Non-goals

- Tools are NOT described in system prompt (they're in USER message)
- System prompt does NOT change between turns
- No tool/data formatting logic in system prompt generation

### Message Structure

```
[SYSTEM, USER(mission + namespaces + execution history + turns left), ASSISTANT(current code)]
```

**Mission format**: The original mission text appears first, followed by namespace sections and execution history:

```
Find well-reviewed products in stock

;; === tool/ ===
(tool/search-reviews query)      ; query:string -> string

;; === data/ ===
data/products                    ; list[7], sample: {:name "Laptop", :price 1200}

;; === user/ (your prelude) ===
electronics                      ; = list[4], sample: {:name "Laptop"}

;; Tool calls made:
;   search-reviews("Electronics")

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

;; === tool/ ===
(tool/search-reviews query)      ; query:string -> string
(tool/get-inventory)             ; -> map

;; === data/ ===
data/products                    ; list[7], sample: {:name "Laptop", :price 1200}

;; === user/ (your prelude) ===
electronics                      ; = list[4], sample: {:name "Laptop", :price 1200}
reviews                          ; = string

;; Tool calls made:
;   search-reviews("Electronics")

;; Output:
Reviews: Customer Review Summary for Electronics...

Turns left: 4

[ASSISTANT]
```lisp
(def well-reviewed ["Laptop" "Monitor" "Keyboard"])
(return (filter (fn [p] (some (fn [name] (= (:name p) name)) well-reviewed)) electronics))
```
```

## Compressed Turn Format

The USER message contains unified namespace sections plus execution history:

```clojure
;; === tool/ ===
(tool/search-reviews query)      ; query:string -> string
(tool/send-notification opts)    ; opts:map -> nil

;; === data/ ===
data/products                    ; list[7], sample: {:name "Laptop", :price 1200}

;; === user/ (your prelude) ===
(fetch-users [category])         ; "Fetches users by category" -> list[5]
users                            ; = list[5], sample: {:name "Alice", :email "..."}

;; Tool calls made:
;   search-reviews("Electronics")
;   send-notification({:to "alice@example.com" :subject "Update"})

;; Output:
Found 5 users
Processing complete
```

**Turn 1** (empty prelude):
```clojure
;; === tool/ ===
(tool/search-reviews query)      ; query:string -> string

;; === data/ ===
data/products                    ; list[7], sample: {:name "Laptop", :price 1200}

;; No tool calls made
```

**Minimal** (no tools, no output):
```clojure
;; === data/ ===
data/items                       ; list[3]

;; === user/ (your prelude) ===
results                          ; = list[2], sample: {:id 1}
```

### Format Templates

**Namespace sections** (stable, cacheable):

| Section | Header | Entry Format |
|---------|--------|--------------|
| Tools | `;; === tool/ ===` | `(tool/{name} {params})      ; {signature}` |
| Data | `;; === data/ ===` | `data/{name}                    ; {type}, sample: {sample}` |
| User prelude | `;; === user/ (your prelude) ===` | See below |

**User prelude entries:**

| Type | Format |
|------|--------|
| Function with docstring + return | `({name} [{params}])           ; "{docstring}" -> {type}` |
| Function with docstring | `({name} [{params}])           ; "{docstring}"` |
| Function minimal | `({name} [{params}])` |
| Value with sample | `{name}                         ; = {type}, sample: {sample}` |
| Value without sample | `{name}                         ; = {type}` |

**Execution history** (changes each turn):

| Section | Header | Entry Format |
|---------|--------|--------------|
| Tool calls | `;; Tool calls made:` | `;   {name}({args})` |
| No calls | `;; No tool calls made` | (no entries) |
| Output | `;; Output:` | `{line}` (no prefix) |

**Section ordering** (empty sections omitted):
1. `tool/` namespace
2. `data/` namespace
3. `user/` namespace (prelude)
4. Tool calls made (or "No tool calls made")
5. Output

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

Failed turns use **conditional collapsing** based on recovery status:

| Current turn | Error history behavior |
|--------------|----------------------|
| **Succeeds** | Collapse all previous errors → clean single USER message |
| **Fails** | Show most recent error turn (limit: 1) |

### Rationale

Once the LLM successfully recovers from an error, old broken code becomes noise. But while still failing, recent error context helps recovery.

### Still Failing (show error)

```
{mission}

;; === tool/ ===
(tool/fetch-data key)            ; key:string -> map

;; === data/ ===
data/config                      ; map[3]

;; === user/ (your prelude) ===
users                            ; = list[5], sample: {:name "Alice"}

;; Tool calls made:
;   fetch-data("users")

---
Your previous attempt:
```clojure
(def x (broken-code))
```

Error: undefined symbol 'broken-code'
---

Turns left: 3
```

### After Recovery (errors collapsed)

Once a turn succeeds, all previous error turns are collapsed. The message returns to the clean format:

```
{mission}

;; === tool/ ===
(tool/fetch-data key)            ; key:string -> map

;; === data/ ===
data/config                      ; map[3]

;; === user/ (your prelude) ===
users                            ; = list[5], sample: {:name "Alice"}
result                           ; = map[2], sample: {:status "ok"}

;; Tool calls made:
;   fetch-data("users")

Turns left: 2
```

No error sections shown - the LLM has recovered and old mistakes are irrelevant.

## Compression Rules

| Content | Handling |
|---------|----------|
| Mission (original task) | Always at the top of USER message |
| Successful turn results | Compressed to summary |
| Failed turn code | Conditional: shown if still failing, collapsed after recovery |
| Tool calls | Accumulated, limited to most recent N |
| println output | Accumulated, limited to most recent N calls |
| SYSTEM prompt | Unchanged |

**CRITICAL: The mission is NEVER removed.**

## Namespace Design: REPL with Prelude

The LLM experience is modeled after a **Clojure REPL with a prelude**:

- **Turn 1**: Like starting a fresh REPL with `tool/` and `data/` namespaces loaded
- **Turn N+1**: Like continuing the session with a "prelude" of your previous definitions

This unified model means the LLM sees the same format regardless of whether data came from external input or previous turns.

### Three Namespaces

| Namespace | Meaning | Mutable? |
|-----------|---------|----------|
| `tool/` | Available tools (side effects) | No (external) |
| `data/` | Input data (read-only) | No (external) |
| `user/` | Your definitions (prelude) | Yes (grows each turn) |

### Unified Format

All namespaces are shown in a consistent Clojure-like format:

```clojure
;; === tool/ ===
(tool/fetch-users category)      ; category:string -> list[user], "Fetches users by category"
(tool/send-email opts)           ; opts:map -> nil, "Sends email notification"

;; === data/ ===
data/products                    ; list[7], sample: {:name "Laptop", :price 1200}
data/config                      ; map[3], sample: {:env "prod", :debug false}

;; === user/ (your prelude) ===
(helper-fn [category])           ; "Filters by category"
users                            ; = list[5], sample: {:name "Alice"}
```

**Turn 1**: `user/` section is empty or omitted
**Turn N+1**: `user/` section shows accumulated definitions from previous turns

### User Definitions (Best Effort)

User-defined functions show what we can capture:

| Component | Source | Always Available? |
|-----------|--------|-------------------|
| Name | `defn` form | Yes |
| Parameters | `[params]` vector | Yes |
| Docstring | Optional string | If provided |
| Return type | Last execution | Only if called |

```clojure
;; user/
(process-data [items filter-fn])  ; "Processes and filters items" -> list[3]
(helper [x])                      ; (uncalled)
results                           ; = list[5], sample: {:id 1, :name "Alice"}
```

### Prompt Caching Benefits

The `tool/` and `data/` sections are **stable** across turns (cache hit). Only `user/` changes:

```
Turn 1: [tool/ + data/] + [user/ empty]     ← tool/data cached
Turn 2: [tool/ + data/] + [user/ small]     ← tool/data cache hit
Turn 3: [tool/ + data/] + [user/ larger]    ← tool/data cache hit
```

This makes the system prompt highly cacheable.

### Auto-fallback Resolution

If the LLM writes `fetch-users` without namespace and no local definition exists, it resolves to `tool/fetch-users` (same for `data/`). Local definitions always take precedence. If both `tool/foo` and `data/foo` exist, bare `foo` raises a runtime exception (ambiguous reference).

## Debug and Tracing

Compression is for the **LLM prompt only**. Full history is always preserved in `step.turns`.

### print_trace API

```elixir
SubAgent.Debug.print_trace(step)                        # programs + results
SubAgent.Debug.print_trace(step, raw: true)             # + raw_response (LLM reasoning)
SubAgent.Debug.print_trace(step, view: :compressed)     # what LLM sees
SubAgent.Debug.print_trace(step, usage: true)           # add token stats
```

| Option | Values | Description |
|--------|--------|-------------|
| `view` | `:turns` (default), `:compressed` | Perspective |
| `raw` | `boolean` | Include `raw_response` in turns view |
| `usage` | `boolean` | Add token statistics |

### System Prompt

The system prompt is static and NOT stored per-turn. To view it:

```elixir
SubAgent.SystemPrompt.generate_system(agent)
```

## Uncompressed Mode

When `compression: false` (the default), the LLM sees full turn history as USER/ASSISTANT pairs:

```
[SYSTEM]      Static language spec (same as compressed)
[USER]        Mission + tool/ + data/
[ASSISTANT]   Turn 1 code (full)
[USER]        Turn 1 result + output
[ASSISTANT]   Turn 2 code (full)
[USER]        Turn 2 result + output + "Turns left: N"
```

Key differences from compressed mode:
- **Full code visible**: ASSISTANT messages contain complete programs
- **USER/ASSISTANT pairs**: One pair per turn instead of single coalesced USER
- **No user/ prelude**: Definitions visible in ASSISTANT history
- **No limits**: Full println output and tool calls preserved
- **No conditional collapsing**: Full errors shown

Use uncompressed mode for debugging, simple agents, or verifying compression behavior.

See [requirements](./message-history-optimization-requirements.md#uncompressed-mode-compression-false) for full specification.

## Resolved Design Decisions

**Append-only turns**: Turns are immutable once created. The compression strategy is a pure render function that transforms turns to messages on demand.

**Turn count source**: Always `length(turns)`, never derived from message count (which varies by compression strategy).

**Error handling**: Failed turns use conditional collapsing. While still failing, the most recent error is shown (limit: 1). After recovery, all error turns are collapsed. This balances error context with token efficiency.

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
