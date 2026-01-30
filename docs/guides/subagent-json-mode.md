# JSON Mode SubAgents

JSON mode returns structured data directly from the LLM without executing PTC-Lisp code.

## When to Use JSON Mode

Use JSON mode for tasks that need structured output but not computation or tool calls:

| Task Type | Mode | Why |
|-----------|------|-----|
| Classification | JSON | Direct structured response |
| Entity extraction | JSON | No computation needed |
| Summarization with structure | JSON | Simple output mapping |
| Multi-step reasoning | PTC-Lisp | Needs tool calls |
| Data transformation | PTC-Lisp | Needs computation |
| External API calls | PTC-Lisp | Needs tools |

## Basic Usage

```elixir
{:ok, step} = SubAgent.run(
  "Classify the sentiment of: {{text}}",
  context: %{text: "I love this product!"},
  output: :json,
  signature: "(text :string) -> {sentiment :string, score :float}",
  llm: my_llm
)

step.return  #=> %{"sentiment" => "positive", "score" => 0.95}
```

**Constraints:** JSON mode requires a signature, cannot use tools, and doesn't support compression or firewall fields.

## Mustache Templates

JSON mode embeds data directly in the prompt using Mustache syntax. All signature parameters must appear in the prompt.

### Simple Variables

Reference context values with `{{variable}}`:

```elixir
SubAgent.new(
  prompt: "Analyze the sentiment of: {{text}}",
  output: :json,
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
  output: :json,
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
  output: :json,
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
  output: :json,
  signature: "(items [:string]) -> {status :string}"
)
```

## Validation Rules

JSON mode enforces strict validation at agent construction time.

### All Parameters Must Be Used

Every signature parameter must appear in the prompt (as a variable or section):

```elixir
# Valid - both params used
SubAgent.new(
  prompt: "Analyze {{text}} for {{user}}",
  output: :json,
  signature: "(text :string, user :string) -> {result :string}"
)

# Invalid - 'user' not used
SubAgent.new(
  prompt: "Analyze {{text}}",
  output: :json,
  signature: "(text :string, user :string) -> {result :string}"
)
# => ArgumentError: JSON mode requires all signature params in prompt. Unused: ["user"]
```

### Section Fields Must Match Signature

Fields inside sections are validated against the element type:

```elixir
# Valid - 'name' exists in element type
SubAgent.new(
  prompt: "{{#items}}{{name}}{{/items}}",
  output: :json,
  signature: "(items [{name :string, price :float}]) -> {count :int}"
)

# Invalid - 'unknown' not in element type
SubAgent.new(
  prompt: "{{#items}}{{unknown}}{{/items}}",
  output: :json,
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
  output: :json,
  signature: "(tags [:string]) -> {count :int}"
)

# Invalid - items is [{name :string}], use {{name}} instead
SubAgent.new(
  prompt: "{{#items}}{{.}}{{/items}}",
  output: :json,
  signature: "(items [{name :string}]) -> {count :int}"
)
# => ArgumentError: {{.}} inside {{#items}} - use {{field}} instead (list contains maps)
```

## JSON Mode vs PTC-Lisp Mode

| Aspect | JSON Mode | PTC-Lisp Mode |
|--------|-----------|---------------|
| Data in prompt | Embedded via Mustache | Shown in Data Inventory |
| Template syntax | Full Mustache (sections) | Simple `{{var}}` only |
| LLM output | JSON object | PTC-Lisp code |
| Tools | Not supported | Supported |
| Compression | Not supported | Supported |
| Use case | Classification, extraction | Computation, orchestration |

## Piping Between Modes

JSON mode returns the standard `Step` struct, enabling seamless piping:

```elixir
# JSON mode extracts data
extract_agent = SubAgent.new(
  prompt: "Extract entities from: {{text}}",
  output: :json,
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

## See Also

- [Getting Started](subagent-getting-started.md) - Basic SubAgent usage
- [Core Concepts](subagent-concepts.md) - Context, memory, and data flow
- [Patterns](subagent-patterns.md) - Chaining and composition patterns
- [Signature Syntax](../signature-syntax.md) - Full type syntax reference
- `PtcRunner.SubAgent.run/2` - API reference
- `PtcRunner.SubAgent.Loop.JsonMode.run/3` - JSON mode execution loop
- `PtcRunner.SubAgent.JsonParser.parse/1` - JSON extraction from LLM responses
