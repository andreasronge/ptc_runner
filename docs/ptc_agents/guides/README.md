# SubAgents Guides

Context-efficient agentic workflows with PTC SubAgents.

> **Note:** This API is not yet implemented. These guides document the planned design.

## What is a SubAgent?

A SubAgent is an isolated worker with a **functional contract** (signature). It does the heavy lifting with large datasets, then returns only what was promised - keeping parent agents lean and context-efficient.

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "Find the most expensive product",
  signature: "{name :string, price :float}",
  tools: %{"list_products" => &MyApp.Products.list/0},
  llm: my_llm
)

step.return.name   #=> "Widget Pro"
step.return.price  #=> 299.99
```

## Guides

### [Getting Started](getting-started.md)
Your first SubAgent, the execution model, defining tools, and providing an LLM.

### [Core Concepts](core-concepts.md)
The context firewall, `ctx/` and `memory/`, error handling, and execution modes.

### [Patterns](patterns.md)
Chaining, SubAgents as tools, LLM-powered tools, and orchestration patterns.

### [Advanced](advanced.md)
Multi-turn ReAct patterns, compile pattern for batch processing, observability, and system prompt internals.

### [Signatures](signatures.md)
Full signature syntax reference - types, collections, optional fields, and validation.

## Reference

- [Specification](../specification.md) - Complete API reference
- [PtcRunner Guide](../../guide.md) - Core PTC-Lisp documentation

## Key Concepts at a Glance

| Concept | Description |
|---------|-------------|
| **Signature** | Contract defining inputs/outputs |
| **Firewall** (`_` prefix) | Hides data from LLM prompts |
| **Context** (`ctx/`) | Read-only data passed to agent |
| **Memory** (`memory/`) | Per-agent scratchpad across turns |
| **Step** | Result struct with `return`, `fail`, `trace` |

## Quick Links

```elixir
# Create agent struct
agent = SubAgent.new(prompt: "...", signature: "...", tools: %{})

# Execute
{:ok, step} = SubAgent.run(agent, llm: llm)

# Chain
{:ok, step2} = SubAgent.run(next_agent, llm: llm, context: step)

# Wrap as tool
tool = SubAgent.as_tool(agent)

# LLM-powered tool
tool = LLMTool.new(prompt: "...", signature: "...")
```
