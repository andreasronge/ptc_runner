# Text Mode SubAgents

Text mode (`output: :text`) lets the LLM respond directly without generating PTC-Lisp code. It covers four variants, auto-detected based on whether tools are provided and the return type:

| Variant | Tools | Signature / Return Type | Behavior |
|---------|-------|------------------------|----------|
| Plain text | No | None or `:string` | Raw text response |
| JSON | No | Complex type (map, list, float, int) | Structured JSON response |
| Tool + text | Yes | None or `:string` | Tool loop, then text answer |
| Tool + JSON | Yes | Complex type (map, list, float, int) | Tool loop, then JSON answer |

## When to Use Text Mode

| Task Type | Mode | Why |
|-----------|------|-----|
| Free-form question answering | Text (plain text) | No structure needed |
| Classification | Text (JSON) | Direct structured response |
| Entity extraction | Text (JSON) | No computation needed |
| Summarization with structure | Text (JSON) | Simple output mapping |
| Tools with small/fast LLMs | Text (tool + JSON) | Native tool calling, no PTC-Lisp needed |
| Tools with free-form answer | Text (tool + text) | Tool use without structured output |
| Multi-step reasoning | PTC-Lisp | Needs tool calls + computation |
| Data transformation | PTC-Lisp | Needs computation |
| External API calls | PTC-Lisp | Needs tools + orchestration |

**Choose text mode over PTC-Lisp when:**
- Using smaller models (Haiku, GPT-4.1 Mini, Gemma, Llama) that struggle with PTC-Lisp syntax
- You want the LLM provider to handle tool schema formatting
- You don't need memory persistence between turns
- You need a plain text or simple structured response

## Basic Usage

### Plain Text (No Signature)

```elixir
{:ok, step} = SubAgent.run(
  "Summarize this article: {{text}}",
  context: %{text: "Long article..."},
  output: :text,
  llm: my_llm
)

step.return  #=> "The article discusses..."  (raw string)
```

### JSON (Complex Return Type)

```elixir
{:ok, step} = SubAgent.run(
  "Classify the sentiment of: {{text}}",
  context: %{text: "I love this product!"},
  output: :text,
  signature: "(text :string) -> {sentiment :string, score :float}",
  llm: my_llm
)

step.return  #=> %{"sentiment" => "positive", "score" => 0.95}
```

### Tool + Text (Tools with String Return)

```elixir
{:ok, step} = SubAgent.run(
  "Use the search tool to find info about Elixir, then summarize.",
  output: :text,
  tools: %{
    "search" => {&MyApp.search/1,
                 signature: "(query :string) -> [{title :string, snippet :string}]",
                 description: "Search the web"}
  },
  llm: my_llm
)

step.return  #=> "Elixir is a dynamic, functional language..."  (raw string)
```

### Tool + JSON (Tools with Complex Return Type)

```elixir
{:ok, step} = SubAgent.run(
  "What is 17 + 25? Use the add tool.",
  output: :text,
  signature: "() -> {result :int}",
  tools: %{
    "add" => {fn args -> args["a"] + args["b"] end,
              signature: "(a :int, b :int) -> :int",
              description: "Add two numbers"}
  },
  llm: my_llm
)

step.return["result"]  #=> 42
```

**Constraints:** Signature is optional. Tools are optional. When no signature or a `:string` return type is used, text mode returns a raw string. When a complex return type (map, list, float, int) is used, text mode returns JSON. Compression and firewall fields are not supported.

## How It Works

### Without Tools

1. The prompt and context are sent to the LLM
2. The LLM responds with text
3. If a complex return type is specified, the response is parsed as JSON and validated against the signature
4. If no signature or `:string` return type, the raw text is returned

### With Tools

The execution flow uses the LLM provider's native tool calling API:

1. Tool signatures are converted to JSON Schema and sent to the LLM provider
2. The LLM uses its native tool calling API to request tool executions
3. ptc_runner executes the tools and feeds results back
4. The loop continues until the LLM returns a final answer
5. If a complex return type is specified, the answer is validated against the signature

```
LLM ──tool_call──> ptc_runner executes tool ──result──> LLM
LLM ──tool_call──> ptc_runner executes tool ──result──> LLM
LLM ──final answer──> validate (if complex type) ──> Step
```

## Mustache Templates

Text mode embeds data directly in the prompt using Mustache syntax. When a signature with input parameters is provided, all parameters must appear in the prompt.

### Simple Variables

Reference context values with `{{variable}}`:

