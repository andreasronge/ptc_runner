# Message History Optimization Specification

## Prerequisites

- [#603 - Messages should be stored in Step](https://github.com/andreasronge/ptc_runner/issues/603) must be completed first. Message history optimization depends on having messages stored in Step.

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

## API

```elixir
compress_history: true                                  # enable with defaults
compress_history: [println_limit: 10, tool_call_limit: 15]  # custom limits
compress_history: false                                 # disabled (default)
```

| Option | Default | Description |
|--------|---------|-------------|
| `println_limit` | 15 | Most recent println calls shown |
| `tool_call_limit` | 20 | Most recent tool calls shown |

Internally normalized to `%HistoryOpts{}` struct. Options inherited like other SubAgent options.

Note: `max_turns` defaults to 5. "Turns left" = `max_turns - current_turn`.

## Namespace Design

Clear namespace separation helps the LLM distinguish between different types of symbols:

| Namespace | Meaning | Example |
|-----------|---------|---------|
| `tool/` | Provided tools (side effects) | `(tool/fetch-users "admin")` |
| `data/` | Provided input data (read-only) | `(filter ... data/products)` |
| (bare) | User definitions | `(my-helper x)` |

**Auto-fallback**: If the LLM writes `fetch-users` without namespace and no local definition exists, it resolves to `tool/fetch-users` (same for `data/`). Local definitions always take precedence over fallback. If both `tool/foo` and `data/foo` exist, bare `foo` raises a runtime exception (ambiguous reference).

This design:
- Makes tool calls explicit: `tool/` = external action with side effects
- Protects input data: `data/` = given context, shouldn't be redefined
- Keeps user code clean: bare names for functions/data the LLM defined

## Design Principle

**Compress the code, preserve the learnings.**

The LLM wrote code to learn something. Once executed, the code itself is disposable - only the results matter. Summaries capture what the LLM learned, not how it learned it.

## What the LLM Sees

### Compressed Turn Format

Old successful assistant turns are replaced with a summary showing:

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

**Tool call format**: Tool calls show the tool name and arguments in Clojure syntax. Arguments are truncated using existing `printable_limit` (reuses `Format.to_clojure/2`). Tool results are NOT shown in the tool call list - they appear as defined values if stored via `def`.

### Format Templates

These are the exact format strings used for each summary line:

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

**Section ordering**: Sections appear in this order when present. Empty sections are omitted entirely:
1. Tool calls (or "No tool calls made")
2. Functions
3. Defined
4. Output

### Type Vocabulary

Values are labeled with these type names:

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

### Truncation (Reusing Format.to_clojure/2)

All value truncation uses the existing `Format.to_clojure/2` function with these defaults:

```elixir
# For samples in Defined lines
Format.to_clojure(value, limit: 3, printable_limit: 80)

# For tool call arguments
Format.to_clojure(args, limit: 3, printable_limit: 60)
```

The function returns `{formatted_string, truncated?}`. When truncated, collections show `... (N items, showing first M)` and strings show `...` suffix.

**println output truncation**: Each `(println ...)` call counts as one call regardless of how many arguments it has. The limit applies to the number of calls, not lines. Output lines are preserved as-is (not truncated individually).

**println tracking**: The interpreter captures each `(println ...)` call during evaluation and stores it in the Step (or sub-module). This allows distinguishing between "turn has println" vs "turn has no println" for the samples-vs-output decision.

### Summary Components

| Component | Purpose | Format |
|-----------|---------|--------|
| **Tool calls** | Actions taken (side effects) | `name(args)` with truncated args |
| **Functions** | Available to call | `name - "docstring"` |
| **Data** | Available to reference | `name - "docstring" = type, sample: value` |
| **Output** | What LLM explicitly printed | `println` output only |
| **Status** | Success or failure | Implicit (errors keep full code) |

**Tool calls are critical for side-effect tracking.** Many tools perform actions (send emails, make API calls, update databases) and return nil or minimal data. Without tool call history, the LLM loses track of what actions it already took.

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

**Redefinition within same turn**: If a symbol is defined multiple times in one turn, only the final value appears in the summary:
```clojure
(def x 1)
(def x 2)  ; redefinition
```
```
; Defined: x = 2
```

Both `defn` and `def` support docstrings:
```clojure
(defn fetch-users "Fetches users by category" [category] ...)
(def users "Active users from API" (fetch-users "admin"))
```

We capture docstrings at execution time. Prompts should encourage descriptive docstrings. Docstrings with semicolons are sanitized (`;` removed) to avoid breaking summary format. Sample truncation uses `Format.to_clojure/2` with `:limit` and `:printable_limit` options.

### Data Samples Are Critical

For defined data values, include enough structure for the LLM to understand what it's working with:

```
; Defined: products = list[7], sample: {:name "Laptop", :price 1200, :category "Electronics"}
```

This tells the LLM:
- `products` exists and is a list of 7 items
- Each item has `:name`, `:price`, `:category` keys
- It can write code like `(filter (fn [p] (> (:price p) 100)) products)`

Without the sample, the LLM doesn't know the data structure.

**Sample format**: Use Clojure-style syntax (`{:key value}`) in samples to match PTC-Lisp syntax the LLM writes. For complex nested structures, use simplified type signatures.

**Edge cases**:
- `(def x nil)` → `; Defined: x = nil`
- `(def x [])` → `; Defined: x = list[0]`
- Redefinition across turns: latest wins (turn 2 redefining turn 1's symbol overwrites it)

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

### Side-Effect Tools (Returning nil)

Some tools perform actions but return nil or minimal data:

```clojure
(tool/make-call {:to "Alice" :message "Meeting at 3pm"})
(tool/make-call {:to "Bob" :message "Bring documents"})
(tool/send-email {:to "team@example.com" :subject "Update"})
```

Without tool call tracking, the summary would show nothing - the LLM wouldn't know what calls were made in previous turns.

**With tool call history:**
```
; Tool calls:
;   make-call({:to "Alice" :message "Meeting at 3pm"})
;   make-call({:to "Bob" :message "Bring documents"})
;   send-email({:to "team@example.com" :subject "Update"})
```

This is essential for:
- **Avoiding duplicate actions**: LLM knows it already called Alice
- **Tracking progress**: LLM knows 2 of 5 calls completed
- **Error recovery**: If turn 3 fails, LLM sees what succeeded in turns 1-2

Tool calls are accumulated across all turns (like definitions), limited by `tool_call_limit`. The data comes from `Step.tool_calls` which already tracks name, args, result, and timing.

## Message Array Transformation

### Key Insight: Single USER Message

All previous successful turns are accumulated into a **single USER message** between SYSTEM and ASSISTANT. The message array becomes:

```
[SYSTEM, USER(mission + accumulated context + turns left), ASSISTANT(current code)]
```

**Mission format**: The original mission text appears first, followed by a blank line, then the accumulated context. No separator or header is needed:

```
Find well-reviewed products in stock

; Tool calls:
;   search-reviews("Electronics")
; Defined: ...

Turns left: 4
```

This avoids confusing the LLM. If summaries appeared in ASSISTANT messages, the LLM might try to output `; Defined: ...` instead of code. By keeping summaries in the USER message:
- **USER** = "Here's your mission + what you've learned + turns remaining"
- **ASSISTANT** = "Here's my PTC-Lisp code"

The LLM never sees a previous ASSISTANT message with summary format, so there's no template to mimic.

### Before (Full History)

```
[SYSTEM] System prompt...

[USER] Find well-reviewed products in stock

[ASSISTANT]
```lisp
(def electronics (filter (fn [p] (= (:category p) "Electronics")) data/products))
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

; Tool calls:
;   search-reviews("Electronics")
;   get-inventory()
; Defined: electronics = list[4], sample: {:name "Laptop", :price 1200, ...}
; Defined: reviews = string
; Defined: inventory = string
; Output:
Reviews: Customer Review Summary for Electronics:
- Laptop: Average rating 4.5/5. - Mouse: Average rating 3.2/5...
Inventory: Warehouse Inventory Report:
Laptop - 23 units in stock. Mouse - OUT OF STOCK...

Turns left: 4

[ASSISTANT]
```lisp
(def well-reviewed ["Laptop" "Monitor" "Keyboard"])
(return (filter (fn [p] (some (fn [name] (= (:name p) name)) well-reviewed)) electronics))
```
```

The LLM sees:
- What tool calls were made (with args)
- What it defined (with type, and samples when no println)
- What it explicitly printed (full output)
- Turns remaining

It does NOT see:
- Previous code
- Repeated definitions
- Previous ASSISTANT messages (avoids format confusion)

## Compression Rules

### What Gets Compressed

With the single USER message approach, compression works differently:

| Content | Handling |
|---------|----------|
| Mission (original task) | Always at the top of USER message |
| Successful turn results | Compressed to summary, appended to USER message |
| Failed turn code | Kept full, appended as-is (LLM needs to see broken code) |
| Tool calls | Accumulated in summary, limited to most recent N |
| println output | Included in summary, limited to most recent N calls |
| SYSTEM prompt | Unchanged |

**CRITICAL: The mission is NEVER removed.** It stays at the top of the USER message. See [#603](https://github.com/andreasronge/ptc_runner/issues/603).

### Compression Timing

Compress at the **start of each new turn**, not at storage time:

```
Turn 1 completes → results stored in trace
Turn 2 starts    → build USER message: mission + Turn 1 summary + "Turns left: N"
Turn 2 completes → results stored in trace
Turn 3 starts    → build USER message: mission + Turn 1-2 summaries + "Turns left: N"
```

The LLM always sees: `[SYSTEM, USER(accumulated), ASSISTANT(current)]`

## Scenarios

### Successful Multi-Turn (Turn 3)

```
[SYSTEM]
[USER] mission
       ; Tool calls:
       ;   (accumulated from turns 1-2)
       ; Function: ...
       ; Defined: ... (accumulated from turns 1-2)
       ; Output: ... (from turns 1-2, limited)
       Turns left: 3
[ASSISTANT] (current code)
```

Only the current ASSISTANT message has code. Previous turns are summaries in USER.

### Error Recovery (Failed Turns)

**Failed turns are NOT compressed.** When a turn fails, the full assistant/user message pair is preserved in the message array (same as today's behavior). Only successful turns get compressed.

Example with Turn 2 failed:
```
[SYSTEM]
[USER] mission

; Tool calls:
;   fetch-data("users")
; Defined: users = list[5], ...

Turns left: 4

[ASSISTANT]
```lisp
(def x (broken-code))
```

[USER]
Error: undefined symbol 'broken-code'

Turns left: 3

[ASSISTANT] (current code, attempting fix)
```

Multiple failed turns each keep their full assistant/user message pairs:
```
[SYSTEM]
[USER] mission + Turn 1 summary + Turns left: 4
[ASSISTANT] Turn 2 code (failed)
[USER] Turn 2 error + Turns left: 3
[ASSISTANT] Turn 3 code (also failed)
[USER] Turn 3 error + Turns left: 2
[ASSISTANT] (current code, attempting fix)
```

This ensures the LLM sees exactly what it tried and why it failed, preventing it from repeating the same mistakes.

### Single-Shot (max_turns: 1)

No compression needed - only one turn. Note: `max_turns` defaults to 5 if not specified.

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

**Error handling**: All failed turns keep their full code in the USER message. This prevents the LLM from cycling through the same mistakes - it sees exactly what it tried and why it failed.

**Accumulated definitions**: Show all definitions from all previous turns (accumulated), except when a symbol has been redefined - only show the latest definition. Definitions persist in memory, so the summary reflects what's actually available. Order of appearance follows order of definition.

**println history limit**: Truncate older println output to avoid unbounded growth. Configurable with default (15 most recent println calls shown, counted per `(println ...)` call, not per line). Older outputs are dropped from summaries but preserved in trace for debugging.

**Tool call history limit**: Truncate older tool calls to avoid unbounded growth. Configurable with default (20 most recent tool calls shown). Shows tool name and truncated args using `Format.to_clojure/2` with `printable_limit`. Tool results are NOT shown in the tool call list - if stored via `def`, they appear in the Defined section. This is essential for side-effect tools that return nil.

**Single USER message**: All previous turn context accumulates into one USER message. This prevents format confusion - the LLM never sees ASSISTANT messages with summary format, so it won't try to mimic that format instead of writing code.

**Namespace separation**: Use `tool/` for provided tools, `data/` for provided input, bare names for user definitions. Auto-fallback resolves bare names to namespaced versions when no local definition exists.

**Default value**: `compress_history` defaults to `false` (opt-in). Safer for initial release - users explicitly enable compression when ready.
