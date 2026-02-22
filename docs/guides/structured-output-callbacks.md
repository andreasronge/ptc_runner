# Structured Output Callbacks

This guide explains how to implement LLM callbacks for SubAgents, including support for `output: :text` mode.

## Overview

```elixir
SubAgent.new(
  prompt: "Classify the sentiment of: {{text}}",
  output: :text,
  signature: "(text :string) -> {sentiment :string, confidence :float}"
)
```

Text mode uses the **same signature syntax** as PTC-Lisp mode, enabling seamless piping between agents.

## Callback Interface

Your callback receives:

```elixir
%{
  system: String.t(),
  messages: list(),
  output: :ptc_lisp | :text,
  schema: json_schema() | nil,  # Present when agent has a complex return type
  tools: [tool_def()] | nil,    # Present when agent has tools
  cache: boolean()
}
```

The `schema` key is present when the agent has a complex return type (map, list, float, int), regardless of whether tools are used. The `tools` key is present when the agent has tools defined.

For complex return types, `schema` contains a JSON Schema derived from the signature:

```elixir
# signature: "(text :string) -> {sentiment :string, confidence :float}"
# schema:
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

## Implementation with ReqLLM

[ReqLLM](https://hexdocs.pm/req_llm) provides `generate_object/4` and `generate_with_tools/4` which handle structured output across providers (OpenAI, Anthropic, Google, OpenRouter, etc.).

```elixir
defmodule MyApp.LLMCallback do
  @model "openrouter:anthropic/claude-sonnet-4-20250514"

  # Tools present -> use generate_with_tools
  def call(%{tools: tools} = req) when is_list(tools) and tools != [] do
    messages = [%{role: :system, content: req.system} | req.messages]

    case ReqLLM.generate_with_tools(@model, messages, tools) do
      {:ok, response} ->
        {:ok, %{content: response.content, tokens: extract_tokens(response.usage)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Complex return type (schema present, no tools) -> use generate_object
  def call(%{schema: schema} = req) when is_map(schema) do
    messages = [%{role: :system, content: req.system} | req.messages]

    case ReqLLM.generate_object(@model, messages, schema) do
      {:ok, %{object: object, usage: usage}} ->
        {:ok, %{content: Jason.encode!(object), tokens: extract_tokens(usage)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Plain text (no schema, no tools) -> use generate_text
  def call(req) do
    messages = [%{role: :system, content: req.system} | req.messages]

    case ReqLLM.generate_text(@model, messages) do
      {:ok, response} ->
        {:ok, %{
          content: ReqLLM.Response.text(response),
          tokens: extract_tokens(ReqLLM.Response.usage(response))
        }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_tokens(nil), do: %{input: 0, output: 0}
  defp extract_tokens(usage) do
    %{
      input: usage[:input_tokens] || 0,
      output: usage[:output_tokens] || 0
    }
  end
end
```

## Using LLMClient (Simplest)

The `llm_client` package provides `callback/1` that handles all modes automatically:

```elixir
# One line - works for :text and :ptc_lisp modes
llm = LLMClient.callback("sonnet")

# Use with any SubAgent
{:ok, step} = SubAgent.run(agent, llm: llm, context: %{...})
```

This is the recommended approach for LiveBooks, demos, and examples.

### Lower-Level API

If you need more control:

```elixir
# Direct call with request map
LLMClient.call("sonnet", subagent_request)

# Structured output only
LLMClient.generate_object(model, messages, schema)

# Text generation only
LLMClient.generate_text(model, messages)
```

## Provider-Specific Implementation

If not using ReqLLM, implement provider-specific structured output:

### OpenAI

```elixir
def call(%{schema: schema} = req) when is_map(schema) do
  result = OpenAI.chat(
    model: "gpt-4o",
    messages: [%{role: "system", content: req.system} | req.messages],
    response_format: %{
      type: "json_schema",
      json_schema: %{name: "response", schema: schema, strict: true}
    }
  )

  case result do
    {:ok, resp} -> {:ok, %{content: resp.choices[0].message.content, tokens: resp.usage}}
    {:error, _} = err -> err
  end
end
```

### Anthropic (Tool-as-Schema)

```elixir
def call(%{schema: schema} = req) when is_map(schema) do
  tool = %{
    name: "respond",
    description: "Return your structured response",
    input_schema: schema
  }

  result = Anthropic.messages(
    model: "claude-sonnet-4-20250514",
    system: req.system,
    messages: req.messages,
    tools: [tool],
    tool_choice: %{type: "tool", name: "respond"}
  )

  case result do
    {:ok, %{content: [%{type: "tool_use", input: args}]} = resp} ->
      {:ok, %{content: Jason.encode!(args), tokens: resp.usage}}

    {:error, _} = err ->
      err
  end
end
```

## Validation

PtcRunner always validates responses against the schema. If validation fails, it retries with error feedback. This ensures correctness even if the provider's structured output isn't perfect.

## Testing

```elixir
# Simple schema
agent = SubAgent.new(
  prompt: "Greet {{name}}",
  output: :text,
  signature: "(name :string) -> {message :string}"
)

# Nested schema
agent = SubAgent.new(
  prompt: "Analyze: {{text}}",
  output: :text,
  signature: "(text :string) -> {analysis {sentiment :string, entities [:string]}}"
)

# Output-only shorthand
agent = SubAgent.new(
  prompt: "Return a greeting",
  output: :text,
  signature: "{message :string}"  # Equivalent to "() -> {message :string}"
)

{:ok, step} = SubAgent.run(agent, llm: &MyApp.LLMCallback.call/1, context: %{name: "Alice"})
```

Verify:
1. Response parses as valid JSON (when complex return type)
2. Response matches expected schema
3. Retries work when validation fails
4. Token counts are captured correctly
5. Plain text responses work when no signature or `:string` return type
