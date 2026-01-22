# Specification: JSON Output Mode

**Status:** Draft
**Target:** v0.6.0

## Summary

Add `output: :json` mode to SubAgent that returns structured JSON data directly from the LLM, without executing PTC-Lisp code. This enables simple classification, extraction, and reasoning tasks where tool orchestration is unnecessary.

## Motivation

Current SubAgent always expects PTC-Lisp code. For simple tasks like sentiment classification:

```elixir
# Current: Overkill - LLM writes code to return a map
SubAgent.new(
  prompt: "Classify sentiment of: {{text}}",
  signature: "() -> {sentiment :string}",
  max_turns: 1
)
# LLM must write: (return {:sentiment "positive"})
```

```elixir
# Proposed: Direct JSON response
SubAgent.new(
  prompt: "Classify sentiment of: {{text}}",
  output: :json,
  signature: "() -> {sentiment :string}"
)
# LLM returns: {"sentiment": "positive"}
```

Benefits:
- Simpler prompts (no PTC-Lisp spec needed)
- Faster responses (no code parsing/execution)
- Better structured output support (schema passed to callback)
- Lower token usage (smaller system prompt)

## Design

### API

```elixir
SubAgent.new(
  prompt: "Classify: {{text}}",
  output: :json,
  signature: "(text :string) -> {sentiment :string, score :float}"
)
```

### Signature Format

JSON mode uses the **same signature syntax** as PTC-Lisp mode. This ensures:
- **Consistent syntax** across all output modes
- **Seamless piping** between agents (input/output types align)
- **Field descriptions** work identically
- **Prompt generation** can document expected input fields

The signature defines:
- **Input parameters**: `(text :string)` - Context fields the agent expects
- **Output schema**: `{sentiment :string, score :float}` - What the LLM should return

```elixir
# Full signature with input and output
signature: "(text :string) -> {sentiment :string, score :float}"

# Output-only shorthand (when input comes purely from prompt template)
signature: "{sentiment :string}"  # Equivalent to "() -> {sentiment :string}"
```

The JSON Schema passed to the callback is derived from the **output portion** of the signature.

### Constraints

| Option | JSON Mode Behavior |
|--------|-------------------|
| `tools:` | Error - not supported |
| `signature:` | Required - defines JSON schema |
| `compression:` | Error - not supported |
| Firewall fields (`_prefix`) | Error - not supported |
| `max_turns:` | Controls validation retry budget |
| `context:` | Passed to prompt template |

### Execution Flow

```
1. Build prompt (no PTC-Lisp spec, no tool docs)
2. Call LLM with {output: :json, schema: <from signature>}
3. Parse JSON from response
4. Validate against signature schema
5. If invalid and turns remaining → retry with error feedback
6. Return Step struct with parsed JSON as return value
```

### Step Result

JSON mode returns the same `Step` struct as other modes:

```elixir
%Step{
  return: %{"sentiment" => "positive"},  # Parsed JSON (string keys)
  memory: %{},                           # Always empty for JSON mode
  usage: %{...},
  turns: [...],                      # Includes retry turns if any
  fail: nil
}
```

## Callback Interface

### Request Format

```elixir
%{
  system: String.t(),
  messages: [%{role: :user, content: String.t()}],
  output: :ptc_lisp | :json,
  schema: json_schema() | nil,  # Present for :json mode, nil for :ptc_lisp
  cache: boolean()
}
```

For `:json` mode, `schema` contains a JSON Schema derived from the signature's output type:

```elixir
# signature: "(text :string) -> {sentiment :string, score :float}"
# schema:
%{
  "type" => "object",
  "properties" => %{
    "sentiment" => %{"type" => "string"},
    "score" => %{"type" => "number"}
  },
  "required" => ["sentiment", "score"],
  "additionalProperties" => false
}
```

### Callback Implementation

Callbacks should use the schema for provider-specific structured output:

```elixir
def my_llm(%{output: :json, schema: schema} = req) do
  # Use ReqLLM.generate_object for best results
  all_messages = [%{role: :system, content: req.system} | req.messages]

  case ReqLLM.generate_object(model, all_messages, schema) do
    {:ok, %{object: object, usage: usage}} ->
      {:ok, %{content: Jason.encode!(object), tokens: extract_tokens(usage)}}
    {:error, reason} ->
      {:error, reason}
  end
end

def my_llm(%{output: :ptc_lisp} = req) do
  # Standard text generation for PTC-Lisp mode
  all_messages = [%{role: :system, content: req.system} | req.messages]

  case ReqLLM.generate_text(model, all_messages) do
    {:ok, response} ->
      {:ok, %{content: ReqLLM.Response.text(response), tokens: extract_tokens(response)}}
    {:error, reason} ->
      {:error, reason}
  end
end
```

