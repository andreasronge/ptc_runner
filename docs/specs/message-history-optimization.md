# Message History Optimization Specification

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
- What was observed (println output, tool results)
- Whether execution succeeded or failed

## API

```elixir
SubAgent.run(agent,
  llm: llm,
  compress_history: true,      # default: false
  println_history_limit: 15    # default: 15, only used when compress_history: true
)
```

Options are inherited like other SubAgent options (e.g., `llm`). When `compress_history` is enabled:
- Old successful turns are compressed to summaries
- Definitions accumulate across turns (latest wins if redefined)
- println output is limited to most recent N outputs

## Design Principle

**Compress the code, preserve the learnings.**

The LLM wrote code to learn something. Once executed, the code itself is disposable - only the results matter. Summaries capture what the LLM learned, not how it learned it.

## What the LLM Sees

### Compressed Turn Format

Old successful assistant turns are replaced with a summary showing:

```
; Function: fetch-users - "Fetches users by category, returns list of user maps"
; Defined: users - "Active users from API" = list[5], sample: %{name: "Alice", email: "..."}
; Output:
Found 5 users
Processing complete
```

Without docstrings:
```
; Function: helper-fn
; Defined: users = list[5], sample: %{name: "Alice", email: "..."}
```

### Summary Components

| Component | Purpose | Format |
|-----------|---------|--------|
| **Functions** | Available to call | `name - "docstring"` |
| **Data** | Available to reference | `name - "docstring" = type, sample: value` |
| **Output** | What LLM explicitly printed | `println` output only |
| **Status** | Success or failure | Implicit (errors keep full code) |

**Samples OR println, not both.** To avoid showing data twice, summaries use either automatic samples or explicit println output:

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
(def inventory (tool/get-inventory))
(println "Reviews:" reviews)
(println "Inventory:" inventory)
```
```
; Defined: reviews = string
; Defined: inventory = string
; Output:
Reviews: Customer Review Summary for Electronics...
Inventory: Warehouse Inventory Report...
```

This forces intentionality - the LLM either explores (automatic samples) or explicitly prints what it wants to see. No duplication.

Both `defn` and `def` support docstrings:
```clojure
(defn fetch-users "Fetches users by category" [category] ...)
(def users "Active users from API" (fetch-users "admin"))
```

We capture docstrings at execution time. Prompts should encourage descriptive docstrings. Sample truncation uses existing truncation algorithm.

### Data Samples Are Critical

For defined data values, include enough structure for the LLM to understand what it's working with:

```
; Defined: products = list[7], sample: %{name: "Laptop", price: 1200, category: "Electronics"}
```

This tells the LLM:
- `products` exists and is a list of 7 items
- Each item has `:name`, `:price`, `:category` keys
- It can write code like `(filter (fn [p] (> (:price p) 100)) products)`

Without the sample, the LLM doesn't know the data structure.

### Tool Results Are Values, Not Output

Tools return values that get stored via `def`. They appear in summaries as truncated samples, not full output:

```clojure
;; LLM writes:
(def reviews (tool/search-reviews "Electronics"))
(def inventory (tool/get-inventory))
```

```
;; Summary shows:
; Defined: reviews = string, sample: "Customer Review Summary for Elec..."
; Defined: inventory = string, sample: "Warehouse Inventory Report:..."
```

If the LLM needs to see full tool output in a later turn, it should print it:

```clojure
(println "Full reviews:" reviews)
```

This keeps summaries compact. The LLM controls verbosity via explicit `println`.

## Message Array Transformation

### Before (Full History)

```
[SYSTEM] System prompt...

[USER] Find well-reviewed products in stock

[ASSISTANT]
```lisp
(def electronics (filter (fn [p] (= (:category p) "Electronics")) ctx/products))
(def reviews (tool/search-reviews "Electronics"))
(def inventory (tool/get-inventory))
(println "Reviews:" reviews)
(println "Inventory:" inventory)
```

[USER]
Reviews: Customer Review Summary for Electronics:
- Laptop: Average rating 4.5/5...
Inventory: Warehouse Inventory Report:
Laptop - 23 units in stock...
Turn 2 of 5

[ASSISTANT]
```lisp
(def electronics (filter ...))  ; repeated
(def reviews (tool/search-reviews "Electronics"))  ; repeated
(def inventory (tool/get-inventory))  ; repeated
(def well-reviewed ["Laptop" "Monitor" "Keyboard"])
(return (filter ...))
```
```

### After (Compressed History)

```
[SYSTEM] System prompt...

[USER] Find well-reviewed products in stock

