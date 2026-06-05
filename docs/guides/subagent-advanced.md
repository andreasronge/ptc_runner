# Advanced Topics

This guide covers advanced SubAgent features: multi-turn ReAct patterns, the compile pattern for batch processing, and system prompt internals.

## Multi-Turn Patterns (ReAct)

The SubAgent loop naturally supports **ReAct** (Reason + Act). Each turn's result merges into the context for the next turn.

### Implicit Context Chaining

```
Turn 1: LLM program -> execute -> result merged to data/
Turn 2: LLM sees data/results, generates next program
Turn 3: LLM calls return with final answer
```

### Example: Discovery and Reasoning

```elixir
{:ok, step} = SubAgent.run(
  "Find urgent emails from Acme",
  signature: "{summary :string, ids [:int]}",
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
(def results (tool/search-emails {:query "Acme Corp"}))
```

The LLM sees in its next prompt:
```
Program Result:
{:results [{id: 101, subject: "Urgent...", body: "..."}, ...]}
(8 more items omitted. Full data available in data/results)
```

**Turn 2: Filter and Return**
```clojure
;; Process all results from data/results
(let [urgent (filter (fn [e] (includes? (:subject e) "Urgent")) data/results)]
  (return {
    :summary (str "Found " (count urgent) " urgent emails")
    :ids (mapv :id urgent)
  }))
```

### Visibility Rules

| Data Type | Lisp Context | LLM Prompt |
|-----------|--------------|------------|
| Normal fields | Full value | Visible |
| Large lists | Full list | Sample (first N) |
| Large strings | Full string | Truncated |
| Memory | Full value | Hidden |

When data is truncated, the system appends:
> *"[98 more items omitted. Full data available in data/results]"*

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
(mapv (fn [r] {:id (:id r) :score (:score r)}) data/reports)

