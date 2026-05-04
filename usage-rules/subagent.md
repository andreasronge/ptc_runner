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
  across calls for chat UIs.

## Don't

- Don't construct `%PtcRunner.SubAgent.Definition{}` directly — use `new/1`.
- Don't read or mutate fields under `PtcRunner.SubAgent.Loop.*`,
  `Compiler`, or `CompiledAgent` — internal API.
- Don't use `Process.sleep/1` in tools or tests; use monitors or
  scripted callbacks.