PtcRunner always validates the response against the schema, providing retry feedback if validation fails.

## Prompt Generation

### System Prompt (Minimal)

```markdown
You are a helpful assistant that returns structured JSON responses.

Return ONLY valid JSON matching the expected format. No explanation, no markdown code blocks, just the JSON object.
```

### User Message

Data is embedded directly in the task via Mustache templates (no separate Data section):

```markdown
# Task

Classify: I love this product!

# Expected Output

Return a JSON object with these fields:
- sentiment (string): The sentiment classification

Example format:
```json
{"sentiment": "..."}
```
```

For list data, use Mustache sections in the prompt:

```elixir
prompt: "Categorize: {{#items}}{{name}}, {{/items}}"
# Expands to: "Categorize: Widget, Gadget, "
```

### Error Feedback (Retry)

When validation fails:

```markdown
Your response was not valid JSON or didn't match the expected format.

Error: Missing required field "sentiment"

Your response was:
{"feeling": "positive"}

Please return valid JSON matching this format:
{"sentiment": "..."}
```

## JSON Parsing

### Extraction Priority

1. JSON in ```json code block
2. JSON in ``` code block (no language)
3. Raw JSON object (starts with `{`)
4. Raw JSON array (starts with `[`)

### Common LLM Quirks Handled

- Trailing text after JSON: `{"a": 1} Let me know if...`
- Markdown wrapper: ` ```json\n{...}\n``` `
- Explanation prefix: `Here's the result:\n{...}`

### Parser Implementation

```elixir
def parse_json(response) do
  with {:error, _} <- extract_json_code_block(response),
       {:error, _} <- extract_raw_json(response) do
    {:error, :no_json_found}
  end
end

defp extract_json_code_block(response) do
  # Match ```json ... ``` or ``` ... ```
  regex = ~r/```(?:json)?\s*\n?([\s\S]*?)\n?```/
  case Regex.run(regex, response) do
    [_, json] -> Jason.decode(String.trim(json))
    nil -> {:error, :no_code_block}
  end
end

defp extract_raw_json(response) do
  # Find JSON object or array
  trimmed = String.trim(response)
  cond do
    String.starts_with?(trimmed, "{") -> extract_json_object(trimmed)
    String.starts_with?(trimmed, "[") -> extract_json_array(trimmed)
    true -> {:error, :no_json_found}
  end
end
```

## Schema Generation from Signature

### Signature to JSON Schema

```elixir
# Input: parsed signature AST
{:signature, [], {:map, [{"sentiment", :string}, {"confidence", :float}]}}

# Output: JSON Schema
%{
  "type" => "object",
  "properties" => %{
    "sentiment" => %{"type" => "string"},
    "confidence" => %{"type" => "number"}
  },
  "required" => ["sentiment", "confidence"],
  "additionalProperties" => false
}
```

### Type Mapping

| Signature Type | JSON Schema |
|---------------|-------------|
| `:string` | `{"type": "string"}` |
| `:int` | `{"type": "integer"}` |
| `:float` | `{"type": "number"}` |
| `:bool` | `{"type": "boolean"}` |
| `:any` | `{}` (no constraint) |
| `[:type]` | `{"type": "array", "items": <type>}` |
| `{:map, fields}` | `{"type": "object", "properties": ...}` |
| `{:enum, values}` | `{"type": "string", "enum": [...]}` |

### Nested Example

```elixir
# Signature
"() -> {analysis {sentiment :string, entities [:string]}}"

# JSON Schema
%{
  "type" => "object",
  "properties" => %{
    "analysis" => %{
      "type" => "object",
      "properties" => %{
        "sentiment" => %{"type" => "string"},
        "entities" => %{
          "type" => "array",
          "items" => %{"type" => "string"}
        }
      },
      "required" => ["sentiment", "entities"],
      "additionalProperties" => false
    }
  },
  "required" => ["analysis"],
  "additionalProperties" => false
}
```

## Validation

### Schema Validation

Use existing `PtcRunner.Schema` module for JSON Schema validation:

```elixir
case Schema.validate(parsed_json, schema) do
  :ok -> {:ok, parsed_json}
  {:error, errors} -> {:error, format_validation_errors(errors)}
end
```

### Key Conversion