;; Turn 2: Find max and get details
(first (filter #(= (:id %) 123) data/reports))

;; Turn 3: Return with reasoning
(return {:report_id 123 :reasoning "..."})
```

> **Long-running agents:** Multi-turn agents that run beyond ~8 turns or accumulate large
> intermediate results can push toward the model's context window. See
> [Context Compaction](subagent-compaction.md) for opt-in pressure-triggered trimming.

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
| `max_print_length` | 2000 | Max chars per `println` call |
| `mission_log_in` | `:system_prompt` | Where to inject the mission log: `:system_prompt` or `:user_message` (use `:user_message` to keep the system prompt static for prompt caching) |

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

To enable prompt caching with providers that cache the system prompt, set `mission_log_in: :user_message` — this keeps the system prompt static across turns while the mission log updates in the first user message.

When data is truncated in turn feedback, the system appends:
> *"... (truncated)"*

When lists are truncated in prompts, the system appends:
> *"[98 more items omitted. Full data available in data/results]"*

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

### 2. Apply Phase

Execute at scale with zero LLM cost:

```elixir
results = Enum.map(all_reports, fn r ->
  compiled.execute.(%{report: r}, [])
end)
```

## Prompt Structure

Understanding what the LLM receives helps debug unexpected behavior.

### Message Layout

| Message | Content | Caching |
|---------|---------|---------|
| **SYSTEM** | Role, language reference, `return`/`fail` usage, output format | Static (cacheable) |
| **USER** | Mission + namespaces + execution history + turns left | Partial (tool/data stable) |

**Note:** Tools and data are placed in the USER message (not SYSTEM) so prompt caching can hit the stable content while the volatile mission/history changes.

### Namespace Model

The USER message presents three namespaces:

```clojure
;; === tool/ ===
(tool/search query)              ; query:string -> [:map]

;; === data/ ===
data/products                    ; list[7], sample: {:name "Laptop"}

;; === user/ (your prelude) ===
cached-results                   ; = list[5], sample: {:id 1}
```

| Namespace | Meaning | Mutable? |
|-----------|---------|----------|
| `tool/` | Available tools (side effects) | No (external) |
| `data/` | Input context (read-only) | No (external) |
| `user/` | Your definitions (prelude) | Yes (grows each turn) |

### Viewing the Prompt

```elixir
# Preview without executing
preview = SubAgent.preview_prompt(agent, context: %{})
IO.puts(preview.system)
IO.puts(preview.user)

# After execution, see what the LLM actually received per turn
SubAgent.Debug.print_trace(step, messages: true)
```

### Strict Termination

If the LLM provides text without a code block or terminal form:

1. Loop records the reasoning
2. Appends: *"Your mission is still active. Provide a PTC-Lisp program or call 'return'."*
3. LLM must provide a functional result

## Capability Prelude

A **capability prelude** lets a deployment expose curated, Lisp-facing APIs to
agents without hard-coding each one into the library or stuffing full source
into the prompt. The prelude defines protected namespaces (for example `crm`)
with public exports the agent can call and discover normally, while private
helpers stay hidden. It is stateless: it defines functions, constants,
docstrings, and metadata, but holds no hidden mutable state.

Compile the prelude source once, then attach the artifact to the agent via
`runtime_prelude:`:

```elixir
prelude_source = """
(ns crm
  "CRM helpers."
  {:visibility :prompt})

(defn get-user
  "Return a CRM user by id."
  [id]
  (tool/call {:server "crm" :tool "get_user" :args {:id id}}))
"""

{:ok, prelude} = PtcRunner.Lisp.Prelude.Compiler.compile(prelude_source)

agent =
  PtcRunner.SubAgent.new(
    prompt: "Look up the requested user",
    runtime_prelude: prelude,
    llm: llm
  )
```

The agent's program can then call `(crm/get-user data/user-id)` and discover the
export through `(ns-publics 'crm)`, `(doc 'crm/get-user)`, and
`(meta 'crm/get-user)`. Prompt-visible exports (`:visibility :prompt`) are
summarized in a compact, deployment-defined prompt inventory that is assembled
dynamically — the core prompt templates stay domain-blind. Exports marked
`:visibility :discoverable` are omitted from the inventory but remain reachable
through the discovery forms.

Prelude exports wrap the existing tool surfaces and are recoverable-by-default,
so the agent can branch on the same `:ok` / `:reason` / `:value` result map a
direct `(tool/call ...)` returns. Protected namespaces cannot be redefined by
agent code, and private helpers are never resolvable or discoverable by
qualified symbol. For the language-level rules, see
[Capability Prelude](../ptc-lisp-specification.md#99-capability-prelude) in the
specification.

> **Traceability.** When a prelude is attached, `step.prelude_trace` carries a
> credential-free summary — source hash, compiled-artifact hash, selected
> protected namespaces, and public export records including arglist params — so
> a run's capability environment can be reproduced from traces. Secrets and
> credentials live in host/deployment config and never appear in the prelude
> artifact, prompts, or traces.

The same compiled artifact also drives the REPL
(`mix ptc.repl --prelude crm.clj`) and direct execution
(`PtcRunner.Lisp.run(program, prelude: prelude)`), so behavior is identical
across surfaces.

For a full walkthrough — authoring a prelude file, visibility and `requires`,
attaching across surfaces, discovery, and troubleshooting — see the
[Capability Preludes authoring & deploying guide](capability-prelude.md).

## PTC-Lisp Quick Reference

### Core

```clojure
(tool/tool-name {:arg value})  ; Call tool
data/key                       ; Access context
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

- [Core Concepts](subagent-concepts.md) - Context and memory
- [Context Compaction](subagent-compaction.md) - Pressure-triggered trimming for long-running multi-turn agents
- [Observability](subagent-observability.md) - Telemetry, debug mode, and tracing
- [Prompt Customization](subagent-prompts.md) - LLM-specific prompts and language specs
- [Patterns](subagent-patterns.md) - Chaining, orchestration, and composition
- [Signature Syntax](../signature-syntax.md) - Type system details
- `PtcRunner.SubAgent.run/2` - Full API reference
- [PTC-Lisp Specification](../ptc-lisp-specification.md) - Language reference
