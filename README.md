# PtcRunner

PtcRunner is a BEAM-native runtime for safe, bounded PTC-Lisp workflows.
Host applications compile immutable Lisp component bundles, assemble explicit
workflow and mission environments, and run an entry program through
`PtcRunner.Kernel`.

> PtcRunner is a 0.x library under active development. Breaking changes are
> expected.

## What it provides

- A Clojure-oriented PTC-Lisp parser, analyzer, evaluator, and sandbox.
- A minimal owner-based Kernel with hard time, memory, result, evaluation, and
  capability limits.
- Frozen component bundles and separate workflow/mission environments.
- Host-registered capabilities, including optional file, LLM, and trace
  providers.
- Canonical bounded trace events, a manifest runner, and a stateful Kernel REPL.

## Running a workflow

The normal application boundary is a versioned JSON manifest:

```console
mix ptc.run path/to/manifest.json
mix ptc.run path/to/manifest.json --trace traces/run.jsonl
```

Use `mix ptc.repl --manifest path/to/manifest.json` for an interactive
session over the same frozen environments and provider registry.

Start with the
[Kernel tutorial](docs/guides/kernel-tutorial.md) for complete deterministic,
DeepSeek, model-authored program, feedback, logging, and viewer examples that
primarily use JSON manifests and PTC-Lisp rather than Elixir.

The active
[Kernel product-readiness roadmap](docs/plans/lisp-kernel/product-readiness.md)
describes current limitations, the recommended next milestone, and the gates
for a standalone non-Elixir developer experience.
The separate
[capability connector plan](docs/plans/lisp-kernel/capability-connectors.md)
proposes host-installed MCP, OpenAPI, database, file, and native extensions.
The
[host access and prelude workspace plan](docs/plans/lisp-kernel/host-access-and-prelude-workspaces.md)
defines how authenticated humans and explicitly delegated model runs can share
bounded TraceLog and versioned prelude services without mutating active runs.

Elixir applications can use `PtcRunner.Kernel.compile_bundle/1` and
`PtcRunner.Kernel.run/2` directly. A run accepts only a validated
`PtcRunner.Kernel.RunConfig`; authority is supplied through its explicit
environments, never ambient process state.

## Development

```console
mix precommit
mix prepush
```

The language reference is in
[`docs/ptc-lisp-specification.md`](docs/ptc-lisp-specification.md), built-ins
are listed in [`docs/function-reference.md`](docs/function-reference.md), and
the implementation is mapped in the
[Kernel maintainer guide](docs/guides/kernel-maintainer.md). Exact host API
contracts live in the `PtcRunner.Kernel.*` module documentation.

## License

See [LICENSE](LICENSE).