JSON keys are strings; convert to atoms for consistency with PTC-Lisp return values:

```elixir
# LLM returns: {"sentiment": "positive", "score": 0.95}
# Step.return: %{"sentiment" => "positive", "score" => 0.95}
```

Use safe atom conversion (existing atoms only) to prevent atom table exhaustion.

## Piping Integration

JSON mode returns the standard `Step` struct, enabling seamless piping between agents regardless of output mode.

### Type Alignment

For piping to work correctly, the **output type** of one agent should match the **input parameters** of the next:

```elixir
# Agent 1: JSON mode - outputs {sentiment, score}
agent1 = SubAgent.new(
  prompt: "Classify the sentiment of: {{text}}",
  output: :json,
  signature: "(text :string) -> {sentiment :string, score :float}"
)

# Agent 2: PTC-Lisp mode - expects {sentiment, score} as input
agent2 = SubAgent.new(
  prompt: "Take action based on sentiment analysis",
  output: :ptc_lisp,
  signature: "(sentiment :string, score :float) -> {action :string, reason :string}",
  tools: %{send_alert: ..., log_feedback: ...}
)

# Execute pipeline
{:ok, step1} = SubAgent.run(agent1, context: %{text: "I love this product!"}, llm: llm)
# step1.return = %{"sentiment" => "positive", "score" => 0.95}

{:ok, step2} = SubAgent.run(agent2, context: step1, llm: llm)
# step2 receives %{"sentiment" => "positive", "score" => 0.95} as context
# step2.return = %{"action" => "log_feedback", "reason" => "High positive sentiment"}
```

### Pipeline Patterns

```elixir
# JSON → JSON chain (extraction → classification)
extract_agent = SubAgent.new(
  prompt: "Extract product mentions from: {{review}}",
  output: :json,
  signature: "(review :string) -> {products [:string], main_topic :string}"
)

classify_agent = SubAgent.new(
  prompt: "Classify sentiment for {{main_topic}}",
  output: :json,
  signature: "(products [:string], main_topic :string) -> {sentiment :string}"
)

{:ok, step1} = SubAgent.run(extract_agent, context: %{review: "..."}, llm: llm)
{:ok, step2} = SubAgent.run(classify_agent, context: step1, llm: llm)


# PTC-Lisp → JSON chain (orchestration → summarization)
orchestrate_agent = SubAgent.new(
  prompt: "Gather data about {{topic}}",
  output: :ptc_lisp,
  signature: "(topic :string) -> {data [:map], sources [:string]}",
  tools: %{search: ..., fetch: ...}
)

summarize_agent = SubAgent.new(
  prompt: "Summarize the gathered data",
  output: :json,
  signature: "(data [:map], sources [:string]) -> {summary :string, key_points [:string]}"
)

{:ok, step1} = SubAgent.run(orchestrate_agent, context: %{topic: "climate"}, llm: llm)
{:ok, step2} = SubAgent.run(summarize_agent, context: step1, llm: llm)
```

### Field Descriptions in Pipelines

Field descriptions propagate through pipelines, providing context to downstream agents:

```elixir
agent1 = SubAgent.new(
  prompt: "Analyze: {{text}}",
  output: :json,
  signature: "(text :string) -> {sentiment :string, confidence :float}",
  field_descriptions: %{
    sentiment: "One of: positive, negative, neutral",
    confidence: "Confidence score between 0.0 and 1.0"
  }
)

agent2 = SubAgent.new(
  prompt: "Decide action based on analysis",
  output: :ptc_lisp,
  signature: "(sentiment :string, confidence :float) -> {action :string}",
  tools: action_tools
  # Agent 2 receives field_descriptions from step1, helping the LLM understand the input
)

{:ok, step1} = SubAgent.run(agent1, context: %{text: "Great!"}, llm: llm)
{:ok, step2} = SubAgent.run(agent2, context: step1, llm: llm)
# step1.field_descriptions are passed to agent2's prompt generation
```

## Files to Modify

### Step 1: Core JSON Mode (PtcRunner)

| File | Changes |
|------|---------|
| `lib/ptc_runner/sub_agent.ex` | Add `output:` field, validation, execution branch |
| `lib/ptc_runner/sub_agent/validator.ex` | Add JSON mode validation rules |
| `lib/ptc_runner/sub_agent/json_loop.ex` | New file - JSON mode execution loop |
| `lib/ptc_runner/sub_agent/json_parser.ex` | New file - JSON extraction from LLM response |
| `lib/ptc_runner/sub_agent/signature.ex` | Add `to_json_schema/1` |
| `lib/ptc_runner/sub_agent/system_prompt.ex` | Add JSON mode prompt generation |
| `priv/prompts/json_system.md` | New - JSON mode system prompt template |
| `priv/prompts/json_user.md` | New - JSON mode user message template |

