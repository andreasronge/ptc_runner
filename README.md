# PtcRunner

PtcRunner lets an LLM write a small program to solve a task, then runs that
program with only the tools you allow.

Instead of sending every tool result back to the model, one PTC-Lisp program
can call several tools, transform their results, branch, and loop. This can
reduce model round trips while keeping credentials and unrestricted host access
out of generated code.

> PtcRunner is a 0.x project under active development. Breaking changes are
> expected.

## What is different?

- **Programmatic tool calling.** Deterministic work stays in generated code
  instead of repeatedly passing intermediate data through the LLM.
- **Replaceable agent behavior.** Prompts, retries, planning, memory, and
  completion rules are PTC-Lisp libraries—not a loop fixed inside the runtime.
- **Controlled tools.** Generated programs see a small task API, not
  credentials, arbitrary files, network access, or host functions.
- **Useful failures.** Successful definitions remain available on the next
  turn; failed attempts roll back and return clear correction errors.
- **Evidence for improvement.** Structured traces record outcomes, errors,
  tool use, evaluations, and resource use. Exact prompts and generated code can
  be captured separately during development.

PtcRunner is most useful when a task needs several tool calls plus local data
work, or when you want to experiment with agent behavior without changing the
trusted host application.

## How it works

```text
task
  -> workflow: choose the prompt and retry policy
  -> model: write one PTC-Lisp program
  -> mission: run it with the allowed task tools
  -> result, usage, and trace
```

A project contains PTC-Lisp files and a small JSON manifest. The manifest
chooses the entry function, input, providers, and limits. It cannot register
host code or add tools the host did not install.

The workflow owns agent policy and may call a model. Model-written code runs in
a separate mission with only the task tools granted by the host. The runtime
owns credentials, tool implementations, timeouts, memory limits, and cleanup.

## Why PTC-Lisp?

PTC-Lisp is a small subset of Clojure made for programmatic tool calling. Its
regular syntax is compact for models, while still supporting data
transformations, functions, branching, loops, and multiple tool calls. The
model is shown the exact task API it may call; arbitrary host access, macros,
`eval`, lazy or infinite sequences, and general Java interop are left out.

### Preludes: reusable agent code

Skills usually tell a model how to approach work. A prelude preserves working
behavior as executable PTC-Lisp. Preludes can depend on one another and compile
together into the fixed workflow or mission bundle used by a run. They
typically work at three levels:

- **Runtime:** safe wrappers for models, tools, results, and evaluation.
- **Agent:** prompt, feedback, retry, memory, delegation, and workflow policy.
- **Domain:** task-specific functions that combine lower-level tools into a
  smaller API for the model.

Preludes can also shape model instructions. `agent.prompt` builds the system
prompt, while prompt-visible domain functions appear in the model's available
API with documentation and optional signatures. The model sees that rendered
interface, not the prelude source by default.

Prelude versions are selected explicitly today. A future promotion flow could
use trace evidence to turn repeated successful programs into tested domain
preludes for later runs. That code could improve how existing tools are used,
but could not grant itself new tools or credentials.

Trace analysis is itself programmable in PTC-Lisp. The shipped `log.core`
prelude provides `log/runs`, `log/run`, `log/turns`, and `log/counters` over an
unchanging trace capture. An investigation can start as a REPL function and
later become a reusable analysis prelude. Logging does not improve the system
automatically today; it provides the evidence and programmable analysis layer
needed for a future improvement loop.

## Why the BEAM?

The BEAM virtual machine provides lightweight processes, separate heaps,
message passing, and monitors. PtcRunner uses them for concurrent work,
deadlines, memory limits, cleanup, and resource accounting. It behaves like a
small process operating system inside the application, with much less startup
overhead than an OS process or container for every evaluation. A container can
still provide the outer security boundary.

## Try it

From the repository root:

```console
mix deps.get
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json
```

The example loads JSON input, runs a PTC-Lisp function, and returns a JSON
result. It requires no model credentials or Elixir code. See
[Getting started](docs/guides/getting-started.md) for the walkthrough and trace
commands, then [Building agents](docs/guides/building-agents.md) for a live
model-generated program.

## Availability

The current product runs from a source checkout with Elixir and Mix. Other
installations will be released from `main` after the standalone command is
complete.

| Installation | Status | Interface |
| --- | --- | --- |
| Source checkout with Mix | Available | `mix ptc.run`, `mix ptc.repl` |
| Hex dependency for Elixir applications | Next 0.x release | Mix tasks and `PtcRunner.Kernel` |
| Standalone macOS installation | Planned | `ptc` command, without an Elixir installation |
| Docker image | Planned | The same `ptc` command and runtime contract |

## Guides

- [Getting started](docs/guides/getting-started.md) — run a credential-free
  PTC-Lisp workflow and inspect its result and trace.
- [Building agents](docs/guides/building-agents.md) — put orchestration and
  agent policy in PTC-Lisp while keeping mission authority narrow.
- [Manifests and capabilities](docs/guides/manifests-and-capabilities.md) —
  assemble components, data, providers, limits, and event policy.
- [Running and debugging](docs/guides/running-and-debugging.md) — use the run
  command, REPL, traces, private inspection, and development Viewer.
- [Embedding in Elixir](docs/guides/embedding-in-elixir.md) — integrate the
  same Kernel into a host application.

Advanced references include the [PTC-Lisp specification](docs/ptc-lisp-specification.md),
[function reference](docs/function-reference.md),
[conformance report](docs/conformance/index.md), and
[Kernel maintainer guide](docs/guides/kernel-maintainer.md).

## Development

```console
mix precommit
mix prepush
```

## License

See [LICENSE](LICENSE).
