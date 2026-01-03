# LLMClient

Unified LLM client for local and cloud providers. Shared between PtcRunner demo, tests, and livebooks.

## Installation

Add as a path dependency:

```elixir
{:llm_client, path: "../llm_client"}
```

## Usage

```elixir
# Generate text with a cloud model
messages = [%{role: :user, content: "Hello!"}]
{:ok, response} = LLMClient.generate_text("openrouter:anthropic/claude-haiku-4.5", messages)
response.content  # => "Hi there!"
response.tokens   # => %{input: 10, output: 5}

# Use model aliases
{:ok, model_id} = LLMClient.resolve("haiku")
{:ok, response} = LLMClient.generate_text(model_id, messages)

# Local Ollama model
{:ok, response} = LLMClient.generate_text("ollama:deepseek-coder:6.7b", messages)

# Check availability
LLMClient.available?("ollama:deepseek-coder:6.7b")  # => true if Ollama running
LLMClient.requires_api_key?("ollama:model")          # => false
LLMClient.requires_api_key?("openrouter:model")      # => true
```

## Providers

| Prefix | Provider | Example |
|--------|----------|---------|
| `ollama:` | Local Ollama | `ollama:deepseek-coder:6.7b` |
| `openai-compat:` | OpenAI-compatible API | `openai-compat:http://localhost:1234/v1\|model` |
| `openrouter:` | OpenRouter | `openrouter:anthropic/claude-haiku-4.5` |
| `anthropic:` | Anthropic direct | `anthropic:claude-haiku-4.5` |
| `openai:` | OpenAI direct | `openai:gpt-4.1-mini` |
| `google:` | Google direct | `google:gemini-2.5-flash` |

## Model Aliases

Built-in aliases for common models:

| Alias | Model ID |
|-------|----------|
| `haiku` | `openrouter:anthropic/claude-haiku-4.5` |
| `sonnet` | `openrouter:anthropic/claude-sonnet-4` |
| `gemini` | `openrouter:google/gemini-2.5-flash` |
| `deepseek` | `openrouter:deepseek/deepseek-chat-v3-0324` |
| `deepseek-local` | `ollama:deepseek-coder:6.7b` |
| `qwen-local` | `ollama:qwen2.5-coder:7b` |
| `llama-local` | `ollama:llama3.2:3b` |

Use `LLMClient.presets/0` to get all aliases.

## Environment Variables

For cloud providers, set the appropriate API key:

- `OPENROUTER_API_KEY` - OpenRouter (recommended, supports many models)
- `ANTHROPIC_API_KEY` - Anthropic direct
- `OPENAI_API_KEY` - OpenAI direct
- `GOOGLE_API_KEY` - Google direct

## License

MIT
