---
layout: default
title: "Stop Feeding Data to Your LLM. Let It Write Programs Instead."
---

# Stop Feeding Data to Your LLM. Let It Write Programs Instead.

*Introducing ptc_runner: an Elixir library for Programmatic Tool Calling*

---

You have 5,000 customer orders and you want an LLM to find the anomalous ones. What do you do?

The naive approach is to stuff everything into the context window. But you hit token limits fast, burn money on every request, and the model starts hallucinating counts when the data gets large enough. So you reach for an agent framework and let the LLM call tools in a loop, fetching data piece by piece. Now you have a different problem: each loop iteration requires a full inference pass, intermediate results pile up in context, and you're paying for the LLM to *read* data it should be *computing over*.

There's a better way. What if the LLM didn't process the data at all? What if it just wrote a program to do it?

## LLMs as Programmers, Not Computers

This is the core idea behind **Programmatic Tool Calling** (PTC). Instead of treating the LLM as the runtime, feeding it data, asking it to reason, feeding it more, you let the LLM do what it's actually good at: *writing code*.

The LLM generates a small program. That program executes deterministically in a sandbox. Tool results stay in memory, never bloating the LLM's context. The model only sees what it needs: the final answer.

Anthropic introduced PTC as [an advanced tool use pattern](https://www.anthropic.com/engineering/advanced-tool-use) for the Claude API, where Claude writes Python that orchestrates tools inside a code execution environment. The concept is powerful, but it comes with a real operational cost: you need to host and secure a Python runtime. Python has a massive surface area. The LLM might generate code that imports arbitrary modules, makes network calls, or does things that are syntactically valid but completely unsafe. Sandboxing Python properly is hard.

[**ptc_runner**](https://github.com/andreasronge/ptc_runner) takes a different approach.

## No Python Sandbox Required

Instead of running LLM-generated Python in a containerized environment, ptc_runner uses **Erlang processes** and a purpose-built language called **PTC-Lisp**.

This matters for two reasons.

**Erlang processes give you isolation for free.** An Erlang process is similar to a Unix process: it has its own memory, its own heap, and if it crashes, nothing else goes down. There's no shared state to corrupt. The BEAM VM (Erlang's runtime) was designed from the ground up for running millions of isolated concurrent processes. It's what powers telecom switches that need 99.999% uptime. That kind of isolation is exactly what you want when executing code written by an LLM.

Each generated program runs in its own process with configurable timeouts and heap limits. If the program hangs, it gets killed. If it crashes, the parent process handles it gracefully. No Docker containers, no process managers, no Python virtual environments.

**PTC-Lisp is built for LLM generation.** Python is a general-purpose language with an enormous surface area. When you let an LLM write Python, it can do almost anything, which means you need to worry about almost everything. PTC-Lisp is intentionally small. It has the constructs an LLM needs for data processing (filtering, mapping, aggregation, control flow) and nothing it doesn't. There's no `import os`, no file system access, no network calls outside of declared tools. The language itself is the sandbox.

And because the syntax is simple and regular (it's a Lisp), LLMs generate it reliably. There are fewer ways to write something that's syntactically valid but semantically wrong compared to Python.

## A Concrete Example

Say you ask a SubAgent: *"What's the total value of orders over $100?"*

A traditional agent loop would call `get_orders`, receive all 5,000 orders into context, and then the LLM would try to read through them, filter mentally, and do arithmetic in its head. It might hallucinate the count or get the sum wrong.

A ptc_runner SubAgent writes this instead:

```clojure
(->> (tool/get_orders)
     (filter #(> (:amount %) 100))
     (sum-by :amount))
```

That's a PTC-Lisp program. It runs in an isolated BEAM process. The 5,000 orders never touch the LLM's context window. The filter and sum happen computationally, not linguistically. The LLM gets back one number: `2450.00`.

```elixir
{:ok, step} = PtcRunner.SubAgent.run(
  "What's the total value of orders over $100?",
  tools: %{"get_orders" => &MyApp.Orders.list/0},
  signature: "{total :float}",
  llm: my_llm
)

step.return.total  #=> 2450.00
```

No hallucinated counts. No token waste. No ambiguity about what happened.

## When Things Go Wrong: Feedback and Retry

LLMs don't write perfect code on the first try. That's fine. What matters is what happens next.

PTC-Lisp is designed to give the LLM structured, useful feedback when something fails. If the program has a syntax error, the LLM gets a clear message pointing to the problem. If the output doesn't match the declared signature types, it gets told exactly which fields were wrong and what was expected. And critically, if the process itself crashes, that information goes back to the LLM too. Ran out of memory? Hit the timeout? The LLM hears about it and can adapt.

This means the LLM might write a program that tries to load too much data into memory on the first attempt. The process gets killed, and the LLM receives feedback like "process exceeded heap limit." On the next turn, it writes a program that processes the data in chunks or filters more aggressively before aggregating. It learns within the workflow.

Every SubAgent declares what shape its output should have:

```elixir
signature: "{sentiment :string, score :float}"
```

If the program produces output that doesn't match these types, ptc_runner automatically retries with feedback. The signature acts as a contract: either the output matches, or the agent tries again with information about what went wrong.

This feedback loop is one of the benefits of using a purpose-built language. Because ptc_runner controls the interpreter, it can produce error messages that are specifically designed to help an LLM correct course. A generic Python traceback is noisy and often misleading. PTC-Lisp errors are concise and actionable.

## Memory References: Data That Doesn't Touch the LLM

In a traditional agent setup, when one step produces data and another step needs it, that data typically flows through the LLM's context. With 50 items that's fine. With 50,000 items it's impossible.

ptc_runner solves this with memory references. When a program calls a tool or computes a result, that data lives in BEAM memory. The LLM works with references to it. It can filter, transform, and aggregate data it has never "seen" in the traditional sense.

Within a single SubAgent, `def` persists data across turns:

```clojure
;; Turn 1: fetch and store. The LLM sees a summary, not the raw data.
(def orders (tool/get_orders))

;; Turn 2: work with the stored data without it re-entering context
(->> orders (filter #(> (:amount %) 100)) (sum-by :amount))
```

But this gets more interesting when you compose multiple SubAgents. Each agent can import and export data via typed memory references. An extraction agent might pull 10,000 records from an API and pass them to an analysis agent, which filters and aggregates, then passes results to a reporting agent. The data flows between agents through BEAM memory with type-safe contracts at each boundary. None of it passes through the LLM's context window.

This is what makes ptc_runner practical for real workloads. The LLM reasons about what to do with the data. The BEAM holds the data. They never need to share the same space.

## Parallel Execution

Since ptc_runner runs on the BEAM, parallelism is natural. The LLM can generate programs that fetch data concurrently:

```clojure
(let [[user orders stats]
      (pcalls #(tool/get_user {:id data/user_id})
              #(tool/get_orders {:id data/user_id})
              #(tool/get_stats {:id data/user_id}))]
  {:user user :order_count (count orders) :stats stats})
```

Three tool calls, running in parallel BEAM processes, each with its own isolation and resource limits. No thread pools to configure, no async/await ceremony.

## LLM Queries From Inside Programs

Sometimes a generated program needs a judgment call, not a computation but an opinion. PTC-Lisp supports ad-hoc LLM queries with typed responses:

```clojure
(pmap (fn [item]
        (tool/llm-query {:prompt "Rate urgency: {{desc}}"
                         :signature "{urgent :bool, reason :string}"
                         :desc (:description item)}))
      data/items)
```

The agent decides *what* to ask and *how* to structure the response, at runtime, from within the generated program. Each query runs in parallel via `pmap`. This lets you combine computation and judgment in a single workflow: process 1,000 items computationally, then ask an LLM to evaluate the 12 that look interesting.

## Composable SubAgents

SubAgents can be nested as tools inside other SubAgents. Each has isolated state, its own turn budget, and a typed signature:

```elixir
# An orchestrator SubAgent that uses other SubAgents as tools
{:ok, compiled} = SubAgent.compile(orchestrator, llm: my_llm)

# The LLM wrote the orchestration logic once. Now it runs deterministically.
compiled.execute.(%{topic: "quarterly review"}, llm: my_llm)
```

The orchestrator calls child agents, each of which generates and executes its own PTC-Lisp programs. The parent only sees the typed results. Combined with memory references, this means agents can hand off large datasets to each other without any of that data passing through a prompt.

## Where It Works Well

ptc_runner is best suited for tasks where raw data volume would overwhelm an LLM's context window:

**Agentic RAG.** Search, filter, summarize, re-rank, all expressed as a generated program over retrieval results. The [PageIndex example](https://github.com/andreasronge/ptc_runner/tree/main/examples/page_index) demonstrates this over PDFs.

**Log analysis.** Filter thousands of log entries by pattern, aggregate error counts, correlate across sources. The LLM never sees the raw logs.

**Data aggregation.** Join data from multiple APIs, compute statistics, apply business logic. The LLM writes the pipeline; the BEAM executes it.

## Observability

ptc_runner ships with telemetry spans for every turn, LLM call, and tool call, with parent-child correlation. Trace logs export as Chrome DevTools flame charts so you can see exactly what happened during a multi-agent workflow.

There's also a built-in trace viewer:

```bash
mix ptc.viewer --trace-dir path/to/traces
```

It shows the full execution from the high-level task graph down to individual agent turns with the LLM's thinking, the generated programs, and the tool output. When something goes wrong (and it will), you can trace exactly where.

## Try It

The fastest way to get a feel for ptc_runner is the [Livebook playground](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Fandreasronge%2Fptc_runner%2Fmain%2Flivebooks%2Fptc_runner_playground.livemd). You can experiment with PTC-Lisp interactively without any setup. For a full agent walkthrough, try the [LLM Agent Livebook](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fandreasronge%2Fptc_runner%2Fblob%2Fmain%2Flivebooks%2Fptc_runner_llm_agent.livemd).

To add it to a project:

```elixir
def deps do
  [{:ptc_runner, "~> 0.7.0"}]
end
```

The [Getting Started guide](https://hexdocs.pm/ptc_runner/subagent-getting-started.html) walks through building your first SubAgent. The [PTC-Lisp specification](https://hexdocs.pm/ptc_runner/ptc-lisp-specification.html) documents the full language.

## What's Next

ptc_runner is open source under MIT, currently at v0.7.0 and under active development. There's more to cover in future posts: the Meta Planner for decomposing complex tasks into parallel execution graphs, recursive agents that subdivide large inputs, and the JSON DSL for simpler template-based workflows.

Contributions, feedback, and issues are welcome on [GitHub](https://github.com/andreasronge/ptc_runner).

If you're building AI workflows that need to handle real data at scale, give PTC a look. The insight is simple: let the LLM think, and let the computer compute.

---

*[ptc_runner on GitHub](https://github.com/andreasronge/ptc_runner) · [Hex package](https://hex.pm/packages/ptc_runner) · [Documentation](https://hexdocs.pm/ptc_runner)*
