# PTC-Lisp Transport (`:content` vs `:tool_call`)

For agents in PTC-Lisp mode (`output: :ptc_lisp`, the default), the
`ptc_transport` option controls *how* the LLM ships its program to PtcRunner.
Both transports run programs in the same sandbox, with the same
`(tool/name ...)` namespace for app tools and the same memory / journal /
signature semantics. They differ only in how the program crosses the wire.

```elixir
# Default — :content. No option needed.
SubAgent.new(prompt: "...", tools: tools)

# Opt in — :tool_call. Same agent shape, different wire format.
SubAgent.new(prompt: "...", tools: tools, ptc_transport: :tool_call)
```

## TL;DR

| Transport | Default? | Wire format | Pick when |
|-----------|----------|-------------|-----------|
| `:content` | yes | Markdown-fenced PTC-Lisp in assistant message | One program is enough. Lowest latency, lowest cost, single LLM turn. |
| `:tool_call` | opt-in | Native call to one internal `ptc_lisp_execute` tool whose `program` arg is the source | Native tool calling is materially more reliable than fenced-code parsing on this provider/model, or the workload truly needs iterative refinement. |

`:content` is the default and stays the default in this release. `:tool_call`
is opt-in. Neither replaces the other.

## How each transport works

### `:content` (default)

The LLM responds with a single markdown-fenced PTC-Lisp block in the assistant
message. PtcRunner parses it and runs it in the sandbox. Tools registered on
the agent are available as `(tool/name ...)` from inside the program.
Typically one LLM turn produces one program that does everything: fan out to
tools, filter, aggregate, return.

This is the *one program, one deterministic orchestration* shape. It is
predictable, cacheable, and almost always cheaper than tool-call mode for the
same workload.

### `:tool_call` (opt-in)

PtcRunner exposes exactly one provider-native tool, `ptc_lisp_execute`, whose
single argument is the PTC-Lisp source string. App tools are **not** exposed
as native tools — only `ptc_lisp_execute` is. App tools remain available
inside the sandboxed program as `(tool/name ...)`, identically to
`:content` mode.

Per assistant turn, the LLM may:

- Call `ptc_lisp_execute` once. PtcRunner runs the program, returns the result
  as a tool-result message, and the loop continues to the next turn.
- Return a final answer directly as content (no tool call). PtcRunner
  validates the answer against `signature:` exactly like `(return v)` would.
  Direct final answers are allowed **before or after** any execution-tool
  calls — a simple prompt the model can answer without computation stays one
  turn.
- Call `(return v)` or `(fail v)` from inside a program to terminate
  immediately, with the final tool result paired against the originating
  call.

`:tool_call` therefore turns one PTC-Lisp program into a ReAct-style loop: the
model calls `ptc_lisp_execute` zero or more times, looks at intermediate
results, and writes the next program (or the final answer). That extra
round-tripping is a **tradeoff, not an upgrade**.

## Why app tools stay inside PTC-Lisp

The most common question on first read of `:tool_call` is "why not just expose
my app tools natively?" The deliberate two-layer model is:

| Layer | What it is | How the LLM invokes it |
|-------|------------|------------------------|
| Provider-native | Exactly one tool: `ptc_lisp_execute`. | Native function-calling on the LLM provider. |
| PTC-Lisp | All app tools registered on the agent. | From inside a PTC-Lisp program: `(tool/name ...)`. |

Keeping app tools inside the sandbox preserves the guarantees PtcRunner exists
to provide:

- **Determinism and observability.** Every app-tool invocation is traced,
  cacheable (`cache: true`), bounded by `max_tool_calls`, and re-entrant under
  `task` / journaling.
- **Parallel execution.** `(pmap ...)` and `(pcalls ...)` fan out app tools in
  parallel inside one program. Native provider tool calling gives you neither
  the parallel primitive nor the deterministic ordering.
- **One transcript shape.** Whatever transport you pick, the program is the
  same and the trace is the same. Only the program-delivery wire changes.

If you want native-only tool calling without PTC-Lisp at all, that's
`output: :text` with `tools:`. See [Text Mode](subagent-text-mode.md). It's a
different product, not a different transport.

## Choosing a transport

### Stay on `:content` (default) when

- You don't have a specific reason to switch. `:content` works on every
  provider PtcRunner supports, including providers without native tool
  calling.
- Cost and latency matter. One LLM turn is cheaper than two, and `:content`
  hits one turn for the typical "fan out + aggregate + return" shape.
- The model reliably emits a single fenced block. Modern Anthropic, OpenAI,
  and capable openrouter-hosted models do this well in PtcRunner's default
  prompt.
- Your workload doesn't actually need to *look at* an intermediate result
  before writing the next program — you can plan the whole program up front.

### Consider `:tool_call` when

- The provider/model you're locked into is materially more reliable at native
  tool calling than at "emit exactly one fenced clojure block." Some smaller
  models follow tool-calling schemas more reliably than they follow
  output-format instructions.
