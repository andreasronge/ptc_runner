# SubAgent Usage Rules

The `PtcRunner.SubAgent` API drives an LLM-controlled agentic loop. Use it
when you want the LLM to plan, call tools, and produce a typed result.

## Two-step pattern (preferred for reuse)

```elixir
agent = PtcRunner.SubAgent.new(
  prompt:    "Find the most expensive product",
  signature: "{name :string, price :float}",
  tools:     %{"list_products" => fn _args -> MyApp.Products.list() end},
  max_turns: 5
)

{:ok, step} = PtcRunner.SubAgent.run(agent, llm: my_llm, context: %{})
```

Use the one-shot string form `SubAgent.run("prompt", opts)` only for trivial
cases — it builds an ephemeral agent with defaults each call.

## Result shape

`SubAgent.run/2` returns `{:ok, %Step{}}` or `{:error, %Step{}}`. **Never
raises** for normal LLM/program failures (`SubAgent.run!/2` does). Public Step
fields you can rely on:

- `step.return` — value returned by `(return ...)` or the last expression in
  single-shot mode.
- `step.fail` — `%{reason: atom, message: binary, ...}` on failure, otherwise `nil`.
- `step.usage` — duration, token, and memory metrics.
- `step.turns` — list of per-turn structs (LLM output, generated program, eval result).
- `step.tool_calls`, `step.pmap_calls` — tool invocation records.
- `step.memory` — final memory map (PTC-Lisp `def`s).
- `step.messages` — full LLM conversation if `collect_messages: true`.
- `step.child_traces`, `step.child_steps` — for nested SubAgentTool calls.

There is no top-level `:trace` field — use `:turns` for execution history,
`:trace_id` / `:parent_trace_id` for telemetry correlation.

## Execution modes (set or inferred)

| Mode | When | Behavior |
|------|------|----------|
| Single-shot | `max_turns: 1`, no tools, `retry_turns: 0` | One LLM call, expression result is the answer; `(return ...)` not needed. |
| Loop | tools present, `max_turns > 1`, or `retry_turns > 0` | Multi-turn until `(return v)` or `(fail r)`; otherwise stops at `max_turns`. |
| Text | `output: :text` | LLM returns text/JSON directly, no PTC-Lisp. Provider's native tool calling is used if `tools:` is set. |

If your agent loops to `max_turns_exceeded` despite producing the right value,
it is almost always missing `(return ...)`. Either drop to `max_turns: 1` or
guide the prompt: `"When done, call (return {:name ..., :price ...})"`.

## App loops and chat UIs

`SubAgent.run/2` is mission-oriented: one prompt, one loop, one result. It does
not create a durable chat session or hidden process-level memory for your app.
For chat-shaped products, keep the transcript and routing logic in your
application, then call `run/2` once per user message with the right contract:

```elixir
history = [%{role: :user, content: "Summarize ticket 123"}]

{:ok, step} =
  PtcRunner.SubAgent.run(
    "Summarize ticket 123",
    output: :text,
    tools: %{"get_ticket" => fn %{"id" => id} -> MyApp.Support.get_ticket(id) end},
    llm: llm,
    max_turns: 4
  )

history = history ++ [%{role: :assistant, content: step.return}]
```

For the next message, decide again: `output: :text` for prose, `output: :text`
plus `signature:` for structured extraction, or default `:ptc_lisp` when the
answer requires deterministic filtering, sorting, aggregation, or date math.
Pass only bounded history through `context:`; don't append the full transcript
forever.

`SubAgent.chat/3` is available when you want PtcRunner to thread `messages` and
PTC-Lisp `memory` between calls:

```elixir
agent = PtcRunner.SubAgent.new(
  prompt: "placeholder",
  output: :text,
  system_prompt: "Answer concisely."
)

{:ok, reply, messages, memory} = PtcRunner.SubAgent.chat(agent, "Hello", llm: llm)
{:ok, reply2, messages2, _memory2} =
  PtcRunner.SubAgent.chat(agent, "Tell me more", llm: llm, messages: messages, memory: memory)
```

Even with `chat/3`, there is no `start` / `send_message` / `close` API. Your app
still owns persistence, history trimming, and which tools/signature/mode apply
to each user message.

## Tools — accepted shapes

