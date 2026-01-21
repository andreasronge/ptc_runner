# PtcRunner

[![Hex.pm](https://img.shields.io/hexpm/v/ptc_runner.svg)](https://hex.pm/packages/ptc_runner)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ptc_runner)
[![CI](https://github.com/andreasronge/ptc_runner/actions/workflows/test.yml/badge.svg)](https://github.com/andreasronge/ptc_runner/actions/workflows/test.yml)
[![Hex Downloads](https://img.shields.io/hexpm/dt/ptc_runner.svg)](https://hex.pm/packages/ptc_runner)
[![License](https://img.shields.io/hexpm/l/ptc_runner.svg)](LICENSE)
[![GitHub](https://img.shields.io/badge/GitHub-repo-blue.svg)](https://github.com/andreasronge/ptc_runner)
[![Run in Livebook](https://img.shields.io/badge/Run_in-Livebook-purple)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fandreasronge%2Fptc_runner%2Fmain%2Flivebooks%2Fptc_runner_playground.livemd)

Build LLM agents that write and execute programs. SubAgents combine the reasoning power of LLMs with the computational precision of a sandboxed interpreter.

## Quick Start

```elixir
# Conceptual example - see Getting Started guide for runnable code
{:ok, step} = PtcRunner.SubAgent.run(
  "What's the total value of orders over $100?",
  tools: %{"get_orders" => &MyApp.Orders.list/0},
  signature: "{total :float}",
  llm: my_llm
)

step.return.total  #=> 2450.00
```

**Try it yourself:** The [Getting Started guide](docs/guides/subagent-getting-started.md) includes fully runnable examples you can copy-paste.

The SubAgent doesn't answer directly - it writes a program that computes the answer:

```clojure
(->> (tool/get_orders)
     (filter #(> (:amount %) 100))
     (sum-by :amount))
```

This is [Programmatic Tool Calling](https://www.anthropic.com/engineering/advanced-tool-use): instead of the LLM being the computer, it programs the computer.

## Why PtcRunner?

**LLMs as programmers, not computers.** Most agent frameworks treat LLMs as the runtime. PtcRunner inverts this: LLMs generate programs that execute deterministically in a sandbox.

### BEAM-Native Advantages

- **Parallel tool calling**: `pmap`/`pcalls` execute I/O concurrently using lightweight BEAM processes
- **Process isolation**: Each execution runs in a sandboxed process with timeout and heap limits
- **Fault tolerance**: Crashes don't propagate; built-in supervision patterns

### Safe Lisp DSL

- **LLM-friendly**: Minimal syntax, easy to generate correctly
- **Safe by construction**: No side effects, no system access, bounded iteration
- **Inspectable**: Debug by examining generated programs

### Unique Features

- **Context firewall**: `_` prefixed fields stay in BEAM memory, hidden from LLM prompts
- **Transactional memory**: `def` persists data across turns without bloating context
- **Composable SubAgents**: Nest agents as tools with isolated state and turn budgets
- **Type-driven retry**: Signatures validate outputs; agents auto-correct on mismatch

### Examples

**Parallel tool calling** - fetch data concurrently:

```clojure
;; LLM generates this - executes in parallel automatically
(let [[user orders stats] (pcalls #(tool/get_user {:id data/user_id})
                                   #(tool/get_orders {:id data/user_id})
                                   #(tool/get_stats {:id data/user_id}))]
  {:user user :order_count (count orders) :stats stats})
```

**Context firewall** - keep large data out of LLM prompts:

```elixir
# The LLM sees: %{summary: "Found 3 urgent emails"}
# Elixir gets: %{summary: "...", _email_ids: [101, 102, 103]}
signature: "{summary :string, _email_ids [:int]}"
```

**Compile SubAgents** - LLM writes the orchestration logic once, execute deterministically:

```elixir
# Orchestrator with SubAgentTools + pure Elixir functions
{:ok, compiled} = SubAgent.compile(orchestrator, llm: my_llm)

# LLM generated: (loop [joke initial, i 1] (if (tool/check ...) (return ...) (recur ...)))

# Execute with zero orchestration cost - only child SubAgents call the LLM
compiled.execute.(%{topic: "cats"}, llm: my_llm)
```

See the [Joke Workflow Livebook](livebooks/joke_workflow.livemd) for a complete example.

## Installation

```elixir
def deps do
  [{:ptc_runner, "~> 0.5.0"}]
end
```

## Documentation

### Guides

- **[Getting Started](docs/guides/subagent-getting-started.md)** - Build your first SubAgent
- **[Core Concepts](docs/guides/subagent-concepts.md)** - Context, memory, and the firewall convention
- **[Patterns](docs/guides/subagent-patterns.md)** - Chaining, orchestration, and composition
- **[Testing](docs/guides/subagent-testing.md)** - Mocking LLMs and integration testing
- **[Troubleshooting](docs/guides/subagent-troubleshooting.md)** - Common issues and solutions

### Reference

- **[Signature Syntax](docs/signature-syntax.md)** - Input/output type contracts
- **[PTC-Lisp Specification](docs/ptc-lisp-specification.md)** - The language SubAgents write
- **[Benchmark Evaluation](docs/benchmark-eval.md)** - LLM accuracy by model

### Interactive

- **`mix ptc.repl`** - Interactive REPL for testing PTC-Lisp expressions
- **[Playground Livebook](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_playground.livemd)** - Try PTC-Lisp interactively
- **[LLM Agent Livebook](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_llm_agent.livemd)** - Build an agent end-to-end
- **[Examples](https://github.com/andreasronge/ptc_runner/tree/main/examples)** - Runnable example applications

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

See `PtcRunner.Lisp` module docs for options. A JSON DSL (`PtcRunner.Json`) is also available for schema-enforced execution.

## License

MIT