### Step 2: LLMClient Extension

Extend `llm_client` to support structured output and provide a simple SubAgent callback:

| File | Changes |
|------|---------|
| `llm_client/lib/llm_client.ex` | Add `generate_object/4`, `call/2`, `callback/1` |
| `llm_client/lib/llm_client/providers.ex` | Implement `generate_object/4` using ReqLLM |

#### New API

```elixir
# Low-level: structured output
LLMClient.generate_object(model, messages, schema, opts \\ [])
# Returns: {:ok, %{object: map(), tokens: map()}} | {:error, term()}

# SubAgent-compatible: handles both :json and :ptc_lisp modes
LLMClient.call(model, subagent_request)
# Returns: {:ok, %{content: string, tokens: map()}} | {:error, term()}

# Convenience: creates a callback for SubAgent.run
LLMClient.callback(model_or_alias)
# Returns: (subagent_request -> {:ok, response} | {:error, term()})
```

#### Usage in LiveBooks/Demo

```elixir
# One line to create callback
llm = LLMClient.callback("sonnet")

# Works for both JSON and PTC-Lisp modes automatically
{:ok, step} = SubAgent.run(
  SubAgent.new(prompt: "Classify: {{text}}", output: :json, signature: "(text :string) -> {sentiment :string}"),
  llm: llm,
  context: %{text: "Great product!"}
)

# Same callback works for PTC-Lisp
{:ok, step} = SubAgent.run(
  SubAgent.new(prompt: "Calculate {{x}} + {{y}}", tools: %{add: &Kernel.+/2}),
  llm: llm,
  context: %{x: 1, y: 2}
)
```

This validates the JSON mode design works well with ReqLLM's structured output.

## Testing Strategy

### Unit Tests

```elixir
# JSON parsing
test "extracts JSON from code block"
test "extracts raw JSON object"
test "handles trailing text after JSON"
test "returns error when no JSON found"

# Schema generation from signature
test "converts simple signature to JSON schema"
test "converts nested signature to JSON schema"
test "converts array types correctly"
test "converts enum types correctly"
test "extracts output schema from full signature (input -> output)"
test "handles output-only shorthand signature"

# Signature validation
test "accepts full signature with input and output"
test "accepts output-only shorthand"
test "rejects signature with firewall fields in JSON mode"

# Mode validation
test "rejects JSON mode with tools"
test "rejects JSON mode without signature"
test "rejects JSON mode with compression"
```

### Integration Tests