**Hard contract:** every tool function is **arity-1** and receives a
**string-keyed** argument map (possibly empty `%{}`). Bare references to
zero-arity or multi-arity functions (`&MyApp.list/0`, `&MyApp.search/2`) will
crash at invocation time — wrap them. The signature/spec auto-extraction
documents the function for the LLM but does **not** rewrite arity at runtime.

Tool map keys are **strings**. Values can be any of:

```elixir
tools = %{
  # Bare function — must already be arity-1 with a map arg
  "list_products" => fn _args -> MyApp.Products.list() end,

  # Function + explicit signature
  "search" => {fn %{"query" => q, "limit" => l} -> MyApp.search(q, l) end,
               "(query :string, limit :int) -> [{id :int}]"},

  # Function + keyword opts (preferred for production)
  "search" => {fn %{"query" => q, "limit" => l} -> MyApp.search(q, l) end,
    signature:   "(query :string, limit :int?) -> [{id :int, title :string}]",
    description: "Search items. Returns up to limit results.",
    cache:       true
  },

  # Module function — wrap to adapt arity
  "get_user" => fn %{"id" => id} -> MyApp.Users.get(id) end
}
```

Tool functions return any Elixir term. Don't raise — return `{:error, reason}`.

`cache: true` is safe only for pure, idempotent tools. Don't use it on tools
that read mutable state another tool might change.

## Signatures

Signatures are short type contracts:

```elixir
"{name :string, price :float}"                       # output only
"(query :string) -> [{id :int, title :string}]"      # input + output
"{count :int, _email_ids [:int]}"                    # firewalled field
```

Effects:

- Sent to the LLM in the system prompt so it knows what shape to return.
- Validated against `step.return` after `(return ...)`. Mismatch → error.
- Fields prefixed with `_` are **firewalled**: returned to your Elixir code
  but stripped from prompt history (use for large opaque data). **PTC-Lisp
  mode only** — the validator rejects firewall fields under `output: :text`.

If the LLM struggles, loosen with `:any` or `?` (optional) before adding retries.

## Validation retries

```elixir
SubAgent.run(agent, llm: llm, retry_turns: 3)
```

`retry_turns` is a separate budget from `max_turns`. After a validation
failure, the agent gets up to `retry_turns` further attempts (with no tools,
just to fix the return shape). Use it only when you've tightened the
signature past what the model reliably hits on the first try.

## LLM callback contract

The `llm:` value is one of:

- **Function** — see input/output below.
- **Model alias string** like `"haiku"`, `"sonnet"`, `"openrouter:..."` —
  resolved via `PtcRunner.LLM.callback/2` (requires `req_llm`).
- **Atom** like `:haiku`, resolved via `llm_registry: %{haiku: fn ... end}`.

**Input:** a map with at least `:system` (binary) and `:messages` (a list of
`%{role: :system|:user|:assistant, content: binary}`).

**Output:** `{:ok, response} | {:error, term}` where `response` is one of:

- A raw `String.t()` — wrapped internally as `%{content: string, tokens: nil}`.
- `%{content: String.t(), tokens: map() | nil}` — the canonical normalized form.
- `%{content: String.t() | nil, tokens: ..., tool_calls: [map()]}` — text-mode
  with provider-native tool calls.

