# LLM Setup Usage Rules

PtcRunner does not ship its own HTTP client. The built-in adapter is provided
by the **optional** `req_llm` dependency. If you don't add it, you must pass
your own callback function.

## Recommended: req_llm + model alias

```elixir
# mix.exs
{:req_llm, "~> 1.8"}
```

```elixir
# direct alias — cheapest path
{:ok, step} = PtcRunner.SubAgent.run("What's 2+2?", llm: "haiku")

# explicit provider:model with options
llm = PtcRunner.LLM.callback("openrouter:anthropic/claude-haiku-4.5", cache: true)
{:ok, step} = PtcRunner.SubAgent.run(agent, llm: llm)

# Bedrock, Anthropic direct, OpenAI, Ollama also supported via prefix
llm = PtcRunner.LLM.callback("bedrock:haiku", cache: true)
```

Required env vars depend on provider — typically one of `OPENROUTER_API_KEY`,
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, or AWS credentials for Bedrock.

## Atom + registry (for swappable models per environment)

```elixir
registry = %{
  haiku:  fn input -> MyApp.LLM.haiku(input) end,
  sonnet: fn input -> MyApp.LLM.sonnet(input) end
}

PtcRunner.SubAgent.run(agent, llm: :sonnet, llm_registry: registry)
```

The registry is inherited by child SubAgents — pass it once at the top level.

## Custom callback

The most general form. The `llm:` value is any 1-arity function.

**Input** (map): `:system` (binary) and `:messages` (list of
`%{role: :user|:assistant|:system, content: binary}`). Other keys may be
present (e.g. `:tools`); ignore unknown keys.

**Output** — return any of these shapes inside `{:ok, _}`:

```elixir
{:ok, "raw string"}                                            # wrapped to %{content: ..., tokens: nil}
{:ok, %{content: "...", tokens: %{input: 12, output: 34}}}     # canonical
{:ok, %{content: nil, tokens: %{}, tool_calls: [%{...}]}}      # text-mode native tools
{:error, term}                                                 # propagated to step.fail
```

Example:

```elixir
llm = fn %{system: system, messages: messages} ->
  case MyApp.LLM.call(system, messages) do
    {:ok, text}     -> {:ok, text}        # raw string is fine
    {:error, _} = e -> e
  end
end
```

In PTC-Lisp mode the `content` should contain a PTC-Lisp program (in a
```` ```clojure ```` fence or as a raw s-expression). In text mode, plain text
or JSON.

## Custom adapter behaviour

To plug a non-`req_llm` provider into `PtcRunner.LLM.callback/2`, implement
the behaviour and configure it:

```elixir
defmodule MyApp.LLMAdapter do
  @behaviour PtcRunner.LLM

  @impl true
  def call(model, request) do
    # request: %{system: binary, messages: [...], ...}
    # must return {:ok, %{content: binary, tokens: map() | %{}}} | {:error, term}
    {:ok, %{content: "...", tokens: %{input: 0, output: 0}}}
  end

  @impl true
  def stream(model, request), do: ...   # optional
end

# config/config.exs
config :ptc_runner, :llm_adapter, MyApp.LLMAdapter
```

The behaviour requires the **map** return shape (not a bare string). Bare-string
returns are only accepted from anonymous-function callbacks passed via
`llm:` — see "Custom callback" above.

## Streaming

```elixir
on_chunk = fn %{delta: text} -> send(parent, {:chunk, text}) end
PtcRunner.SubAgent.run(agent, llm: llm, on_chunk: on_chunk)
```

Streaming is supported only when the underlying adapter implements `stream/2`
(`req_llm` does). The `on_chunk` callback receives delta chunks
(`%{delta: text}`) — final-chunk metadata like `:done`/`:tokens` is collected
internally rather than forwarded as an `on_chunk` event. For raw stream events
(including `%{done: true, tokens: ...}`), call `PtcRunner.LLM.stream/2`
directly instead of going through `SubAgent.run/2`. See the Phoenix Streaming
guide for a full LiveView example.

## Retries on transient failures

```elixir
PtcRunner.SubAgent.run(agent,
  llm: llm,
  llm_retry: %{
    max_attempts:     3,
    backoff:          :exponential,
    base_delay:       1000,
    retryable_errors: [:rate_limit, :timeout, :server_error]
  }
)
```

`llm_retry` covers **infrastructure** retries (rate limits, network errors).
`retry_turns` is unrelated — it's for **validation** retries after the LLM's
return value fails the signature.

## Don't

- Don't call `PtcRunner.LLM.callback/2` unless `req_llm` is in deps **or**
  you've configured a custom adapter (`config :ptc_runner, :llm_adapter, MyAdapter`).
  Without one of those, adapter resolution fails. Anonymous function callbacks
  passed via `llm:` work regardless.
- Don't build LLM clients on top of `Req` directly inside ptc_runner code paths.
  Either use `req_llm` or implement the `PtcRunner.LLM` behaviour.
- Don't pin model IDs in your prompts (e.g. "you are claude-3-5-sonnet"); pass
  the model via `llm:` and let the system prompt stay model-agnostic.
- Don't read API keys at compile time (`@api_key System.get_env(...)`). Read
  them at runtime so test environments can override.
