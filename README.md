# PtcRunner

PtcRunner is a bounded meta-agentic harness. Agent orchestration, prompts,
retries, delegation, memory policy, and task logic are written in PTC-Lisp: a
small, eager, bounded subset of Clojure with a few PTC-specific forms and
namespaces. The BEAM-native Kernel supplies confinement, explicit capabilities,
hard resource limits, execution, and observable results.

PTC-Lisp includes a small runtime contract system for public functions and
values. Signatures validate inputs and successful outputs and produce
structured, path-aware errors. Agent workflows can turn a pure contract or
evaluation failure into bounded correction feedback, giving an LLM a concrete
reason to revise its program and retry. Programs are not blindly retried after
capability activity, where repeating an external effect may be unsafe. The
credential-free
[`05-signature-feedback`](examples/kernel-tutorial/05-signature-feedback/ptc.json)
example demonstrates the complete failure, feedback, and correction cycle.

> PtcRunner is a 0.x project under active development. Breaking changes are
> expected. The Kernel line is a clean replacement for the earlier product.

## What you build

A PtcRunner project contains PTC-Lisp components and a small JSON manifest.
The manifest chooses the entry function, input, installed providers, requested
limits, and event policy. It cannot register host code or grant authority.

One run has two intentionally different environments:

- **workflow** — trusted PTC-Lisp that owns agent policy and may call a model;
- **mission** — confined PTC-Lisp, including model-authored programs, with only
  the task capabilities explicitly granted by the host.

PTC-Lisp may use authority but cannot manufacture it. Credentials, transports,
filesystem roots, network destinations, process ownership, and hard limits
remain outside the language boundary.

## Why PTC-Lisp and the BEAM?

An agent harness needs two different things: a language that an LLM can write
and correct, and a runtime that can enforce what the generated program is
allowed to do. PtcRunner keeps those responsibilities separate.

### Why PTC-Lisp?

- **Compact and model-friendly.** Clojure-shaped code is regular and
  data-oriented. One generated program can transform data, branch, loop, and
  call several granted capabilities instead of requiring a model round trip
  for every small operation.
- **Small enough to bound.** PTC-Lisp is eager and deliberately excludes
  arbitrary host access, macros, `eval`, lazy or infinite sequences, and
  general Java interop. The model receives the exact mission API it may call.
- **Built for correction.** Public signatures, structured errors, and
  transactional definition memory give an agent concrete feedback after a
  pure failure. It can revise the program without publishing definitions from
  the failed attempt.
- **Policy stays portable.** Prompts, retries, planning, delegation, and
  completion rules are ordinary versioned PTC-Lisp components rather than
  changes to trusted Elixir host code or one fixed framework loop.

Safety does not come from Lisp syntax alone. The Kernel compiles a closed
component bundle, grants explicit capabilities, validates their schemas, and
enforces time, heap, source, memory, call, result, and event ceilings.

### Why the BEAM virtual machine?

- **Lightweight concurrency.** Independent runs, evaluations, and capability
  work can use lightweight BEAM processes under preemptive scheduling.
- **Isolation and ownership.** Processes have separate heaps and communicate
  by messages. Monitors and single-owner state make cancellation, cleanup, and
  atomic resource accounting explicit.
- **Enforceable failure boundaries.** The Kernel can run work in monitored,
  heap-capped processes, terminate timed-out work, and reject results that
  arrive after a run has closed.
- **Low per-run infrastructure overhead.** A BEAM process is materially lighter
  than starting an OS process or container for every small evaluation, making
  many concurrent bounded evaluations practical inside one host runtime.

The BEAM is usefully thought of as a small process operating system inside the
host: it provides schedulers, processes, mailboxes, monitors, and per-process
heaps. It is not an OS security sandbox for deliberately hostile native BEAM
code. Trusted providers and the host still own external authority, and an OS
process or container may remain the outer deployment boundary.

Together, the model proposes PTC-Lisp, the language contracts make mistakes
actionable, the Kernel mediates every effect, and the BEAM contains and
accounts for execution. This aims to reduce model/tool round trips and runtime
overhead without moving credentials or unrestricted host access into generated
code. PtcRunner does not yet claim a benchmark-backed speed or cost multiplier;
those results depend on the workload and will need published measurements.

## Availability

The new Kernel product is currently available from a source checkout with
Elixir and Mix. The other distribution channels will be released from `main`
after the shared standalone command contract is complete.

| Installation | Status | Interface |
| --- | --- | --- |
| Source checkout with Mix | Available | `mix ptc.run`, `mix ptc.repl` |
| Hex dependency for Elixir applications | Next 0.x release | Mix tasks and `PtcRunner.Kernel` |
| Standalone macOS installation | Planned | `ptc` command, without an Elixir installation |
| Docker image | Planned | The same `ptc` command and runtime contract |

## Try a bounded workflow

From the repository root:

```console
mix deps.get
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json
```

The checked-in example loads JSON input, runs a deterministic PTC-Lisp
function, and returns a bounded JSON result. It requires no model credentials
and no Elixir code.

Persist its sanitized canonical trace with:

```console
mkdir -p tmp/tutorial-traces
mix ptc.run examples/kernel-tutorial/01-orders/ptc.json \
  --trace tmp/tutorial-traces/orders.jsonl
```

See [Getting started](docs/guides/getting-started.md) for the complete example.

## How a meta-agent run works

```text
manifest + workflow PTC-Lisp
             |
             v
     bounded workflow ---- model/provider capabilities
             |
             | static or model-authored PTC-Lisp
             v
      bounded mission ---- narrowly granted task capabilities
             |
             v
       result or error + usage + canonical events
```

The repository ships PTC-Lisp agent libraries for model requests, feedback,
retry policy, prompt construction, and multi-turn mission evaluation. The
Kernel does not embed one fixed agent loop.

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

The current source tree includes a local trace Viewer and live model examples.
Those are development features until their standalone packaging is complete.

## License

See [LICENSE](LICENSE).
