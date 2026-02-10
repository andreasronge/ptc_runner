# LLMClient

Unified LLM client for local and cloud providers. Shared between PtcRunner demo, tests, and livebooks.

## Installation

Add as a path dependency:

```elixir
{:llm_client, path: "../llm_client"}
```

## Usage

```elixir
messages = [%{role: :user, content: "Hello!"}]

# Using model aliases (uses default provider)
{:ok, response} = LLMClient.generate_text("haiku", messages)

# Explicit provider with alias
{:ok, response} = LLMClient.generate_text("bedrock:haiku", messages)
{:ok, response} = LLMClient.generate_text("openrouter:haiku", messages)

# Direct model ID
{:ok, response} = LLMClient.generate_text("openrouter:anthropic/claude-haiku-4.5", messages)

# Local Ollama model
{:ok, response} = LLMClient.generate_text("ollama:deepseek-coder:6.7b", messages)

# Check availability
LLMClient.available?("bedrock:haiku")  # => true if AWS credentials set
```

## Providers

| Prefix | Provider | Example |
|--------|----------|---------|
| `ollama:` | Local Ollama | `ollama:deepseek-coder:6.7b` |
| `openai-compat:` | OpenAI-compatible API | `openai-compat:http://localhost:1234/v1\|model` |
| `openrouter:` | OpenRouter | `openrouter:anthropic/claude-haiku-4.5` |
| `bedrock:` | AWS Bedrock | `bedrock:haiku` |
| `anthropic:` | Anthropic direct | `anthropic:claude-3-haiku-20240307` |
| `openai:` | OpenAI direct | `openai:gpt-4.1-mini` |
| `google:` | Google direct | `google:gemini-2.5-flash` |

## Model Aliases

Aliases map to provider-specific model IDs. Use `provider:alias` syntax:

| Alias | OpenRouter | Bedrock |
|-------|------------|---------|
| `haiku` | `anthropic/claude-haiku-4.5` | `anthropic.claude-haiku-4-5-20251001-v1:0` |
| `sonnet` | `anthropic/claude-sonnet-4` | `anthropic.claude-sonnet-4-20250514-v1:0` |
| `qwen-coder` | ❌ Not available | `qwen.qwen3-coder-30b-a3b-v1:0` |
| `qwen-coder-480b` | ❌ Not available | `qwen.qwen3-coder-480b-a35b-v1:0` |
| `gemini` | `google/gemini-2.5-flash` | ❌ Not available |
| `deepseek` | `deepseek/deepseek-chat-v3-0324` | ❌ Not available |
| `gpt` | `openai/gpt-4.1-mini` | ❌ Not available |

Local aliases (Ollama only): `deepseek-local`, `qwen-local`, `llama-local`

Use `LLMClient.presets/1` to get aliases for a specific provider.

## Options

```elixir
# Prompt caching — reduces cost and latency for repeated context
{:ok, response} = LLMClient.generate_text("bedrock:haiku", messages, cache: true)
```

| Option | Default | Description |
|--------|---------|-------------|
| `cache` | `false` | Enable prompt caching (Anthropic, OpenRouter Anthropic, Bedrock Claude). Uses 5-min ephemeral cache. Cache hits charged at ~10% of normal input token rate. |
| `receive_timeout` | `120_000` | Request timeout in milliseconds |

## Configuration

### Default Provider

Set the default provider used when no prefix is specified:

```bash
export LLM_DEFAULT_PROVIDER=bedrock  # or openrouter (default)
```

Or in Elixir config:

```elixir
config :llm_client, :default_provider, :bedrock
```

### Environment Variables

| Provider | Environment Variables |
|----------|----------------------|
| OpenRouter | `OPENROUTER_API_KEY` |
| Bedrock | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` |
| Anthropic | `ANTHROPIC_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Google | `GOOGLE_API_KEY` |

### AWS Bedrock Region

Bedrock region is determined in this order:
1. `AWS_REGION` environment variable
2. `config :llm_client, :bedrock_region, "region-name"`
3. Default: `eu-north-1`

Some models (like `qwen-coder-480b`) are only available in specific regions.

### AWS Bedrock with SSO

For local development with AWS SSO:

```bash
aws sso login --profile sandbox
eval $(aws configure export-credentials --profile sandbox --format env)
iex -S mix
```

## GitHub Actions

See `infrastructure/` for CloudFormation template to set up OIDC authentication for GitHub Actions with Bedrock.

## License

MIT