[ASSISTANT]
; Defined: electronics = list[4], sample: %{name: "Laptop", price: 1200, ...}
; Defined: reviews = string, sample: "Customer Review Summary for Elec..."
; Defined: inventory = string, sample: "Warehouse Inventory Report:..."
; Output:
Reviews: Customer Review Summary for Electronics:
- Laptop: Average rating 4.5/5. - Mouse: Average rating 3.2/5...
Inventory: Warehouse Inventory Report:
Laptop - 23 units in stock. Mouse - OUT OF STOCK...

[USER]
Turn 2 of 5

[ASSISTANT]
```lisp
(def well-reviewed ["Laptop" "Monitor" "Keyboard"])
(return (filter (fn [x] (some #(= x %) ["Laptop" "Monitor" "Keyboard"]) well-reviewed)))
```
```

The LLM sees:
- What it defined (with truncated samples)
- What it explicitly printed (full output)
- Turn info

It does NOT see:
- Previous code
- Repeated definitions

## Compression Rules

### What Gets Compressed

| Message Type | Compress? | Reason |
|--------------|-----------|--------|
| Old successful ASSISTANT | Yes | Code is disposable, results matter |
| ASSISTANT with error | No | LLM needs to see broken code to fix it |
| Latest ASSISTANT | No | LLM just wrote it, may need to iterate |
| USER feedback | No | Already minimal (output + turn info) |
| SYSTEM prompt | No | Static, needed for context |
| Initial USER message | No | The task/question |

### Compression Timing

Compress at the **start of each new turn**, not at storage time:

```
Turn 1 completes → messages stored as-is
Turn 2 starts    → compress Turn 1 assistant message before sending to LLM
Turn 2 completes → messages stored (Turn 1 compressed, Turn 2 full)
Turn 3 starts    → compress Turn 2 assistant message before sending to LLM
```

This ensures the "current" turn always has full code during iteration.

## Scenarios

### Successful Multi-Turn

```
[system, user, assistant₁(summary), feedback₁, assistant₂(summary), feedback₂, assistant₃(full)]
```

Only the final assistant message has code.

### Error Recovery

```
[system, user, assistant₁(summary), feedback₁, assistant₂(full+error), error_feedback₂, assistant₃(full)]
```

Turn 2 stays full because it errored - LLM needs to see what went wrong.

### Tool-Heavy Workflow

```
[system, user, assistant₁(summary with tool output), feedback₁, assistant₂(full)]
```

Turn 1 summary includes full tool results, Turn 2 processes them.

### Single-Shot (max_turns: 1)

No compression needed - only one turn.

## Validated by Testing

These findings come from spike testing with real LLMs (Gemini Flash):

1. **Data exploration task**: LLM completed in 3 turns using compressed format. It used data samples from summaries to understand structure.

2. **Tool-based task**: LLM completed in 2 turns. It used println to inspect tool results, then processed them in the next turn without seeing the tool-calling code.

3. **Key finding**: LLMs don't need their previous code - they need the **results** of their previous code. Summaries that capture definitions (with samples) and explicit println output provide sufficient context.

## Debug and Tracing

Compression is for the **LLM prompt only**. Full programs are preserved for debugging:

| Purpose | What's stored |
|---------|---------------|
| LLM prompt (next turn) | Compressed summaries |
| Step.trace | Full programs from every turn |
| Serialization (async) | Both: summaries for resume, full programs for debug |

The trace always contains the complete history:
```
trace: [
  %{turn: 1, program: "(def x ...)\n(println x)", output: "...", definitions: [...]},
  %{turn: 2, program: "(def y ...)\n(return y)", output: "...", definitions: [...]}
]
```

When building the LLM prompt, we render old turns as summaries. When debugging or inspecting, we use the full trace.

This separation means:
- Token-efficient prompts for multi-turn execution
- Full visibility for debugging, logging, and analysis
- Async resume can rebuild either view from stored state

## Resolved Design Decisions

**Error context window**: Keep N turns of full code before an error, not just the error turn. This gives the LLM enough context to understand what led to the failure.

**Accumulated definitions**: Show all definitions from all previous turns (accumulated), except when a symbol has been redefined - only show the latest definition. Definitions persist in memory, so the summary reflects what's actually available.

**println history limit**: Truncate older println output to avoid unbounded growth. Configurable with default (e.g., 15 most recent println outputs shown). Older outputs are dropped from summaries but preserved in trace for debugging.

**Default value**: `compress_history` defaults to `false` (opt-in). Safer for initial release - users explicitly enable compression when ready.