```elixir
SubAgent.new(
  prompt: "Analyze the sentiment of: {{text}}",
  output: :text,
  signature: "(text :string) -> {sentiment :string}"
)
```

Nested access uses dot notation: `{{user.name}}`, `{{order.items.count}}`.

### Sections for Lists

Iterate over lists with `{{#section}}...{{/section}}`:

```elixir
SubAgent.new(
  prompt: """
  Categorize these products:
  {{#products}}
  - {{name}}: ${{price}}
  {{/products}}
  """,
  output: :text,
  signature: "(products [{name :string, price :float}]) -> {categories [{name :string, category :string}]}"
)
```

With context `%{products: [%{name: "Widget", price: 9.99}, %{name: "Gadget", price: 19.99}]}`, the prompt expands to:

```
Categorize these products:
- Widget: $9.99
- Gadget: $19.99
```

### Scalar Lists with Dot Notation

For lists of primitives, use `{{.}}` to reference the current element:

```elixir
SubAgent.new(
  prompt: "Classify these tags: {{#tags}}{{.}}, {{/tags}}",
  output: :text,
  signature: "(tags [:string]) -> {primary_tag :string}"
)
```

### Inverted Sections

Use `{{^section}}` to render content when a value is falsy or empty:

```elixir
SubAgent.new(
  prompt: """
  {{#items}}Process items...{{/items}}
  {{^items}}No items to process.{{/items}}
  """,
  output: :text,
  signature: "(items [:string]) -> {status :string}"
)
```

## Validation Rules

When a signature with input parameters is provided, text mode enforces strict validation at agent construction time.

### All Parameters Must Be Used

Every signature parameter must appear in the prompt (as a variable or section):

```elixir
# Valid - both params used
SubAgent.new(
  prompt: "Analyze {{text}} for {{user}}",
  output: :text,
  signature: "(text :string, user :string) -> {result :string}"
)

# Invalid - 'user' not used
SubAgent.new(
  prompt: "Analyze {{text}}",
  output: :text,
  signature: "(text :string, user :string) -> {result :string}"
)
# => ArgumentError: Text mode requires all signature params in prompt. Unused: ["user"]
```

### Section Fields Must Match Signature

Fields inside sections are validated against the element type:

```elixir
# Valid - 'name' exists in element type
SubAgent.new(
  prompt: "{{#items}}{{name}}{{/items}}",
  output: :text,
  signature: "(items [{name :string, price :float}]) -> {count :int}"
)

# Invalid - 'unknown' not in element type
SubAgent.new(
  prompt: "{{#items}}{{unknown}}{{/items}}",
  output: :text,
  signature: "(items [{name :string}]) -> {count :int}"
)
# => ArgumentError: {{unknown}} inside {{#items}} not found in element type
```

### Dot Notation Requires Scalar Lists

Use `{{.}}` only for lists of primitives, not lists of maps:

```elixir
# Valid - tags is [:string]
SubAgent.new(
  prompt: "{{#tags}}{{.}}{{/tags}}",
  output: :text,
  signature: "(tags [:string]) -> {count :int}"
)

# Invalid - items is [{name :string}], use {{name}} instead
SubAgent.new(
  prompt: "{{#items}}{{.}}{{/items}}",
  output: :text,
  signature: "(items [{name :string}]) -> {count :int}"
)
# => ArgumentError: {{.}} inside {{#items}} - use {{field}} instead (list contains maps)
```

## Multiple Tools

Provide multiple tools and the LLM decides which to call:

```elixir
tools = %{
  "multiply" => {fn args -> args["a"] * args["b"] end,
                 signature: "(a :int, b :int) -> :int",
                 description: "Multiply two numbers"},
  "subtract" => {fn args -> args["a"] - args["b"] end,
                 signature: "(a :int, b :int) -> :int",
                 description: "Subtract b from a"}
}

{:ok, step} = SubAgent.run(
  "Calculate (6 * 7) - 10",
  output: :text,
  signature: "() -> {result :int}",
  tools: tools,
  max_turns: 5,
  llm: my_llm
)

step.return["result"]  #=> 32
```

The LLM may call multiple tools per turn or across multiple turns.

## Tool Signatures

Tool signatures define the JSON Schema sent to the LLM provider. Use the same signature syntax as PTC-Lisp tools:

```elixir
# Full tool definition with signature and description
"search" => {fn args -> do_search(args["query"]) end,
             signature: "(query :string, limit :int?) -> [{id :int, title :string}]",
             description: "Search the database"}

# Bare function (no schema sent to LLM — not recommended)
"ping" => fn _args -> "pong" end
```