- The workload genuinely needs iterative refinement across multiple program
  executions: write program → inspect result → write next program → ... → return.
  This is a real ReAct pattern that doesn't compress into one program. It
  exists, but it's rarer than people think.
- You want to compare `:content` vs `:tool_call` on a real workload of your
  own (turn count, cost, error rate) before standardizing on one. Both are
  supported indefinitely; pick on data, not preference.

### Why "tool calling is more native, therefore better" is wrong

It is tempting to read `:tool_call` as the modern, production-grade option and
`:content` as the legacy fenced-code path. That framing is incorrect.

- **`:content` is not legacy.** It is the default, and stays the default in
  this release. PtcRunner's whole value proposition — *the LLM writes a
  program, the runtime executes it deterministically* — works equally well in
  either transport.
- **`:tool_call` is not magic.** It does *not* improve the program, the
  sandbox, or the tool surface. It only changes how the program string is
  delivered.
- **`:tool_call` adds turns.** A workload that takes one turn in `:content`
  often takes two or three in `:tool_call` (call `ptc_lisp_execute`, get
  result, return final answer). Pay for the extra turns deliberately.
- **`:tool_call` can hurt reliability on capable models.** Models that
  already emit fenced code cleanly (e.g., recent Anthropic) sometimes do
  *worse* on `:tool_call`: the loop encourages them to fragment one-program
  work into multiple `ptc_lisp_execute` calls, replan between turns, or
  embed the answer in conversational prose. This is not hypothetical —
  measure before switching.
- **Each `:tool_call` turn re-ships the `ptc_lisp_execute` schema.**
  In practice that's ~800 input tokens of overhead per turn. On simple
  workloads, this can dominate the total prompt cost.

### Empirical note (one small benchmark)

A 7-query demo suite — 3 in-memory queries, 4 multi-turn search/fetch
queries — run 5 times per cell:

| Model | `:content` pass | `:tool_call` pass | `:content` wall | `:tool_call` wall | `:tool_call` input tokens |
|---|:---:|:---:|:---:|:---:|:---:|
| Claude Haiku 4.5 | 34/35 | **27/35** | 94 s | 162 s | **+162 %** |
| Gemini 3.1 Flash Lite | 35/35 | 34/35 | 69 s | 61 s | +58 % |

Reading the table:

- On Haiku, `:tool_call` dropped pass rate (97 % → 77 %) and roughly doubled
  latency. `:content` is the right default here.
- On Gemini Flash Lite, pass rates were close. `:tool_call` was ~26 %
  *faster* on the multi-turn tool queries but ~25 % *slower* on the simple
  in-memory queries, and always cost more input tokens.
- The right transport depends on **(model × workload)**, not just model.
  One small benchmark on one suite is not a universal recommendation —
  reproduce the comparison on your own workload before standardizing.

## Provider compatibility

`:tool_call` requires a provider/model with native tool calling. If you call a
non-tool-calling model with `ptc_transport: :tool_call`, the run surfaces as
`{:error, %Step{}}` with `step.fail.reason == :llm_error` and the provider's
own reason string in `step.fail.message`. **There is no automatic fallback to
`:content`.**

Common cases:

- **Most Anthropic and OpenAI models** — supported.
- **Bedrock-hosted Anthropic / supported OpenAI variants** — supported.
- **OpenRouter** — supported when the upstream model itself supports tool
  calling. PtcRunner passes through whatever the upstream offers.
- **Ollama** — generally not supported.
- **`openai-compat:` endpoints without tool calling** — not supported.

When in doubt, leave `ptc_transport` at its default. See
[`usage-rules/llm-setup.md`](../../usage-rules/llm-setup.md#ptc_transport-tool_call-and-provider-tool-calling)
for the per-provider table and the failure surface.

## Don't

- Don't pass `ptc_transport` together with `output: :text` — raises
  `ArgumentError`. The transport only applies to PTC-Lisp programs.
- Don't define an app tool named `ptc_lisp_execute`. The name is reserved
  globally; the validator rejects it regardless of `ptc_transport`.
- Don't switch transports mid-conversation. `ptc_transport` is part of the
  agent contract; pick once per agent and stay there.

## See also

- [SubAgent usage rules — PTC-Lisp transport](../../usage-rules/subagent.md#ptc-lisp-transport-ptc_transport)
- [LLM setup — provider compatibility](../../usage-rules/llm-setup.md#ptc_transport-tool_call-and-provider-tool-calling)
- [Output Modes in an App Loop livebook](../../livebooks/output_modes_in_app_loops.livemd) —
  runnable walkthrough that demos `:content` and `:tool_call` over the same
  scenario.
- [Troubleshooting](subagent-troubleshooting.md#ptc_transport-tool_call-issues) —
  failure modes specific to `:tool_call`.
