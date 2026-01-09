# Advanced Topics

This guide covers advanced SubAgent features: multi-turn ReAct patterns, the compile pattern for batch processing, and system prompt internals.

## Multi-Turn Patterns (ReAct)

The SubAgent loop naturally supports **ReAct** (Reason + Act). Each turn's result merges into the context for the next turn.

### Implicit Context Chaining

```
Turn 1: LLM program -> execute -> result merged to ctx/
Turn 2: LLM sees ctx/results, generates next program
Turn 3: LLM calls return with final answer
```

### Example: Discovery and Reasoning

```elixir
{:ok, step} = SubAgent.run(
  "Find urgent emails from Acme",
  signature: "{summary :string, _ids [:int]}",
  tools: %{
    "search_emails" => &MyApp.Email.search/1,
    "count_results" => &MyApp.Email.count/1
  },
  max_turns: 5,
  llm: llm
)
```

**Turn 1: Discovery**
```clojure
;; Store results in user namespace
(def results (ctx/search-emails {:query "Acme Corp"}))
```

The LLM sees in its next prompt:
```
Program Result:
{:results [{id: 101, subject: "Urgent...", _body: <Firewalled>}, ...]}
(8 more items omitted. Full data available in ctx/results)
```

**Turn 2: Filter and Return**
```clojure
;; Process all results from ctx/results
(let [urgent (filter (fn [e] (includes? (:subject e) "Urgent")) ctx/results)]
  (return {
    :summary (str "Found " (count urgent) " urgent emails")
    :_ids (mapv :id urgent)
  }))
```

### Visibility Rules

| Data Type | Lisp Context | LLM Prompt |
|-----------|--------------|------------|
| Normal fields | Full value | Visible |
| Firewalled (`_`) | Full value | `<Firewalled>` |
| Large lists | Full list | Sample (first N) |
| Large strings | Full string | Truncated |
| Memory | Full value | Hidden |

When data is truncated, the system appends:
> *"[98 more items omitted. Full data available in ctx/results]"*

### Investigation Agents (Zero Tools)

Sometimes you have all data in context but it's too large for one pass:

```elixir
data = %{
  reports: [...]  # thousands of items
}

# max_turns > 1 with tools enables agentic loop
{:ok, step} = SubAgent.run(
  "Find the report with highest anomaly score",
  signature: "{report_id :int, reasoning :string}",
  context: data,
  max_turns: 5,
  llm: llm
)
```

The LLM can "walk" the data across turns:

```clojure
;; Turn 1: Extract summaries
(mapv (fn [r] {:id (:id r) :score (:score r)}) ctx/reports)

;; Turn 2: Find max and get details
(first (filter #(= (:id %) 123) ctx/reports))

;; Turn 3: Return with reasoning
(return {:report_id 123 :reasoning "..."})
```

## Debugging

### Prompt Preview

Inspect expanded prompts without executing:

```elixir
preview = SubAgent.preview_prompt(agent,
  context: %{user: "alice", sender: "bob@example.com"}
)

IO.puts(preview.system)  # Full system prompt
IO.puts(preview.user)    # Expanded user prompt
```

> **Telemetry, debug mode, and trace inspection:** See [Observability](subagent-observability.md).

### Output Truncation

Large results are automatically truncated at different stages to manage context size and memory:

| Option | Default | Used For |
|--------|---------|----------|
| `feedback_limit` | 10 | Max collection items shown to LLM in turn feedback |
| `feedback_max_chars` | 512 | Max chars in turn feedback message |
| `history_max_bytes` | 512 | Truncation limit for `*1/*2/*3` history access |
| `result_limit` | 50 | Inspect `:limit` for final result formatting |
| `result_max_chars` | 500 | Max chars in final result string |

Configure via `format_options`:

```elixir
SubAgent.new(
  prompt: "Analyze large dataset",
  format_options: [
    feedback_limit: 20,       # Show more items to LLM
    feedback_max_chars: 1024  # Allow longer feedback
  ]
)
```

When data is truncated in turn feedback, the system appends:
> *"... (truncated)"*

When lists are truncated in prompts, the system appends:
> *"[98 more items omitted. Full data available in ctx/results]"*

## Compile Pattern

For repetitive batch processing, separate the cognitive step (writing logic) from execution (running at scale).

### What Can Be Compiled

| Tool Type | Compilable? | Why |
|-----------|-------------|-----|
| Pure Elixir functions | Yes | Deterministic |
| LLMTool | No | Needs LLM |
| SubAgent as tool | No | Needs LLM |

### 1. Derive Phase

LLM analyzes sample data and generates pure PTC-Lisp:

```elixir
scorer = SubAgent.new(
  prompt: "Extract anomaly score and reasoning from report",
  signature: "(report :map) -> {score :float, reason :string}",
  tools: %{"lookup_threshold" => &MyApp.lookup_threshold/1}
)

{:ok, compiled} = SubAgent.compile(scorer,
  llm: llm,
  sample: sample_reports
)

IO.puts(compiled.source)
#=> (fn [report] (let [...] {...}))
```

### 2. Validate (Optional)

Test against known cases:

```elixir
case SubAgent.validate_compiled(compiled, test_reports) do
  :ok -> IO.puts("Verified!")
  {:error, failures} -> Logger.warning("Failed: #{length(failures)}")
end
```

### 3. Apply Phase

Execute at scale with zero LLM cost:

```elixir
results = Enum.map(all_reports, fn r ->
  compiled.execute(%{report: r})
end)
```

### Persistence

Save derived logic for later:

```elixir
File.write!("agents/scorer.lisp", compiled.source)

# Load later
{:ok, compiled} = SubAgent.load(
  File.read!("agents/scorer.lisp"),
  signature: "(report :map) -> {score :float, reason :string}"
)
```

## System Prompt Structure

Understanding what the LLM receives helps debug unexpected behavior.

### Prompt Sections

1. **Role & Purpose** - Defines the agent as a PTC-Lisp generator

2. **Data Inventory** - Generated from `context_signature`:
   ```
   DATA INVENTORY (Available in ctx/):
   - results ([:map]): List of research results
   - _token ([:string]): Firewalled access tokens
   ```

3. **Tools** - Generated from the `tools` map (signatures + descriptions):
   ```
   AVAILABLE TOOLS:
   - search(query :string) -> [:map]
     Search for items matching query.
   - return(data :any) -> stops loop
   - fail(params {...}) -> stops loop
   ```

4. **Language Reference** - PTC-Lisp syntax, built-ins, control flow

5. **Output Format** - Instructions for thought + code block format

6. **Boundary Reminders** - Prevents conversational filler

### Strict Termination

If the LLM provides text without a code block or terminal tool call:

1. Loop records the reasoning
2. Appends: *"Your mission is still active. Provide a PTC-Lisp program or call 'return'."*
3. LLM must provide a functional result

## PTC-Lisp Quick Reference

### Core

```clojure
(ctx/tool {:arg value})        ; Call tool
ctx/key                        ; Access context
(def key value)                ; Store value
key                            ; Access stored value
(defn name [args] body)        ; Define function
```

### Control Flow

```clojure
(do expr1 expr2)               ; Sequential, returns last
(let [x 1 y 2] (+ x y))        ; Local bindings
(if cond then else)            ; Conditional
(when cond expr)               ; Conditional without else
(cond c1 e1 c2 e2 :else e3)    ; Multi-branch
(fn [x] (* x 2))               ; Anonymous function
```

### Collections

```clojure
(map f coll)                   ; Transform
(mapv f coll)                  ; Transform to vector
(filter pred coll)             ; Keep matching
(reduce f init coll)           ; Fold
(first coll) (last coll)       ; Access
(count coll) (empty? coll)     ; Info
(sort-by :key coll)            ; Sort
(group-by :key coll)           ; Group
```

### Maps

```clojure
(get m :key)                   ; Access
(get-in m [:a :b])             ; Nested access
(assoc m :key val)             ; Add/update
(merge m1 m2)                  ; Combine
(keys m) (vals m)              ; Extract
```

### Keywords as Functions

```clojure
(:id item)                     ; Same as (get item :id)
(mapv :id items)               ; Extract :id from each
```

### Type Conversion

```clojure
(parse-long "42")              ; String to int (nil on failure)
(parse-double "3.14")          ; String to float
```

## Glossary

| Term | Definition |
|------|------------|
| **Signature** | Contract defining inputs and outputs |
| **Step** | Result struct with `return`, `fail`, `memory`, `trace` |
| **Firewall** | `_` prefix hiding data from LLM prompts |
| **Data Inventory** | Type info section in system prompt |
| **Turn** | One LLM generation + execution cycle |
| **Mission** | Complete SubAgent execution until `return`/`fail` |

## See Also

- [Core Concepts](subagent-concepts.md) - Context, memory, and the firewall
- [Observability](subagent-observability.md) - Telemetry, debug mode, and tracing
- [Prompt Customization](subagent-prompts.md) - LLM-specific prompts and language specs
- [Patterns](subagent-patterns.md) - Chaining, orchestration, and composition
- [Signature Syntax](../signature-syntax.md) - Type system details
- `PtcRunner.SubAgent` - Full API reference
- [PTC-Lisp Specification](../ptc-lisp-specification.md) - Language reference
