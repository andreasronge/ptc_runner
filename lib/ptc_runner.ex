defmodule PtcRunner do
  @moduledoc """
  BEAM-native Programmatic Tool Calling (PTC) library.

  PtcRunner enables LLMs to write programs that orchestrate tools and transform
  data inside a sandboxed environment. The LLM reasons and generates code; the
  computation runs in an isolated interpreter with deterministic results.

  ## Core Components

  | Component | Purpose |
  |-----------|---------|
  | `PtcRunner.SubAgent` | Agentic loop: prompt → LLM → program → execute → repeat |
  | `PtcRunner.Lisp` | PTC-Lisp interpreter |
  | `PtcRunner.Sandbox` | Isolated execution with timeout/memory limits |
  | `PtcRunner.Context` | Tools and memory container |

  ## Example

      {:ok, step} = PtcRunner.SubAgent.run("What's 2 + 2?", llm: my_llm)
      step.return  #=> 4

  The SubAgent asks the LLM to write a program, executes it in the sandbox,
  and returns the result. See `PtcRunner.SubAgent.run/2` for all options.

  ## Guides

  - [Getting Started](guides/subagent-getting-started.md) - First SubAgent walkthrough
  - [Core Concepts](guides/subagent-concepts.md) - Context, memory, firewall convention
  - [Patterns](guides/subagent-patterns.md) - Composition and orchestration
  """
end