```elixir
test "JSON mode returns parsed data" do
  agent = SubAgent.new(
    prompt: "Return greeting",
    output: :json,
    signature: "() -> {message :string}"
  )

  llm = fn _ -> {:ok, ~s|{"message": "hello"}|} end
  {:ok, step} = SubAgent.run(agent, llm: llm)

  assert step.return == %{"message" => "hello"}
end

test "JSON mode retries on validation error" do
  agent = SubAgent.new(
    prompt: "Return greeting",
    output: :json,
    signature: "() -> {message :string}",
    max_turns: 3
  )

  # First call returns invalid, second returns valid
  llm = mock_llm([
    {:ok, ~s|{"wrong": "field"}|},
    {:ok, ~s|{"message": "hello"}|}
  ])

  {:ok, step} = SubAgent.run(agent, llm: llm)
  assert step.return == %{"message" => "hello"}
  assert length(step.turns) == 2
end

test "JSON mode pipes to PTC-Lisp mode with type alignment" do
  json_agent = SubAgent.new(
    prompt: "Classify: {{text}}",
    output: :json,
    signature: "(text :string) -> {sentiment :string, score :float}"
  )

  lisp_agent = SubAgent.new(
    prompt: "Act on sentiment",
    signature: "(sentiment :string, score :float) -> {action :string}",
    tools: %{alert: fn _ -> "alerted" end}
  )

  llm_json = fn _ -> {:ok, ~s|{"sentiment": "positive", "score": 0.9}|} end
  llm_lisp = fn _ -> {:ok, "(return {:action (alert)})"} end

  {:ok, step1} = SubAgent.run(json_agent, llm: llm_json, context: %{text: "Great!"})
  {:ok, step2} = SubAgent.run(lisp_agent, llm: llm_lisp, context: step1)

  assert step1.return == %{"sentiment" => "positive", "score" => 0.9}
  assert step2.return == %{"action" => "alerted"}
end

test "PTC-Lisp mode pipes to JSON mode" do
  lisp_agent = SubAgent.new(
    prompt: "Fetch data",
    signature: "(query :string) -> {results [:map]}",
    tools: %{search: fn _ -> [%{title: "Result"}] end}
  )

  json_agent = SubAgent.new(
    prompt: "Summarize results",
    output: :json,
    signature: "(results [:map]) -> {summary :string}"
  )

  llm_lisp = fn _ -> {:ok, "(return {:results (search query)})"} end
  llm_json = fn _ -> {:ok, ~s|{"summary": "Found one result"}|} end

  {:ok, step1} = SubAgent.run(lisp_agent, llm: llm_lisp, context: %{query: "test"})
  {:ok, step2} = SubAgent.run(json_agent, llm: llm_json, context: step1)

  assert step2.return == %{"summary" => "Found one result"}
end

test "JSON → JSON pipeline works" do
  agent1 = SubAgent.new(
    prompt: "Extract",
    output: :json,
    signature: "(text :string) -> {entities [:string]}"
  )

  agent2 = SubAgent.new(
    prompt: "Classify",
    output: :json,
    signature: "(entities [:string]) -> {category :string}"
  )

  llm1 = fn _ -> {:ok, ~s|{"entities": ["apple", "banana"]}|} end
  llm2 = fn _ -> {:ok, ~s|{"category": "fruits"}|} end

  {:ok, step1} = SubAgent.run(agent1, llm: llm1, context: %{text: "..."})
  {:ok, step2} = SubAgent.run(agent2, llm: llm2, context: step1)

  assert step2.return == %{"category" => "fruits"}
end
```

### E2E Tests

```elixir
@tag :e2e
test "sentiment classification with real LLM" do
  agent = SubAgent.new(
    prompt: "Classify the sentiment of: {{text}}",
    output: :json,
    signature: "() -> {sentiment :string, confidence :float}"
  )

  {:ok, step} = SubAgent.run(agent,
    llm: real_llm(),
    context: %{text: "I love this product!"}
  )

  assert step.return["sentiment"] in ["positive", "negative", "neutral"]
  assert is_float(step.return["confidence"])
end
```

## Design Decisions

### D1: Signature Format

**Decision:** Use the same PTC-Lisp signature syntax for JSON mode.

```elixir
# Full form - input parameters and output schema
signature: "(text :string) -> {sentiment :string, score :float}"

# Shorthand - output schema only (equivalent to "() -> ...")
signature: "{sentiment :string}"
```

**Rationale:**
- Consistent syntax across all output modes
- Enables seamless piping between agents (input/output types align)
- Field descriptions work identically
- Input parameters are documented in the prompt for the LLM
- JSON Schema is derived internally from the output portion

## Open Questions

### Q1: Should JSON mode support `memory:`?

**Recommendation:** No. JSON mode is single-shot by design. Memory accumulation doesn't make sense without multi-turn tool orchestration.

`step.memory` will always be `%{}` for JSON mode.

### Q2: Default `max_turns` for JSON mode?

**Recommendation:** Same as default (5). This provides a reasonable retry budget for validation errors without special-casing.

### Q3: Should we support `output: :json` with `max_turns: 1`?

**Recommendation:** Yes. Single-shot JSON mode is valid - it just means no retries on validation failure.

### Q4: Key format - strings or atoms?

**Recommendation:** Atoms for consistency with PTC-Lisp. Use `String.to_existing_atom/1` with fallback to keep as string if atom doesn't exist. This prevents atom table exhaustion while maintaining ergonomic access.

```elixir
# Safe conversion
defp to_atom_keys(map) when is_map(map) do
  Map.new(map, fn {k, v} ->
    key = try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> k  # Keep as string if atom doesn't exist
    end
    {key, to_atom_keys(v)}
  end)
end

defp to_atom_keys(list) when is_list(list), do: Enum.map(list, &to_atom_keys/1)
defp to_atom_keys(value), do: value
```

## Success Criteria

1. `output: :json` works for simple classification tasks
2. Validation errors trigger clear retry feedback
3. Schema is passed to callback for provider-specific optimization
4. Piping between JSON and PTC-Lisp modes works seamlessly
5. Existing PTC-Lisp tests unchanged
6. Clear error messages for invalid configurations
