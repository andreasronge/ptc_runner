# PtcRunner

Below is a ~100-line summary describing the ptc_runner project—what it is, why it exists, what problems it solves, and how it works. It’s written in a style suitable for a README introduction, proposal document, or architectural overview.

⸻

PTC Runner — Project Summary (≈100 lines)

ptc_runner is an Elixir library designed to bring Programmatic Tool Calling (PTC) to the BEAM ecosystem.
PTC is a powerful execution model—pioneered by Anthropic’s “open-ptc-agent”—where an LLM writes programs, not function-call JSON, to orchestrate tools, transform data, and compute final results inside a sandbox.
Instead of returning large datasets directly to the model (which bloats context), the model writes a small program that runs locally on the host, processes large data efficiently, and returns only the final result.
This results in massive token savings and enables more complex reasoning pipelines.

The problem: existing PTC implementations depend heavily on Python sandboxes, Daytona runtimes, and Python-based code execution.
For Elixir developers, this introduces foreign runtime dependencies, adds operational complexity, and doesn’t leverage the strengths of the BEAM VM.
Additionally, running arbitrary AI-generated Python code introduces security risks and deployment challenges.

ptc_runner aims to provide a safe, BEAM-native alternative.
Instead of letting the LLM generate arbitrary Elixir code—which is unsafe and not well supported—it introduces a small, structured DSL for tool calling and data transformation.
This DSL is designed to be:
• Safe: only a fixed set of operations are allowed.
• Deterministic: execution follows a strict interpreter, no hidden side effects.
• LLM-friendly: easy for models to produce, easy to validate.
• Sandboxable: evaluation happens inside isolated BEAM processes or optional Lua/WASM runtimes.

The project consists of four main layers:
	1.	DSL Layer
A JSON-based or minimal text-based language describing tool calls, filters, aggregations, merges, reductions, and control flow.
It is simple enough for LLMs to reliably generate yet expressive enough for common data workflows.
	2.	Parser Layer
Converts DSL programs into an internal AST.
Ensures validity, type checks arguments, and prevents invalid or harmful structures before execution.
	3.	Interpreter / Execution Engine
Runs AST instructions safely inside the BEAM.
Implements operations like filtering lists, selecting fields, grouping, summing, joining datasets, mapping over collections, and calling tools.
Guarantees that code cannot escape the allowed environment.
	4.	Tool Layer (MCP Integration)
Exposes BEAM functions as “tools” that the DSL can call.
Tools may include database queries, analytics, data loading, or business logic.
This layer allows integration with Model Context Protocol (MCP) servers or custom user-defined tools.
The model invokes tools indirectly through DSL instructions, never directly calling Elixir functions.

Optionally, ptc_runner provides embedding support for:
• Lua (via Luerl) for additional sandboxing.
• WebAssembly (WASM) for stronger isolation.
• ReqLLM / OpenRouter for LLM communication.
• Supervisor-based sandbox pools for high-concurrency workloads.

ptc_runner makes it possible to run large-scale tool workflows entirely on the BEAM without Python.
It enables LLMs to process datasets, merge tool outputs, perform calculations, and orchestrate logic locally—while keeping the model’s context small and the execution safe.
It provides a foundation for building advanced agents, code-driven workflows, chat-based data pipelines, or autonomous systems in Elixir.

In essence, ptc_runner turns Elixir into a PTC execution environment, letting the BEAM act as a safe “compute engine” for AI-generated programs.
It is designed to be modular, safe-by-default, easy to integrate, and powerful enough to replace Python-based PTC architectures.
This makes it the first step toward full BEAM-native agent workloads, enabling developers to stay entirely inside the Elixir ecosystem while leveraging the latest LLM capabilities.


## Status

TODO: create specification from research document, see docs/research.md

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `ptc_runner` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ptc_runner, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/ptc_runner>.

