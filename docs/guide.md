# PtcRunner Guide

## Architecture

```mermaid
flowchart TD
      User([User / LLM Client]) -->|"run/2 (program)"| Runner[PtcRunner.Json / PtcRunner.Lisp]

      subgraph "PtcRunner Process"
          Runner -->|parse/1| Parser[Parser]
          Parser -->|AST| Validator[Validator / Analyzer]
          Validator -->|":ok"| Runner
          Runner -->|Creates| Context[Execution Context]
          Context -- Contains --> Tools[Tool Registry]
      end

      subgraph "Sandbox Process"
          direction TB
          Sandbox[Sandbox<br/>max_heap: 10MB<br/>timeout: 1s]
          Sandbox -->|eval/2| Interpreter[Interpreter / Eval]
          Interpreter -->|Dispatch| Ops[Operations / Runtime]
          Ops -->|Access vars| ContextRef[Context]
          Ops -->|Call| ToolsRef[Tools]
      end

      Runner -->|"execute/3 (AST, Context)"| Sandbox
      Sandbox -->|Result| Runner
```

Two-phase execution: parse and validate in the main process, then execute in an isolated sandbox with memory and timeout limits.

## Design Principles

1. **Safety First**: Programs run in isolated processes with resource limits
2. **Simplicity**: DSLs are easy for LLMs to generate and humans to debug
3. **Composability**: Operations chain via `pipe`, results can be stored and referenced
4. **Extensibility**: Users register their own tools as simple functions
5. **Execution Only**: No LLM integration—compose with ReqLLM or other clients

## DSL Specifications

- **[PTC-JSON Specification](ptc-json-specification.md)** - Complete JSON DSL reference
- **[PTC-Lisp Specification](ptc-lisp-specification.md)** - Complete Lisp DSL reference
- **[PTC-Lisp Overview](ptc-lisp-overview.md)** - Lisp DSL introduction
- **[Performance and Use Cases](performance-and-use-cases.md)** - Benchmarks, cost analysis, when to use PTC

### Quick Comparison

**PTC-JSON**
```json
{
  "program": {
    "op": "pipe",
    "steps": [
      {"op": "load", "name": "expenses"},
      {"op": "filter", "where": {"op": "eq", "field": "category", "value": "travel"}},
      {"op": "sum", "field": "amount"}
    ]
  }
}
```

**PTC-Lisp**
```clojure
(->> ctx/expenses
     (filter (where :category = "travel"))
     (sum-by :amount))
```

## API Reference

See the module documentation for complete API details:

- `PtcRunner.Json` - JSON DSL entry point, tool registration, error handling
- `PtcRunner.Lisp` - Lisp DSL entry point, tool registration
- `PtcRunner.Sandbox` - Resource limits and configuration
- `PtcRunner.Context` - Context, memory, and tools management

## LLM Integration

PtcRunner is execution-only. Compose with your LLM client (e.g., [ReqLLM](https://hexdocs.pm/req_llm)):

```elixir
defmodule MyApp.PTCAgent do
  @system_prompt """
  Generate JSON programs using this DSL:
  #{PtcRunner.Schema.to_prompt()}
  """

  def run(user_request, context \\ %{}) do
    {:ok, response} = ReqLLM.generate_text("anthropic:claude-haiku-4.5",
      user_request, system: @system_prompt)

    program = extract_json(response)

    case PtcRunner.Json.run(program, context: context, tools: @tools) do
      {:ok, result, _} -> {:ok, result}
      {:error, error} -> retry_with_error(user_request, program, error)
    end
  end
end
```

### Dynamic Context Refs

For large tool results, store them as context refs instead of returning to the LLM:

```elixir
def handle_tool_result(state, tool_name, result) do
  if large_result?(result) do
    ref = "#{tool_name}_#{System.unique_integer([:positive])}"
    state = %{state | context: Map.put(state.context, ref, result)}
    {state, {:context_ref, %{ref: ref, count: length(result)}}}
  else
    {state, {:inline, result}}
  end
end
```

The LLM queries via: `{"op": "load", "name": "get_orders_42"}`.

## Demo Application

The `demo/` directory contains an interactive chat application demonstrating PtcRunner with LLM integration:

- **Interactive CLI**: Query datasets using natural language
- **Both DSLs**: JSON (`mix run -e "PtcDemo.CLI.main([])"`) and Lisp (`mix lisp`)
- **Test Runner**: Automated tests to evaluate LLM program generation accuracy
- **Sample Data**: 2500 records across products, orders, employees, and expenses

See `demo/README.md` for setup and usage.

#### Running E2E Tests

E2E tests require an API key. Copy `.env.example` to `.env` and configure:

```bash
cp .env.example .env
# Edit .env with your OPENROUTER_API_KEY

# Run JSON DSL e2e tests
mix test test/ptc_runner/json/e2e_test.exs --include e2e

# Run Lisp DSL e2e tests
mix test test/ptc_runner/lisp/e2e_test.exs --include e2e

# Run all e2e tests
mix test --include e2e

# Run with specific model
PTC_TEST_MODEL=haiku mix test --include e2e
```

The same `.env` file is used by the demo application in `demo/`.

## Clojure Validation

PTC-Lisp is designed as a Clojure subset. You can validate programs against real Clojure using [Babashka](https://babashka.org/):

```bash
# Install Babashka (one-time)
mix ptc.install_babashka

# Run Clojure conformance tests
mix test --only clojure

# Skip Clojure tests (if Babashka not installed)
mix test --exclude clojure

# Demo test runner with Clojure syntax validation
cd demo && mix lisp --test --validate-clojure
```

### Known Differences from Clojure

PTC-Lisp aims for semantic compatibility with Clojure. All conformance tests currently pass.

The main intentional difference is that sequence functions (`filter`, `map`, `sort`, etc.) return vectors instead of lazy sequences. This is practical for LLM use cases and doesn't affect program correctness.

## References

- [Anthropic PTC Blog Post](https://www.anthropic.com/research/ptc)
- [Open-PTC-Agent (Python)](https://github.com/Chen-zexi/open-ptc-agent)
- [ReqLLM Documentation](https://hexdocs.pm/req_llm)
