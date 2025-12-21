# PtcRunner

[![Hex.pm](https://img.shields.io/hexpm/v/ptc_runner.svg)](https://hex.pm/packages/ptc_runner)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/ptc_runner)
[![CI](https://github.com/andreasronge/ptc_runner/actions/workflows/test.yml/badge.svg)](https://github.com/andreasronge/ptc_runner/actions/workflows/test.yml)
[![Hex Downloads](https://img.shields.io/hexpm/dt/ptc_runner.svg)](https://hex.pm/packages/ptc_runner)
[![License](https://img.shields.io/hexpm/l/ptc_runner.svg)](LICENSE)
[![GitHub](https://img.shields.io/badge/GitHub-repo-blue.svg)](https://github.com/andreasronge/ptc_runner)
[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fandreasronge%2Fptc_runner%2Fmain%2Flivebooks%2Fptc_runner_playground.livemd)

A BEAM-native Elixir library for Programmatic Tool Calling (PTC). Execute LLM-generated programs that orchestrate tools and transform data safely inside sandboxed processes.

## What is PTC?

Programmatic Tool Calling is an execution model where an LLM writes small programs to process data, rather than making individual tool calls. Instead of returning large datasets to the model (which bloats context), the model generates a program that calls tools, filters/transforms results, and returns only the final answer.

The pattern was introduced by Anthropic in their blog posts on [advanced tool use](https://www.anthropic.com/engineering/advanced-tool-use) and [code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp).

## Quick Example

```elixir
iex> tools = %{
...>   "get_expenses" => fn _args ->
...>     [
...>       %{"category" => "travel", "amount" => 500},
...>       %{"category" => "food", "amount" => 50},
...>       %{"category" => "travel", "amount" => 200}
...>     ]
...>   end
...> }
iex> program = ~S|{"program": {"op": "pipe", "steps": [
...>   {"op": "call", "tool": "get_expenses"},
...>   {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
...>   {"op": "sum", "field": "amount"}
...> ]}}|
iex> {:ok, result, _memory_delta, _new_memory} = PtcRunner.Json.run(program, tools: tools)
iex> result
700
```

PTC-Lisp (same result, more compact):

```elixir
iex> tools = %{"get-expenses" => fn _args ->
...>   [%{"category" => "travel", "amount" => 500},
...>    %{"category" => "food", "amount" => 50},
...>    %{"category" => "travel", "amount" => 200}]
...> end}
iex> program = ~S|(->> (call "get-expenses" {}) (filter (where :category = "travel")) (sum-by :amount))|
iex> {:ok, result, _, _} = PtcRunner.Lisp.run(program, tools: tools)
iex> result
700
```

## Why PTC?

Traditional tool calling requires multiple LLM round-trips:

```
LLM → get_employees() → LLM → filter(dept=eng) → LLM → avg(salary) → LLM
```

With PTC, the LLM writes one program executed locally:

```clojure
(->> (call "get-employees" {}) (filter (where :department = "engineering")) (avg-by :salary))
```

## Why two DSLs?

- **PTC-JSON** — Easy for weaker models; JSON schema enforces valid programs.
- **PTC-Lisp** — More expressive (anonymous functions, destructuring), ~8x fewer tokens. Clojure-inspired syntax (small subset).

**Can LLMs reliably generate these?** See [Performance and Use Cases](docs/performance-and-use-cases.md) for benchmarks, or try the [LLM Agent Livebook](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_llm_agent.livemd) to test with your own queries.

Example of PTC-Lisp that can not be expressed in PTC-JSON from the LiveBook page [![Run with LLM](https://livebook.dev/badge/v1/gray.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_llm_agent.livemd): Question: Which category has the highest total spending? Show the breakdown.

```clojure
(let [expenses (call "get-expenses" {})
      by-category (group-by :category expenses)
      spending-by-cat (map (fn [[cat items]]
                             {:category cat
                              :total (sum-by :amount items)
                              :count (count items)
                              :avg (avg-by :amount items)})
                           by-category)
      sorted (sort-by :total > spending-by-cat)]
  {:highest (first sorted)
   :breakdown sorted})
```

## Installation

```elixir
def deps do
  [{:ptc_runner, "~> 0.3"}]
end
```

## Features

- **Two DSLs**: JSON (verbose, universal) and Lisp (compact, LLM-friendly)
- **Safe**: Fixed operations, no arbitrary code execution
- **Fast**: Isolated BEAM processes with configurable timeout (1s) and memory (10MB) limits
- **Simple**: No external dependencies (Python, containers, etc.)
- **Cost-efficient**: Tested with budget models (DeepSeek 3.2, Gemini 2.5 Flash)
- **Retry-friendly**: Structured errors with actionable messages for LLM retry loops
- **Stateful**: Context refs enable persistent memory across agentic loop iterations

## Documentation

- **[Guide](docs/guide.md)** - Architecture, API reference, detailed examples
- **[Performance and Use Cases](docs/performance-and-use-cases.md)** - Benchmarks, cost analysis, when to use PTC
- **[PTC-JSON Specification](docs/ptc-json-specification.md)** - Complete JSON DSL reference
- **[PTC-Lisp Overview](docs/ptc-lisp-overview.md)** - Lisp DSL introduction
- **Livebooks**: [Playground](livebooks/ptc_runner_playground.livemd) (try the DSLs) · [LLM Agent](livebooks/ptc_runner_llm_agent.livemd) (build an agent)

## License

MIT
