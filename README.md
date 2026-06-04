# PtcRunner

[![Hex.pm](https://img.shields.io/hexpm/v/ptc_runner.svg)](https://hex.pm/packages/ptc_runner)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ptc_runner)
[![CI](https://github.com/andreasronge/ptc_runner/actions/workflows/test.yml/badge.svg)](https://github.com/andreasronge/ptc_runner/actions/workflows/test.yml)
[![Hex Downloads](https://img.shields.io/hexpm/dt/ptc_runner.svg)](https://hex.pm/packages/ptc_runner)
[![License](https://img.shields.io/hexpm/l/ptc_runner.svg)](LICENSE)
[![GitHub](https://img.shields.io/badge/GitHub-repo-blue.svg)](https://github.com/andreasronge/ptc_runner)
[![Run in Livebook](https://img.shields.io/badge/Run_in-Livebook-purple)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fandreasronge%2Fptc_runner%2Fmain%2Flivebooks%2Fptc_runner_playground.livemd)
[![Blog](https://img.shields.io/badge/Blog-posts-green)](https://andreasronge.github.io/ptc_runner/)

PtcRunner gives LLM agents a fast, secure, stateful code mode.

> PtcRunner is a 0.x library under active development. Expect bugs, API changes,
> and breaking behavior as the project evolves.

Models write small [PTC-Lisp](docs/ptc-lisp-specification.md) programs.
PtcRunner runs them in a BEAM-native sandbox with process isolation, timeouts,
heap limits, and controlled tool access. Sessions can keep definitions and
intermediate results across calls, so an agent can work in a REPL-like loop
without repeatedly reloading context or restarting a runtime.

Use it over MCP from any language or client, or embed it directly in Elixir.

## Start Here

### Use code mode over MCP

`ptc_runner_mcp` is a standalone MCP server for sandboxed code execution. It
gives MCP-compatible clients and server-side agent runtimes a fast REPL-like
code mode backed by PTC-Lisp. Agents can evaluate programs, keep session state,
call approved tools, aggregate large results, and return compact computed
answers.

Use this when you want code execution for an agent, but do not want generated
code to have direct filesystem, network, package-install, or OS process access.
The server is useful both for local AI clients such as Claude Desktop, Cursor,
Cline, and Claude Code, and for non-Elixir agent applications that want a stable
protocol boundary around the sandbox.

Compared with process-per-call Python or JavaScript execution, PtcRunner keeps
the runtime warm, evaluates small programs inside lightweight BEAM processes,
and can preserve session state across calls.

Start with the [`mcp_server` README](mcp_server/README.md)
for install, setup, client config, and server deployment. See
[`docs/mcp-server.md`](docs/mcp-server.md) for the security model, sessions, and
architecture.

For applications that already run inside Elixir, use the
[`Root Upstream Runtime`](docs/upstream-runtime.md) directly to embed OpenAPI
and MCP upstream tools without starting the MCP server. The MCP server's
[`aggregator mode`](docs/aggregator-mode.md) uses the same upstream config and
`(tool/call ...)` authoring model behind an MCP boundary.

### Build agents in Elixir

Use the `ptc_runner` library when you want SubAgents, signatures, tools, memory,
text mode, PTC-Lisp mode, tracing, composition, and compiled workflows directly
inside an Elixir application.

## Elixir Quick Start

```elixir
# Runnable doctest — uses a mock LLM so it works without API access.
# In production, swap `mock_llm` for `PtcRunner.LLM.callback("haiku")`.
iex> mock_llm = fn _request ->
...>   {:ok, "(->> (tool/get_orders) (filter #(> % data/threshold)) (reduce +))"}
...> end
iex> {:ok, step} = PtcRunner.SubAgent.run(
...>   "Total value of orders over ${{threshold}}",
...>   tools: %{"get_orders" => fn _ -> [1500.0, 950.0, 50.0] end},
...>   context: %{threshold: 100},
...>   llm: mock_llm,
...>   max_turns: 1
...> )
iex> step.return
2450.0
```

The `llm:` option accepts any 1-arity function — for tests, pass an inline lambda
like `mock_llm` above. There is no separate `stub`/`mock` helper. See the
[Testing guide](docs/guides/subagent-testing.md) for scripted callbacks and
integration patterns.

### Embed a stateful PTC-Lisp session

Use `PtcRunner.Session` when your application already owns the chat loop and
only needs REPL-like Lisp state:

```elixir
session = PtcRunner.Session.new(timeout: 1_000)

{{:ok, step}, session} =
  PtcRunner.Session.eval(session, "(def total (+ 1 2))")

step.memory["total"]
#=> 3

{{:ok, step}, session} =
  PtcRunner.Session.eval(session, "(* total 10)")

step.return
#=> 30

{{:ok, step}, _session} =
  PtcRunner.Session.eval(session, "*1")

step.return
#=> 30
```

The session stores explicit `(def ...)` memory and the bounded return history
used by `*1`, `*2`, and `*3` (default depth: 3). Runtime options such as tools,
context, signatures, and timeouts can be stored as session defaults or passed
per eval call. Pass `upstream_runtime: runtime` to evaluate through the root
upstream runtime while keeping the session focused on Lisp state.

**Try it yourself:** The [Getting Started guide](docs/guides/subagent-getting-started.md) includes fully runnable examples you can copy-paste.

The SubAgent doesn't answer directly - it writes a program that computes the answer:

```clojure
(->> (tool/get_orders)
     (filter #(> (:amount %) 100))
     (sum-by :amount))
```

This is [Programmatic Tool Calling](https://www.anthropic.com/engineering/advanced-tool-use): instead of the LLM being the computer, it programs the computer.

## Why PtcRunner?

**LLMs as programmers, not computers.** Most agent frameworks treat LLMs as the runtime. PtcRunner inverts this: LLMs generate programs that execute deterministically in a sandbox. Tool results stay in memory — the LLM explores data through code, exposing only relevant findings. This scales to thousands of items without context limits and eliminates hallucinated counts.

**Best suited for:** Document analysis (agentic RAG), log analysis, data aggregation, multi-source joins — any task where raw data volume would overwhelm an LLM's context window.

### Key Features

- **Secure code mode**: [PTC-Lisp](docs/ptc-lisp-specification.md) executes generated programs in a BEAM-native sandbox with process isolation, timeouts, and heap limits
- **Two agent modes**: PTC-Lisp for multi-turn agentic workflows with tools, or [text mode](docs/guides/subagent-text-mode.md) for direct LLM responses with optional native tool calling
- **Signatures**: Type contracts (`{sentiment :string, score :float}`) that validate outputs and drive auto-retry on mismatch
- **Transactional memory**: `def` persists data across turns without bloating context
- **Composable SubAgents**: Nest agents as tools with isolated state and turn budgets
- **[Recursive agents (RLM)](https://arxiv.org/pdf/2512.24601)**: Agents call themselves via `:self` tools to subdivide large inputs
- **Ad-hoc LLM queries**: `llm-query` calls an LLM from within PTC-Lisp with signature-validated responses
- **Observable**: [Telemetry spans](docs/guides/subagent-observability.md) for every turn, LLM call, and tool call with parent-child correlation. JSONL trace logs with Chrome DevTools flame chart export for debugging multi-agent flows ([interactive Livebook](livebooks/observability_and_tracing.livemd))
- **[Context compaction](docs/guides/subagent-compaction.md)**: Pressure-triggered trimming for long-running multi-turn agents — opt in with `compaction: true` to drop older turns once a turn or token threshold is hit
- **BEAM-native**: Parallel tool calling (`pmap`/`pcalls`), process isolation with timeout and heap limits, fault tolerance
- **MCP server**: Expose the sandbox as code mode over MCP for clients and server-side agents, with optional stateful sessions and [aggregator mode](docs/aggregator-mode.md) for upstream MCP tools

### Examples

**Parallel tool calling** - fetch data concurrently:

```clojure
;; LLM generates this - executes in parallel automatically
(let [[user orders stats] (pcalls #(tool/get_user {:id data/user_id})
                                   #(tool/get_orders {:id data/user_id})
                                   #(tool/get_stats {:id data/user_id}))]
  {:user user :order_count (count orders) :stats stats})
```

**Ad-hoc LLM judgment from code** - the LLM writes programs that call other LLMs, with typed responses and parallel execution:

```clojure
;; LLM generates this - each llm-query runs in parallel via pmap
(pmap (fn [item]
        (tool/llm-query {:prompt "Rate urgency: {{desc}}"
                         :signature "{urgent :bool, reason :string}"
                         :desc (:description item)}))
      data/items)
```

The agent decides *what* to ask and *how* to structure the response — at runtime, from within the generated program. Enable with `llm_query: true`. See the [LLM Agent Livebook](livebooks/ptc_runner_llm_agent.livemd#ad-hoc-llm-queries-llm_query) for a full example.

**Compile SubAgents** - LLM writes the orchestration logic once, execute deterministically:

```elixir
# Orchestrator with SubAgentTools + pure Elixir functions
{:ok, compiled} = SubAgent.compile(orchestrator, llm: my_llm)

# LLM generated: (loop [joke initial, i 1] (if (tool/check ...) (return ...) (recur ...)))

# Execute with zero orchestration cost - only child SubAgents call the LLM
compiled.execute.(%{topic: "cats"}, llm: my_llm)
```

See the [Joke Workflow Livebook](livebooks/joke_workflow.livemd) for a complete example.

### Text Mode

Not every task needs PTC-Lisp. Text mode (`output: :text`) uses the LLM provider's native tool calling API — ideal for smaller models or straightforward tasks:

```elixir
# Plain text — no signature, raw string response
{:ok, step} = SubAgent.run(
  "Summarize this article: {{text}}",
  context: %{text: article},
  output: :text,
  llm: my_llm
)
step.return  #=> "The article discusses..."

# Structured JSON — signature validates the response
{:ok, step} = SubAgent.run(
  "Classify the sentiment of: {{text}}",
  context: %{text: "I love this product!"},
  output: :text,
  signature: "() -> {sentiment :string, score :float}",
  llm: my_llm
)
step.return  #=> %{"sentiment" => "positive", "score" => 0.95}
```

Text mode also supports tools. Define tools as arity-1 functions that receive a map of arguments:

```elixir
defmodule Calculator do
  @doc "Add two numbers"
  @spec add(%{a: integer(), b: integer()}) :: integer()
  def add(%{"a" => a, "b" => b}), do: a + b

  @doc "Multiply two numbers"
  @spec multiply(%{a: integer(), b: integer()}) :: integer()
  def multiply(%{"a" => a, "b" => b}), do: a * b
end
```

PtcRunner auto-extracts the `@doc` and `@spec` into tool descriptions and JSON Schema for the LLM provider's native tool calling API — just pass bare function references:

```elixir
{:ok, step} = SubAgent.run(
  "What is (3 + 4) * 5?",
  output: :text,
  signature: "() -> {result :int}",
  tools: %{
    "add" => &Calculator.add/1,
    "multiply" => &Calculator.multiply/1
  },
  llm: my_llm
)
step.return["result"]  #=> 35
```

For full control (or anonymous functions), pass an explicit signature string instead. See the [Text Mode guide](docs/guides/subagent-text-mode.md) for all four variants (plain text, JSON, tool+text, tool+JSON).

### PTC-Lisp Transport (`ptc_transport`)

For `output: :ptc_lisp` agents, `ptc_transport` controls how the LLM ships its program. `:content` (default) parses a markdown-fenced PTC-Lisp block from the assistant message — *one program, one deterministic orchestration*, lower latency and cost in a single LLM turn. `:tool_call` (opt-in) exposes a single internal `lisp_eval` tool to the provider's native tool-calling API; the model can call it zero or more times before returning a final answer directly. App tools stay inside PTC-Lisp in **both** transports — only `lisp_eval` is exposed natively.

| Transport | Default? | Use when |
|-----------|----------|----------|
| `:content` | yes | One PTC-Lisp program is enough. Lowest latency and cost. |
| `:tool_call` | opt-in | Native tool calling is materially more reliable than fenced-code parsing on your provider/model, **or** the workload genuinely needs iterative refinement across multiple program executions. |

`:tool_call` turns one program into a ReAct-style loop: that's a tradeoff, not an upgrade. Pay for it deliberately. Models without native tool calling cannot use `:tool_call` — those runs surface as `:llm_error`, with no fallback. See the [PTC-Lisp Transport guide](docs/guides/subagent-ptc-transport.md) for the full decision and a runnable walkthrough.

### Signatures and JSON Schema

Signatures are compact type contracts that validate SubAgent inputs and outputs:

```
"(query :string, limit :int) -> {total :float, items [{id :int, name :string}]}"
```

Under the hood, PtcRunner converts signatures to **JSON Schema** in two places:

| Where | When | Purpose |
|-------|------|---------|
| **Tool definitions** | Text mode with tools | Tool signatures → JSON Schema parameters sent to the LLM provider's native tool calling API |
| **Structured output** | Text mode with complex return type | Return signature → JSON Schema passed to the LLM callback for provider-specific structured output (e.g., OpenAI `response_format`) |

In PTC-Lisp mode, signatures stay in their compact form — the LLM sees them in the prompt and PtcRunner validates the result directly. JSON Schema is only generated when interfacing with LLM provider APIs that require it.

Auto-extraction from `@spec` means you can define tools as regular Elixir functions and skip writing signatures by hand. For full control, pass an explicit signature string:

```elixir
"search" => {&MyApp.search/2, signature: "(query :string, limit :int) -> [{id :int}]"}
```

See [Signature Syntax](docs/signature-syntax.md) for the full type reference.

## Installation

```elixir
def deps do
  [
    {:ptc_runner, "~> 0.12.0"},
    {:req_llm, "~> 1.8"}  # optional — enables built-in LLM adapter
  ]
end
```

With `req_llm` installed, create LLM callbacks with zero configuration:

```elixir
llm = PtcRunner.LLM.callback("openrouter:anthropic/claude-haiku-4.5")

# or with prompt caching
llm = PtcRunner.LLM.callback("bedrock:haiku", cache: true)
```

`PtcRunner.LLM.callback/2` routes by model prefix (`openrouter:`, `bedrock:`, `anthropic:`, `ollama:`, etc.) and handles structured output, tool calling, and prompt caching. See the [LLM Setup guide](docs/guides/subagent-llm-setup.md) for all providers, streaming, custom adapters, and framework integration.

## Documentation

### Guides

- **[Getting Started](docs/guides/subagent-getting-started.md)** - Build your first SubAgent
- **[LLM Setup](docs/guides/subagent-llm-setup.md)** - Providers, streaming, custom adapters, framework integration
- **[Core Concepts](docs/guides/subagent-concepts.md)** - Context and memory
- **[PTC-Lisp Transport](docs/guides/subagent-ptc-transport.md)** - `ptc_transport: :content` (default) vs `:tool_call` (opt-in)
- **[Text Mode + PTC-Lisp Compute](docs/guides/text-mode-ptc-compute.md)** - Combined mode (`output: :text, ptc_transport: :tool_call`) for chat agents that escalate to deterministic compute
- **[Patterns](docs/guides/subagent-patterns.md)** - Chaining, orchestration, and composition
- **[Root Upstream Runtime](docs/upstream-runtime.md)** - Embed OpenAPI/MCP upstream tools in Elixir callers or `mix ptc.repl`
- **[MCP Aggregator Mode](docs/aggregator-mode.md)** - Expose the same upstream runtime through `ptc_runner_mcp`
- **[Testing](docs/guides/subagent-testing.md)** - Mocking LLMs and integration testing
- **[Troubleshooting](docs/guides/subagent-troubleshooting.md)** - Common issues and solutions
- **[MCP Getting Started](docs/guides/mcp-getting-started.md)** - Using `ptc_runner_mcp` from MCP clients or server-side agent runtimes (overview: [`docs/mcp-server.md`](docs/mcp-server.md))

### Reference

- **[Signature Syntax](docs/signature-syntax.md)** - Input/output type contracts
- **[PTC-Lisp Specification](docs/ptc-lisp-specification.md)** - The language SubAgents write (a Clojure subset: 211 of 534 `clojure.core` vars, plus `clojure.string`, `clojure.set`, `clojure.walk`, and `java.lang.Math`)
- **[Namespace Conformance](https://github.com/andreasronge/ptc_runner/blob/main/docs/conformance/index.md)** - Generated coverage index for supported Clojure namespaces, Java compatibility targets, and PTC-specific extensions
- **[Function Reference](docs/function-reference.md)** - All built-in functions with signatures
- **Clojure Conformance** - [Gaps](docs/clojure-conformance-gaps.md) | [Java Interop](docs/java-interop.md)
- **[Benchmark Evaluation](docs/benchmark-eval.md)** - LLM accuracy by model

PTC-Lisp follows Clojure where that is safe and bounded. Intentional divergences favor sandbox safety and recoverable signal values for Clojure-named helpers; Java-named dot methods keep Java semantics.

### Interactive

- **`mix ptc.repl`** - Interactive REPL for testing PTC-Lisp expressions
- **[Playground Livebook](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_playground.livemd)** - Try PTC-Lisp interactively
- **[LLM Agent Livebook](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_llm_agent.livemd)** - Build an agent end-to-end
- **[Output Modes in an App Loop](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Foutput_modes_in_app_loops.livemd)** - Pick `:text` plain, `:text` structured, or `:ptc_lisp` per user message in a chat-shaped app
- **[Examples](https://github.com/andreasronge/ptc_runner/tree/main/examples)** - Runnable example applications including [Wire Transfer](https://github.com/andreasronge/ptc_runner/tree/main/examples/wire_transfer) (human-in-the-loop workflow)
- **[Blog](https://andreasronge.github.io/ptc_runner/)** - Articles and updates

## Trace Viewer

A built-in web UI for browsing execution traces with turn-by-turn drill-down:

```bash
mix ptc.viewer --trace-dir traces
```

See [Observability Guide](docs/guides/subagent-observability.md#interactive-trace-viewer) for details.

## Low-Level API

For direct program execution without the agentic loop:

```elixir
{:ok, step} = PtcRunner.Lisp.run(
  "(->> data/items (filter :active) (count))",
  context: %{items: items}
)
step.return  #=> 3
```

Programs run in isolated BEAM processes with resource limits (1s timeout, 10MB heap).

See `PtcRunner.Lisp` module docs for options.

## License

MIT. This license applies to the repository, including the MCP server in
`mcp_server/`.
