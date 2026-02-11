# Plan: SubAgent Output Modes

## Overview

Add an `output:` parameter to `SubAgent.new/1` that controls what format the LLM returns. This enables both program execution (current behavior) and direct data responses.

```elixir
# Program modes - LLM writes executable code
SubAgent.new(prompt: "Orchestrate tools...", output: :ptc_lisp)  # default

# Data modes - LLM returns data directly
SubAgent.new(prompt: "Classify this review...", output: :json)
SubAgent.new(prompt: "Summarize this text...", output: :text)
```

## Output Modes

| Mode | Tools? | Signature? | Sandbox? | Schema to Callback? | Use Case |
|------|--------|------------|----------|---------------------|----------|
| `:ptc_lisp` | Yes | Yes | Yes | No | Orchestration, complex logic |
| `:json` | No | Yes | No | Yes (output shape) | Structured data, reasoning |
| `:text` | No | No | No | No | Free-form responses |

## Design Decisions

### D1: Output mode validation

| Mode | Tools allowed? | Signature required? | Firewall fields (`_`)? | Compression? |
|------|----------------|---------------------|------------------------|--------------|
| `:ptc_lisp` | Yes | Optional | Yes | Yes |
| `:json` | No (error) | Yes (required) | No (error) | No (error) |
| `:text` | No (error) | No (ignored) | N/A | No (error) |

### D2: Multi-turn retry

- `:json` mode: Retry on validation errors (same as program modes)
- `:text` mode: No retry (nothing to validate)
- `max_turns` controls retry budget

### D3: LLM response format

