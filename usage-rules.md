# PtcRunner Usage Rules

PtcRunner is a BEAM-native Elixir library for Programmatic Tool Calling (PTC). LLMs generate small programs (PTC-Lisp or JSON DSL) that orchestrate tools and transform data inside sandboxed BEAM processes.

## SubAgent — Primary Interface

### Creating and Running Agents

```elixir
# Single-shot (no tools, one LLM call)
{:ok, step} = SubAgent.run("What is 2 + 2?", llm: my_llm, max_turns: 1)

# Multi-turn with tools
agent = SubAgent.new(
  prompt: "Find products matching {{query}}",
  signature: "(query :string) -> [{id :int, name :string, price :float}]",
  tools: %{"search_products" => &MyApp.search/1}
)
{:ok, step} = SubAgent.run(agent, llm: my_llm, context: %{query: "laptop"})
step.return  #=> [%{"id" => 1, "name" => "Laptop Pro", "price" => 999.99}]
```

### Key Options for `SubAgent.new/1`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `prompt` | string | **required** | Template with `{{placeholder}}` expansion |
| `signature` | string | nil | Type contract: `"(inputs) -> output"` |
| `tools` | map | %{} | Named tool functions |
| `max_turns` | pos_integer | 5 | Max LLM calls |
| `retry_turns` | non_neg_integer | 0 | Extra turns for validation retry |
| `timeout` | pos_integer | 1000 | Per-turn sandbox timeout (ms) |
| `mission_timeout` | pos_integer \| nil | nil | Total wall-clock timeout (ms) |
| `turn_budget` | pos_integer | 20 | Total turns across all retries |
| `max_depth` | pos_integer | 10 | Nested agent depth limit |
| `output` | atom | :ptc_lisp | `:ptc_lisp` or `:json` |
| `memory_strategy` | atom | :strict | `:strict` or `:rollback` |
| `compression` | boolean | false | Enable turn history compression |
| `llm_query` | boolean | false | Enable builtin llm-query tool |
| `float_precision` | integer | 2 | Decimal places for floats |
| `description` | string | nil | For use as nested tool |
| `plan` | list | [] | Step descriptions for progress |

### Runtime Options for `SubAgent.run/2`

```elixir
SubAgent.run(agent,
  llm: my_llm,                    # REQUIRED - LLM callback function
  context: %{user: "alice"},       # Input data (or a previous Step)
  llm_registry: %{haiku: fn_},    # Atom LLM lookup for nested agents
  trace: true,                     # true | false | :on_error
  collect_messages: false           # Capture full LLM conversation
)
```

## Signatures — Type Contracts

Format: `(inputs) -> output` or just `output` for output-only.

### Primitive Types

`:string`, `:int`, `:float`, `:bool`, `:keyword`, `:any`, `:map`

### Collections and Maps

```elixir
[:int]                              # List of integers
[{id :int, name :string}]           # List of typed maps
{count :int, label :string?}        # Map with optional field (? suffix)
```

### Firewall Fields

Fields prefixed with `_` are hidden from LLM prompts but available in code:

```elixir
signature: "{summary :string, _raw_ids [:int]}"
# LLM sees only "summary"; _raw_ids is available in step.return
```

### Invalid Type Names (Common Mistake)

| Wrong | Correct |
|-------|---------|
| `:list` | `[:type]` |
| `:array` | `[:type]` |
| `:object` | `{field :type}` or `:map` |
| `:tuple` | `{field :type}` (named fields) |

## Tools — Callable Functions

### Definition Formats

```elixir
tools = %{
  # Bare function (auto-extracts @spec/@doc)
  "get_user" => &MyApp.get_user/1,

  # Function + explicit signature
  "search" => {&MyApp.search/2, "(query :string, limit :int) -> [{id :int}]"},

  # Function + options
  "analyze" => {&MyApp.analyze/1,
    signature: "(data :map) -> {score :float}",
    description: "Return anomaly score",
    cache: true},

  # Skip validation
  "dynamic" => {&MyApp.dynamic/1, :skip},

  # SubAgent as tool (nested agent)
  "classifier" => SubAgent.as_tool(classifier_agent),

  # LLM-powered tool
  "judge" => LLMTool.new(
    prompt: "Is {{text}} urgent?",
    signature: "(text :string) -> {urgent :bool}")
}
```