In PTC-Lisp mode `content` should contain a PTC-Lisp program (typically inside a
```` ```clojure ```` fence; raw s-expressions also parse). In text mode, plain
text or JSON.

## PTC-Lisp transport (`ptc_transport`)

For agents in PTC-Lisp mode (`output: :ptc_lisp`, the default), `ptc_transport`
controls how the LLM delivers programs to PtcRunner. Two values:

| Value | Default? | Wire format |
|-------|----------|-------------|
| `:content` | yes | Markdown-fenced PTC-Lisp in the assistant message body. Existing behavior. |
| `:tool_call` | opt-in | Native tool call to a single internal `ptc_lisp_execute` tool. The `program` argument carries the PTC-Lisp source. |

Both transports run programs in the same sandbox and call your app tools the
same way — via `(tool/name ...)` forms inside the program. App tools are
**never** exposed as native provider tools, including in `:tool_call` mode.
Only `ptc_lisp_execute` is. This keeps the sandbox boundary, `max_tool_calls`
budget, tool cache, and `pmap`/`pcalls` semantics identical across transports.

### When to use which

- **`:content`** — *one program, one deterministic orchestration.* Lower
  latency, lower cost, single LLM turn for the typical "fan out to tools,
  filter, aggregate, return" pattern. Stay here unless you have a reason to
  switch.
- **`:tool_call`** — providers/models where native tool calling is materially
  more reliable than fenced-code parsing, **or** workloads that genuinely need
  iterative refinement across multiple program executions (model inspects an
  intermediate result before writing the next program).

`:tool_call` turns one PTC-Lisp program into a ReAct-style loop: the model can
call `ptc_lisp_execute` zero or more times, then return a final answer
directly. That extra round-tripping is a **tradeoff, not an upgrade** — pay
for it deliberately.

### Behavior in `:tool_call` mode

- The LLM may call `ptc_lisp_execute` zero or more times, then return a final
  answer directly as content. Direct final answers are validated against
  `signature:` exactly like `(return v)` in `:content` mode.
- Direct final answers are allowed **before or after** any execution-tool
  calls. A simple prompt the model can answer without computing anything stays
  one turn.
- `(return v)` and `(fail v)` from inside a program still terminate the loop.
- `max_tool_calls` continues to bound *app tools* invoked from inside the
  program. Calls to `ptc_lisp_execute` itself do **not** count against that
  budget — the loop is bounded by `max_turns` and by the rule "exactly one
  `ptc_lisp_execute` call per assistant turn."
- Markdown-fenced PTC-Lisp returned as content is *not* parsed in `:tool_call`
  mode — the model is told to call `ptc_lisp_execute` instead.

### Provider support

`:tool_call` requires a provider/model with native tool calling. Models without
it surface as `:llm_error` with the provider reason; there is no fallback to
`:content`. See [`usage-rules/llm-setup.md`](llm-setup.md#ptc_transport-tool_call-and-provider-tool-calling)
for which built-in providers qualify.

### Examples

```elixir
# :content — default. Same as today, no option needed.
agent = PtcRunner.SubAgent.new(
  prompt: "Find the most expensive product",
  signature: "{name :string, price :float}",
  tools:     %{"list_products" => fn _args -> MyApp.Products.list() end}
)

{:ok, step} = PtcRunner.SubAgent.run(agent, llm: my_llm)
```

```elixir
# :tool_call — opt-in. Pass on the agent struct …
agent = PtcRunner.SubAgent.new(
  prompt:        "Find the most expensive product",
  signature:     "{name :string, price :float}",
  tools:         %{"list_products" => fn _args -> MyApp.Products.list() end},
  ptc_transport: :tool_call
)

# … or as a runtime option on run/2.
{:ok, step} = PtcRunner.SubAgent.run(agent, llm: my_llm, ptc_transport: :tool_call)
```

### Don't

- Don't pass `ptc_transport` together with `output: :text` — raises
  `ArgumentError`. The transport only applies to PTC-Lisp programs.
- Don't define an app tool named `ptc_lisp_execute`. The name is reserved
  globally; the validator rejects it regardless of `ptc_transport`.

For the full decision guide ("when to switch, when to stay") and a runnable
walkthrough, see [PTC-Lisp transport](../docs/guides/subagent-ptc-transport.md).

## Composition

- `SubAgent.as_tool(agent, opts)` turns an agent into a tool another agent can
  call — child agents run with isolated state and their own turn budget.
  **Requires** a description, either `description:` in `opts` or
  `agent.description`; missing both raises `ArgumentError`.
- `SubAgent.compile/2` bakes the LLM-generated PTC-Lisp into a deterministic
  Elixir function for zero-LLM-cost orchestration. **Constraints:**
  `max_turns: 1` and `output: :ptc_lisp` are required — passing a multi-turn
  or text-mode agent raises `ArgumentError` (this is a build-time misuse, not a
  runtime failure). Returns `{:ok, %CompiledAgent{}}` on success or
  `{:error, %Step{}}` if the compilation run itself fails. Pure-Elixir tools and
  `LLMTool`/`SubAgentTool` are supported (the latter still call the LLM at
  execute time).
- `SubAgent.chat/3` threads `messages` and (in `:ptc_lisp` mode) `memory`
  across calls for chat UIs. Prefer application-owned history plus one
  `run/2` call per user message when each turn needs a different output mode,
  signature, or tool surface.

## Don't

- Don't construct `%PtcRunner.SubAgent.Definition{}` directly — use `new/1`.
- Don't read or mutate fields under `PtcRunner.SubAgent.Loop.*`,
  `Compiler`, or `CompiledAgent` — internal API.
- Don't use `Process.sleep/1` in tools or tests; use monitors or
  scripted callbacks.
