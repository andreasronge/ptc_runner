# PtcRunner

PtcRunner is a bounded meta-agentic harness. Agent orchestration, prompts,
retries, delegation, memory policy, and task logic are written in PTC-Lisp.
The BEAM-native Kernel supplies confinement, explicit capabilities, hard
resource limits, execution, and observable results.

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
