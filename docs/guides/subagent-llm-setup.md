# LLM Setup

How to connect SubAgent to an LLM provider — from the built-in adapter to custom integrations.

## Quick Start

Add the dependencies:

```elixir
def deps do
  [
    {:ptc_runner, "~> 0.9.0"},
    {:req_llm, "~> 1.2"}  # enables the built-in adapter
  ]
end
```

Set your API key and run:

```elixir
export OPENROUTER_API_KEY=sk-or-...

llm = PtcRunner.LLM.callback("openrouter:anthropic/claude-haiku-4.5")
{:ok, step} = PtcRunner.SubAgent.run("What is 2 + 2?", llm: llm)
step.return  #=> 4
```

That's it. The built-in adapter handles text generation, structured output, tool calling,
and prompt caching across providers.

## Built-in Adapter

`PtcRunner.LLM.callback/2` creates a SubAgent-compatible callback using the built-in
`PtcRunner.LLM.ReqLLMAdapter`, which routes by model prefix:

| Prefix | Provider | API Key Env Var |
|--------|----------|-----------------|
| `openrouter:` | OpenRouter | `OPENROUTER_API_KEY` |
| `anthropic:` | Anthropic direct | `ANTHROPIC_API_KEY` |
| `bedrock:` | AWS Bedrock | `AWS_ACCESS_KEY_ID` |
| `google:` | Google Gemini | `GOOGLE_API_KEY` |
| `openai:` | OpenAI | `OPENAI_API_KEY` |
| `groq:` | Groq | `GROQ_API_KEY` |
| `ollama:` | Local Ollama | (none) |
| `openai-compat:` | Any OpenAI-compatible | (varies) |

```elixir
# Cloud providers
PtcRunner.LLM.callback("openrouter:anthropic/claude-sonnet-4")
PtcRunner.LLM.callback("anthropic:claude-haiku-4-5-20251001")
PtcRunner.LLM.callback("bedrock:haiku", cache: true)
PtcRunner.LLM.callback("google:gemini-2.5-flash")

# Local providers
PtcRunner.LLM.callback("ollama:deepseek-coder:6.7b")
PtcRunner.LLM.callback("openai-compat:http://localhost:1234/v1|my-model")
```

### Prompt Caching

Pass `cache: true` to enable prompt caching on supported providers (Anthropic, Bedrock
Claude, OpenRouter with Anthropic models):

```elixir
llm = PtcRunner.LLM.callback("bedrock:haiku", cache: true)
```

### Bedrock Region

For AWS Bedrock, the region is resolved in order:

1. `AWS_REGION` environment variable
2. `config :ptc_runner, :bedrock_region, "us-east-1"`
3. Default: `"eu-north-1"`

### Streaming

Pass `on_chunk` to receive text chunks in real-time:

```elixir
llm = PtcRunner.LLM.callback("openrouter:anthropic/claude-haiku-4.5")
on_chunk = fn %{delta: text} -> IO.write(text) end

{:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm, on_chunk: on_chunk)
```

When the adapter supports `stream/2`, chunks arrive incrementally. Otherwise `on_chunk`
fires once with the full content (graceful degradation). For agents with tools, `on_chunk`
fires on the final text answer only — tool-calling turns are not streamed.

See `PtcRunner.LLM.callback/2` for details.

## Custom Callback

SubAgent is provider-agnostic. Any function that accepts a request map and returns
`{:ok, content}` or `{:ok, %{content: ..., tokens: ...}}` works:

```elixir
llm = fn %{system: system, messages: messages} ->
  # Call your provider here
  {:ok, "response text"}
end

{:ok, step} = PtcRunner.SubAgent.run("Hello", llm: llm)
```

The request map contains:

| Key | Type | Description |
|-----|------|-------------|
| `system` | `String.t()` | System prompt (include in messages sent to LLM) |
| `messages` | `[map()]` | Conversation history |
| `schema` | `map() \| nil` | JSON Schema for structured output |
| `tools` | `[map()] \| nil` | Tool definitions for tool calling |
| `cache` | `boolean()` | Prompt caching hint |
| `turn` | `integer()` | Current turn number |

The return value shape depends on what the agent needs:

```elixir
# Minimal — text only
{:ok, "response text"}

# With token tracking
{:ok, %{content: "response text", tokens: %{input: 100, output: 50}}}

# With tool calls (when tools are in the request)
{:ok, %{tool_calls: [%{name: "search", args: %{"q" => "test"}}], content: nil, tokens: %{}}}
```