- `:json` mode: JSON in code block (```json), fallback to raw JSON
- `:text` mode: Raw text (no parsing)

### D4: Piping integration

All modes return the same `Step` struct - piping works seamlessly:

```elixir
# :json → :ptc_lisp chain
{:ok, step1} = SubAgent.run(
  SubAgent.new(prompt: "Classify: {{review}}",
               output: :json,
               signature: "() -> {sentiment :string}"),
  context: %{review: "Great!"},
  llm: llm
)

{:ok, step2} = SubAgent.run(
  SubAgent.new(prompt: "Decide action based on sentiment",
               output: :ptc_lisp,
               tools: action_tools),
  context: step1,  # Works exactly like before
  llm: llm
)
```

---

## LLM Callback Interface

### Current Interface

```elixir
%{system: String.t(), messages: list()}
```

### Extended Interface

```elixir
%{
  system: String.t(),
  messages: list(),
  output: :ptc_lisp | :json | :text,
  schema: json_schema_map() | nil
}
```

**Schema availability:**

| Output | Schema | Size | Content |
|--------|--------|------|---------|
| `:ptc_lisp` | `nil` | - | N/A |
| `:json` | Map | Small | Output shape from signature |
| `:text` | `nil` | - | N/A |

### Callback Usage (Optional)

The callback can use `output` and `schema` to configure provider-specific features:

```elixir
def my_llm(%{output: output, schema: schema} = req) do
  opts = base_opts()

  # Optionally use schema for structured output
  opts = case {output, schema} do
    {mode, schema} when mode == :json and schema != nil ->
      if provider_supports_json_schema?() do
        # OpenAI: response_format with json_schema
        Keyword.put(opts, :response_format, %{
          type: "json_schema",
          json_schema: %{name: "response", schema: schema}
        })
      else
        # Ignore schema, rely on prompt + validation
        opts
      end

    _ ->
      opts
  end

  ReqLLM.generate_text(model, build_messages(req), opts)
end
```

**Key principle:** Schema usage is optional. PtcRunner always validates responses regardless of whether the callback used the schema.

---

## Implementation Stages

### Stage 1: Core `:json` Mode

Minimal implementation to enable direct JSON responses.

#### 1.1 Update SubAgent Struct

**File:** `lib/ptc_runner/sub_agent.ex`

- [ ] Add `output:` field to struct (default: `:ptc_lisp`)
- [ ] Add validation rules per output mode
- [ ] Add helper: `program_mode?/1`, `data_mode?/1` predicates

```elixir
defstruct [
  :prompt,
  output: :ptc_lisp,  # new field
  # ... rest unchanged
]
```

**Validation rules:**

```elixir
defp validate_output_mode(agent) do
  case agent.output do
    :ptc_lisp -> :ok
    :json ->
      cond do
        map_size(agent.tools) > 0 ->
          {:error, ":json mode does not support tools"}
        agent.parsed_signature == nil ->
          {:error, ":json mode requires a signature"}
        has_firewall_fields?(agent.parsed_signature) ->
          {:error, ":json mode does not support firewall fields (_prefix)"}
        agent.compression ->
          {:error, ":json mode does not support compression"}
        true ->
          :ok
      end
    :text ->
      cond do
        map_size(agent.tools) > 0 ->
          {:error, ":text mode does not support tools"}
        agent.compression ->
          {:error, ":text mode does not support compression"}
        true ->
          :ok
      end
  end
end
```

#### 1.2 JSON Response Parser

**File:** `lib/ptc_runner/sub_agent/loop/response_handler.ex`

- [ ] Add `parse_json/1` function
- [ ] Try ```json code block first
- [ ] Fallback to raw JSON detection
- [ ] Handle common LLM quirks (trailing text, markdown wrapping)

```elixir
def parse_json(response) do
  with {:error, _} <- extract_json_code_block(response),
       {:error, _} <- extract_raw_json(response) do
    {:error, :no_json_found}
  end
end
```

#### 1.3 JSON Mode Prompt Generation

**File:** `lib/ptc_runner/sub_agent/system_prompt.ex`

- [ ] Add `generate_json_prompt/2` function
- [ ] Simple template: context + task + output format
- [ ] No PTC language spec, no tool documentation

**Template:**

```markdown
# Context
{{data_section}}

# Task
{{prompt}}

# Output Format
Respond with a JSON object matching this structure:
```json
{{example_output}}
```

Return ONLY the JSON object, no explanation or markdown.
```

#### 1.4 JSON Mode Execution Path

**File:** `lib/ptc_runner/sub_agent.ex`

- [ ] Branch in `run/2` based on `output:` mode
- [ ] For `:json` mode:
  1. Generate JSON prompt
  2. Call LLM (with `output: :json, schema: schema` in request)
  3. Parse JSON response
  4. Validate against signature
  5. Retry with feedback if invalid
  6. Return Step struct

```elixir
defp run_json_mode(agent, opts) do
  schema = Signature.to_json_schema(agent.parsed_signature)
  # ... implementation
end
```

#### 1.5 Schema Generation from Signature

**File:** `lib/ptc_runner/sub_agent/signature.ex`

- [ ] Add `to_json_schema/1` function
- [ ] Convert parsed signature to JSON Schema format

```elixir
def to_json_schema({:signature, _params, return_type}) do
  type_to_json_schema(return_type)
end

defp type_to_json_schema({:map, fields}) do
  %{
    "type" => "object",
    "properties" => Map.new(fields, fn {name, type} ->
      {name, type_to_json_schema(type)}
    end),
    "required" => Enum.map(fields, fn {name, _} -> name end)
  }
end

defp type_to_json_schema(:string), do: %{"type" => "string"}
defp type_to_json_schema(:int), do: %{"type" => "integer"}
defp type_to_json_schema(:float), do: %{"type" => "number"}
# ... etc
```

#### 1.6 Extend Callback Interface

**File:** `lib/ptc_runner/sub_agent/llm_resolver.ex`

- [ ] Pass `output:` and `schema:` to callback
- [ ] Backward compatible: old callbacks ignore new fields

```elixir
def resolve(llm, request, opts) do
  extended_request = Map.merge(request, %{
    output: Keyword.get(opts, :output, :ptc_lisp),
    schema: Keyword.get(opts, :schema)
  })
  # ... call llm with extended_request
end
```

### Stage 2: `:text` Mode

Simple addition after `:json` mode works.

- [ ] Add `:text` mode execution path
- [ ] No parsing, no validation
- [ ] Return raw text in `step.return`
- [ ] `step.signature` = nil for text mode

### Stage 3: Documentation & Guides

- [ ] Update `docs/guides/subagent-getting-started.md` with output modes
- [ ] Add `docs/guides/structured-output-callbacks.md` for LLM callback guide
- [ ] Add examples for ReqLLM integration
- [ ] Add livebook examples for each mode

---

## Files to Change

| File | Stage | Changes |
|------|-------|---------|
| `lib/ptc_runner/sub_agent.ex` | 1 | Add `output:` field, validation, execution branches |
| `lib/ptc_runner/sub_agent/loop/response_handler.ex` | 1 | Add `parse_json/1` |
| `lib/ptc_runner/sub_agent/system_prompt.ex` | 1 | Add `generate_json_prompt/2` |
| `lib/ptc_runner/sub_agent/signature.ex` | 1 | Add `to_json_schema/1` |
| `lib/ptc_runner/sub_agent/llm_resolver.ex` | 1 | Extend callback interface |
| `priv/prompts/json.md` | 1 | New template for JSON mode |
| `priv/prompts/text.md` | 2 | New template for text mode |

## Files Unchanged (Reused)

| File | Why Unchanged |
|------|---------------|
| `lib/ptc_runner/step.ex` | Same struct for all modes |
| `lib/ptc_runner/lisp.ex` | Only used for `:ptc_lisp` mode |
| `lib/ptc_runner/sandbox.ex` | Only used for program modes |
| `lib/ptc_runner/sub_agent/loop/return_validation.ex` | Reused for JSON validation feedback |

---

## Testing Strategy

### Stage 1 Tests

**Unit:**
- [ ] `parse_json/1` with code blocks, raw JSON, edge cases
- [ ] `to_json_schema/1` for various signature types
- [ ] Validation: `:json` + `tools:` raises error
- [ ] Validation: `:json` without signature raises error
- [ ] Validation: `:json` + firewall fields raises error

**Integration:**
- [ ] `:json` mode → valid response → success
- [ ] `:json` mode → invalid JSON → retry → success
- [ ] `:json` mode → schema validation error → retry
- [ ] Piping: `:json` → `:ptc_lisp`
- [ ] Piping: `:ptc_lisp` → `:json`

**E2E:**
- [ ] Sentiment classification with `:json` mode
- [ ] Data extraction with `:json` mode

### Stage 2 Tests

- [ ] `:text` mode returns raw text
- [ ] `:text` mode ignores signature
- [ ] Piping: `:text` → `:ptc_lisp` (text as context)

---

## Guide: Using Structured Output with LLM Callbacks

*(To be written as `docs/guides/structured-output-callbacks.md`)*

### Basic Callback (Ignores Schema)

```elixir
def my_llm(%{system: system, messages: messages}) do
  # Schema and output mode are ignored
  # PtcRunner handles validation
  ReqLLM.generate_text(:openai,
    [%{role: "system", content: system} | messages],
    receive_timeout: 30_000
  )
end
```

### Using JSON Schema with OpenAI

```elixir
def my_llm(%{system: system, messages: messages, output: output, schema: schema} = req) do
  opts = [receive_timeout: 30_000]

  opts = if output == :json and schema do
    Keyword.put(opts, :response_format, %{
      type: "json_schema",
      json_schema: %{name: "response", schema: schema, strict: true}
    })
  else
    opts
  end

  ReqLLM.generate_text(:openai, build_messages(req), opts)
end
```

### Using Tool Calling with Anthropic

```elixir
def my_llm(%{output: output, schema: schema} = req) when output == :json and schema != nil do
  # Convert schema to tool definition
  tool = %{
    name: "respond",
    description: "Return the response",
    input_schema: schema
  }

  result = ReqLLM.generate_text(:anthropic, build_messages(req),
    tools: [tool],
    tool_choice: %{type: "tool", name: "respond"}
  )

  # Extract tool call arguments as content
  case result do
    {:ok, %{tool_calls: [%{arguments: args}]}} ->
      {:ok, %{content: Jason.encode!(args), tokens: result.tokens}}
    other ->
      other
  end
end
```

### Fallback: Prompt + Validation

```elixir
def my_llm(req) do
  # Just call the LLM, let PtcRunner handle validation and retry
  ReqLLM.generate_text(:my_model, build_messages(req))
end
```

---

## Success Criteria

1. `:json` mode works for sentiment classification (no syntax errors)
2. Validation errors trigger helpful retry feedback
3. Piping between all modes works seamlessly
4. Callback receives `output:` and `schema:` fields
5. Existing `:ptc_lisp` tests unchanged
6. Clear error messages for invalid configurations
7. Guide enables users to leverage provider-specific structured output

---

## Open Questions

1. **Default `max_turns` for `:json` mode?**
   - Suggestion: Same as current default (5), since it's just for validation retries

2. **Should `:text` mode support `context:` for piping?**
   - Yes, but `step.return` is just the raw text string

3. **Should we rename `prompt:` for consistency?**
   - No - `prompt:` is the task/mission, `output:` is the format
   - They're orthogonal concerns

4. **Memory handling for `:json` mode?**
   - `step.memory` = empty map (no memory accumulation)
   - Consistent with single-shot behavior

---

## Extended Callback Interface: Tool Calling Support

### Background: Tool Calling Landscape

Most LLM providers support tool/function calling with variations:
- OpenAI: `tools` + `tool_calls` in response
- Anthropic: `tools` + `tool_use` content blocks
- Others: Similar patterns with field name differences

**Key insight**: Tool calling is often more portable than `response_format: json_schema` across providers and aggregators like OpenRouter.

### Extended Callback Interface

```elixir
# Full callback request (v0.6+)
%{
  system: String.t(),
  messages: list(),
  output: :ptc_lisp | :json | :text,

  # Structured output (current plan)
  schema: json_schema_map() | nil,

  # Tool calling support (new)
  tools: [%{name: String.t(), description: String.t(), parameters: map()}] | nil,
  tool_choice: :auto | :none | {:tool, String.t()} | nil
}

# Callback response (extended)
%{
  content: String.t() | nil,
  tool_calls: [%{id: String.t(), name: String.t(), arguments: map()}] | nil,
  tokens: %{input: integer(), output: integer()}
}
```

### Tool Calling as Structured Output Mechanism

For `:json` mode, instead of relying on `response_format` (not all providers support), use tool calling:

```elixir
def my_llm(%{output: :json, schema: schema} = req) when schema != nil do
  # Force structured output via tool calling
  tool = %{
    name: "respond",
    description: "Return your response",
    parameters: schema
  }

  result = call_provider(req, tools: [tool], tool_choice: {:tool, "respond"})

  # Extract tool arguments as JSON response
  case result do
    {:ok, %{tool_calls: [%{arguments: args}]}} ->
      {:ok, %{content: Jason.encode!(args), tokens: result.tokens}}
    other ->
      other
  end
end
```

This makes `:json` mode work across more providers than native JSON schema support.

### How Each Mode Uses Tool Calling

| Mode | Uses tools? | Uses tool_choice? | Purpose |
|------|-------------|-------------------|---------|
| `:ptc_lisp` | No | No | LLM writes code |
| `:json` | Yes (schema as tool) | `{:tool, "respond"}` | Portable structured output |
| `:text` | No | No | Raw text |

---

## Future Consideration: `:chat` Mode

**Not in v0.6 scope**, but the callback interface extension enables a potential `:chat` mode for traditional tool-calling agents:

```elixir
SubAgent.new(
  prompt: "You are a helpful assistant",
  output: :chat,  # Future mode
  tools: %{
    get_weather: &Weather.get/1,
    search_web: &Search.query/1
  }
)
```

Where `:chat` mode:
- LLM can return text OR tool calls (not code)
- Framework executes tool calls, feeds results back as messages
- Loop until LLM returns final text
- Traditional agentic loop, not PTC-Lisp

**Why defer**: PtcRunner's differentiation is *programmatic* tool calling. `:chat` mode is what every other framework does. Users can build this on top of PtcRunner if needed.

---

## Future Consideration: `ask_user` Tool and Suspension

The callback interface extension also enables human-in-the-loop patterns. This ties into v0.8 (Async Tools & Suspension).

### The Pattern

In a chat application, the main conversation is plain text. SubAgent orchestration is treated like an opaque "tool call":

```
┌─────────────────────────────────────────────────────┐
│           Main Conversation (plain text)            │
│  [{user, "Send email to John"},                     │
│   {assistant, "Which John?"},      ← ask_user       │
│   {user, "John Smith"},                             │
│   {assistant, "Email sent!"}]                       │
└─────────────────────────────────────────────────────┘
                         │
                         │ SubAgent call (opaque)
                         ▼
┌─────────────────────────────────────────────────────┐
│         SubAgent (:ptc_lisp, multi-turn)            │
│  Turn 1: (let [contacts (search "John")]            │
│            (if (> (len contacts) 1)                 │
│              (ask_user "Which John?" contacts)))    │
│          → SUSPENDS                                 │
│                                                     │
│  Turn 2: (send_email selected_john ...)             │
│          → (return "Email sent")                    │
└─────────────────────────────────────────────────────┘
```

### How It Works

`ask_user` is a tool that **suspends** the SubAgent:

```elixir
# Tool returns special suspension marker
def ask_user(question, options \\ nil) do
  {:suspend, %{question: question, options: options}}
end

# SubAgent.run returns suspension state
{:suspended, step, continuation}

# Later, resume with user's answer
{:ok, final_step} = SubAgent.resume(continuation, user_input: "John Smith")
```

### Relationship to v0.7 Async

This is essentially the same mechanism as async tools:
- `ask_user` suspends waiting for human input
- `make_phone_call` suspends waiting for call completion
- Both need: state serialization, continuation tokens, resume API

**Decision**: Defer to v0.8, but the callback interface changes in v0.6 lay groundwork.

---

## Limitations and Anti-Patterns

### Mixed-Mode Pipeline Caveats

1. **Memory asymmetry**: `:json` mode returns `step.memory = %{}`. In chains like `:ptc_lisp → :json → :ptc_lisp`, memory accumulated in the first agent is not automatically passed through the `:json` step.

2. **Type mismatches**: When piping complex `:ptc_lisp` output into a `:json` agent expecting simple input, ensure the context shape matches what the prompt expects.

3. **`:text` mode fragility**: Piping unstructured text into agents expecting structured context may cause runtime surprises.

### When NOT to Use Each Mode

| Mode | Anti-pattern |
|------|-------------|
| `:json` | Complex multi-step orchestration (use `:ptc_lisp`) |
| `:text` | When you need validation or structured data |
| `:ptc_lisp` | Simple classification/extraction (overkill) |

### `max_turns` Semantic Difference

- `:ptc_lisp`: `max_turns` = orchestration iterations (tool calls + reasoning)
- `:json`: `max_turns` = validation retry budget (simpler)

Don't assume they mean the same thing when switching modes.