Optional parameters (`:int?`) are excluded from the `required` list in the generated JSON Schema.

## Limits and Error Handling

### max_turns

Controls total LLM round-trips. Each tool call response and each final answer attempt counts as a turn:

```elixir
SubAgent.new(
  prompt: "Find and analyze data",
  output: :text,
  signature: "() -> {analysis :string}",
  tools: tools,
  max_turns: 10  # Allow up to 10 LLM calls
)
```

If exhausted, returns `{:error, step}` with `step.fail.reason == :max_turns_exceeded`.

### max_tool_calls

Limits total tool executions across all turns:

```elixir
SubAgent.new(
  prompt: "Search for info",
  output: :text,
  signature: "() -> {answer :string}",
  tools: tools,
  max_tool_calls: 5  # No more than 5 total tool calls
)
```

When the limit is reached, remaining tool calls in the current turn receive an error message, and the LLM is informed.

### Tool Errors

Tool failures don't crash the agent. If a tool raises an exception or isn't found, the error is fed back to the LLM as a tool result, giving it a chance to recover:

```elixir
# Tool that may fail
"risky" => {fn _args -> raise "service unavailable" end,
            signature: "() -> :string",
            description: "Call external service"}
```

The LLM receives `{"error": "service unavailable"}` as the tool result and can adapt its approach.

## Text Mode vs PTC-Lisp Mode

| Aspect | Text Mode (no tools) | Text Mode (with tools) | PTC-Lisp Mode |
|--------|---------------------|----------------------|---------------|
| Data in prompt | Embedded via Mustache | Embedded via Mustache | Shown in Data Inventory |
| Template syntax | Full Mustache (sections) | Full Mustache (sections) | Simple `{{var}}` only |
| LLM output | Text or JSON | Tool calls + text/JSON | PTC-Lisp code |
| Tools | Not supported | Provider-native API | Supported |
| Computation | None | None (tools only) | Full Lisp runtime |
| Memory | N/A | Always `%{}` | Accumulated across turns |
| System prompt | Minimal | Minimal | Full PTC-Lisp spec |
| Compression | Not supported | Not supported | Supported |
| Sandbox | N/A | Direct function calls | Isolated BEAM process |
| Best for | Classification, extraction | Small/fast LLMs with tools | Capable LLMs |

## Piping Between Modes

Text mode returns the standard `Step` struct, enabling seamless piping:

```elixir
# Text mode extracts data
extract_agent = SubAgent.new(
  prompt: "Extract entities from: {{text}}",
  output: :text,
  signature: "(text :string) -> {entities [:string], topic :string}"
)

# PTC-Lisp mode processes with tools
process_agent = SubAgent.new(
  prompt: "Look up details for {{topic}}",
  signature: "(entities [:string], topic :string) -> {details [:map]}",
  tools: %{lookup: &MyApp.lookup/1}
)

{:ok, step1} = SubAgent.run(extract_agent, context: %{text: "..."}, llm: llm)
{:ok, step2} = SubAgent.run(process_agent, context: step1, llm: llm)
```

Text mode with tools can also pipe to other modes:

```elixir
# Text mode with tools gathers data
gather = SubAgent.new(
  prompt: "Look up the population of {{city}}",
  output: :text,
  signature: "(city :string) -> {population :int, country :string}",
  tools: %{"lookup" => {&MyApp.lookup/1,
                        signature: "(city :string) -> {population :int, country :string}",
                        description: "Look up city data"}}
)

# Text mode without tools summarizes
summarize = SubAgent.new(
  prompt: "Write a one-sentence summary about {{city}} (pop: {{population}}, in {{country}})",
  output: :text,
  signature: "(city :string, population :int, country :string) -> {summary :string}"
)

{:ok, step1} = SubAgent.run(gather, context: %{city: "Tokyo"}, llm: llm)
{:ok, step2} = SubAgent.run(summarize, context: step1, llm: llm)
```

## See Also

- [Getting Started](subagent-getting-started.md) - Basic SubAgent usage
- [Core Concepts](subagent-concepts.md) - Context, memory, and data flow
- [Patterns](subagent-patterns.md) - Chaining and composition patterns
- [Signature Syntax](../signature-syntax.md) - Full type syntax reference
- `PtcRunner.SubAgent.run/2` - API reference
- `PtcRunner.SubAgent.Loop.TextMode.run/3` - Text mode execution loop
- `PtcRunner.SubAgent.JsonParser.parse/1` - JSON extraction from LLM responses