## Writing an Adapter Module

For reuse across your application, implement the `PtcRunner.LLM` behaviour:

```elixir
defmodule MyApp.LLMAdapter do
  @behaviour PtcRunner.LLM

  @impl true
  def call(model, request) do
    messages = [%{role: :system, content: request.system} | request.messages]
    # ... call your provider, return {:ok, %{content: ..., tokens: ...}}
  end

  # Optional — enables streaming via on_chunk
  @impl true
  def stream(model, request) do
    # Return {:ok, stream} where stream emits %{delta: text} and %{done: true, tokens: map()}
    # Or {:error, :streaming_not_supported} to fall back to call/2
  end
end
```

Register it globally:

```elixir
# config/config.exs
config :ptc_runner, :llm_adapter, MyApp.LLMAdapter
```

Then use `PtcRunner.LLM.callback/2` as normal — it delegates to your adapter:

```elixir
llm = PtcRunner.LLM.callback("my-model-name", cache: true)
```

## Framework Integration Examples

The callback interface makes it straightforward to wrap any LLM library.

### Req (Direct HTTP)

Call any OpenAI-compatible API with `Req`:

```elixir
llm = fn %{system: system, messages: messages} ->
  body = %{
    model: "gpt-4.1-mini",
    messages: [%{role: "system", content: system} | messages]
  }

  case Req.post!("https://api.openai.com/v1/chat/completions",
         json: body,
         headers: [{"authorization", "Bearer #{System.get_env("OPENAI_API_KEY")}"}]
       ) do
    %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}} ->
      {:ok, text}

    %{body: body} ->
      {:error, body}
  end
end
```

### LangChain

Wrap [LangChain](https://hexdocs.pm/langchain) chains:

```elixir
llm = fn %{system: system, messages: messages} ->
  {:ok, chain} =
    LangChain.Chains.LLMChain.new(%{
      llm: LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4.1-mini"})
    })

  all_messages =
    [LangChain.Message.new_system!(system)] ++
      Enum.map(messages, fn
        %{role: :user, content: c} -> LangChain.Message.new_user!(c)
        %{role: :assistant, content: c} -> LangChain.Message.new_assistant!(c)
      end)

  case LangChain.Chains.LLMChain.run(chain, %{messages: all_messages}) do
    {:ok, _chain, %LangChain.Message{content: content}} ->
      {:ok, content}

    {:error, reason} ->
      {:error, reason}
  end
end
```

### Bumblebee (Local Models via Nx)

Run models locally with [Bumblebee](https://hexdocs.pm/bumblebee):

```elixir
# Start the serving in your application supervisor
{:ok, _} = Bumblebee.Text.Generation.serving(model_info, tokenizer, generation_config)

llm = fn %{system: system, messages: messages} ->
  prompt = format_chat_prompt(system, messages)

  case Nx.Serving.batched_run(MyApp.LLMServing, prompt) do
    %{results: [%{text: text}]} -> {:ok, text}
    error -> {:error, error}
  end
end
```

### Instructor (Structured Output)

[Instructor](https://hexdocs.pm/instructor) specializes in structured output, which
pairs well with text-mode SubAgents:

```elixir
defmodule MyApp.InstructorAdapter do
  @behaviour PtcRunner.LLM

  @impl true
  def call(model, %{schema: schema} = req) when is_map(schema) do
    messages = [%{role: "system", content: req.system} | req.messages]

    case Instructor.chat_completion(model: model, messages: messages, response_model: schema) do
      {:ok, result} ->
        {:ok, %{content: Jason.encode!(result), tokens: %{}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def call(model, req) do
    # Fall back to plain text generation for non-schema requests
    # ...
  end
end
```

## Adapter Resolution

When you call `PtcRunner.LLM.callback/2` or `PtcRunner.LLM.call/2`, the adapter is
resolved in this order:

1. `config :ptc_runner, :llm_adapter, MyApp.LLMAdapter` — explicit config
2. `PtcRunner.LLM.ReqLLMAdapter` — auto-discovered when `req_llm` is in deps
3. Raises with setup instructions if neither is available

This means adding `{:req_llm, "~> 1.2"}` to your deps is all you need — no config
required.

## See Also

- [Getting Started](subagent-getting-started.md) — First SubAgent walkthrough
- [Structured Output Callbacks](structured-output-callbacks.md) — Schema handling, tool calling, and provider-specific patterns
- `PtcRunner.LLM` — API reference
- `PtcRunner.LLM.ReqLLMAdapter` — Built-in adapter reference