### Tool Function Contract

Tools always receive a map with **string keys**:

```elixir
# CORRECT - string keys
def my_tool(%{"query" => q, "limit" => l}), do: search(q, l)

# WRONG - atom keys won't match
def my_tool(%{query: q}), do: search(q)
```

Return `value`, `{:ok, value}`, or `{:error, reason}`.

PTC-Lisp hyphenated names are converted to underscores:
`{:user-name "Alice"}` arrives as `%{"user_name" => "Alice"}`.

## Step — Result Type

```elixir
case SubAgent.run(agent, opts) do
  {:ok, step} ->
    step.return          # Success value
    step.prints          # println output
    step.tool_calls      # Tool execution log
    step.usage           # %{duration_ms, turns, total_tokens, ...}

  {:error, step} ->
    step.fail.reason     # :timeout, :validation_error, :max_turns_exceeded, etc.
    step.fail.message    # Human-readable description
end
```

### Chaining Steps

```elixir
{:ok, step1} = SubAgent.run(finder, llm: llm, context: %{query: "urgent"})
{:ok, step2} = SubAgent.run(summarizer, llm: llm, context: step1)
```

## LLM Callback

```elixir
llm = fn %{system: system, messages: messages} ->
  # Must include system prompt in request
  # messages: [%{role: :user, content: "..."}, ...]

  # Simple form
  {:ok, response_text}

  # With token counts (recommended)
  {:ok, %{content: response_text, tokens: %{input: 100, output: 50}}}
end
```

## JSON Mode

For classification/extraction without tools or PTC-Lisp:

```elixir
{:ok, step} = SubAgent.run(
  "Extract name and age from: {{text}}",
  output: :json,
  signature: "(text :string) -> {name :string, age :int}",
  context: %{text: "John is 25"},
  llm: my_llm
)
```

### JSON Mode Constraints

- **Cannot use tools** — `output: :json` and `tools` are mutually exclusive
- **Requires signature** with all prompt parameters
- **No firewall fields** (no `_` prefix)
- **No compression**

## PTC-Lisp Key Patterns

### Data Access and Tool Calls

```clojure
;; Read context data
(data/products)

;; Call tools with named arguments (map, not positional)
(tool/search {:query "laptop" :limit 10})

;; WRONG - positional args not supported
(tool/search "laptop" 10)
```

### Multi-Turn Completion

In loop mode, always terminate with `return` or `fail`:

```clojure
(let [results (tool/search {:query "laptop"})]
  (return {:count (count results) :items results}))

;; WRONG - expression result doesn't terminate the loop
(tool/search {:query "laptop"})
```

Single-shot mode (`max_turns: 1`, no tools): expression result is the answer, no `return` needed.

### State Across Turns

```clojure
(def seen-ids #{})              ; Persists across turns
(defn score [item] (* (:price item) (:rating item)))
```

## Common Mistakes

1. **Atom keys in tools** — Use string keys: `%{"query" => q}` not `%{query: q}`
2. **Invalid type names** — Use `[:int]` not `:list`, `{f :type}` not `:object`
3. **Positional tool args** — Use `(tool/name {:key val})` not `(tool/name val)`
4. **Missing return in loops** — Multi-turn agents must call `(return ...)` or `(fail ...)`
5. **max_turns: 1 with tools** — Agent won't have enough turns to use tools; increase `max_turns`
6. **JSON mode with tools** — `output: :json` cannot have tools
7. **Forgetting system prompt** — LLM callback must include the `system` field in its request

## Debugging

```elixir
# Preview generated prompts without calling LLM
preview = SubAgent.preview_prompt(agent, context: %{query: "test"})
preview.system   # System prompt
preview.user     # First user message

# Print execution trace
SubAgent.Debug.print_trace(step)
SubAgent.Debug.print_trace(step, raw: true)       # Include LLM reasoning
SubAgent.Debug.print_trace(step, messages: true)   # Full conversation
```

## Sandbox Limits

Programs run in isolated BEAM processes:
- **Timeout**: 1s default (configurable via `timeout` option)
- **Memory**: ~10 MB heap (configurable via `max_heap` option)
- **Loop limit**: 1,000 iterations (hard cap: 10,000)

Override per-execution:

```elixir
SubAgent.new(prompt: "...", timeout: 5000, max_heap: 5_000_000)
```
