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
{:ok, step} = PtcRunner.SubAgent.run(
  "What's the total value of orders over $100?",
  tools: %{"get_orders" => &MyApp.Orders.list/0},
  signature: "{total :float}",
  llm: my_llm
)

step.return.total  #=> 2450.00
```

The SubAgent doesn't answer directly - it writes a program that computes the answer:

```clojure
(->> (call "get_orders" {})
     (filter (where :amount > 100))
     (sum-by :amount))
```

This is [Programmatic Tool Calling](https://www.anthropic.com/engineering/advanced-tool-use): instead of the LLM being the computer, it programs the computer.

## Why SubAgents?

- **Precise computation**: LLMs reason and generate code; computation runs deterministically in a sandbox
- **Context-efficient**: Process large datasets locally instead of sending everything to the LLM
- **Multi-turn capable**: Agents can call tools, store results in memory, and iterate until done
- **Type-safe**: Validate return structures with signatures; agents auto-retry on mismatch

## Installation

```elixir
def deps do
  [{:ptc_runner, "~> 0.3"}]
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

- **[Playground Livebook](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_playground.livemd)** - Try PTC-Lisp interactively
- **[LLM Agent Livebook](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_llm_agent.livemd)** - Build an agent end-to-end

## Low-Level APIs

For direct program execution without the agentic loop, use the DSL runners:

```elixir
# PTC-Lisp (compact, expressive)
{:ok, %{return: result}} = PtcRunner.Lisp.run(
  "(->> ctx/items (filter (where :active)) (count))",
  context: %{items: items}
)

# PTC-JSON (verbose, schema-enforced)
{:ok, result, _, _} = PtcRunner.Json.run(program_json, tools: tools)
```

See **[Guide](docs/guide.md)** for architecture and low-level API details.

## License

MIT
