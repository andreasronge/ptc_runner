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
- Host-registered capabilities, including optional file, LLM, trace, and
  read-only MCP providers.
- Canonical bounded traces plus a separate opt-in private inspection artifact,
  a manifest runner, local Viewer, and stateful Kernel REPL.

## Running a workflow

The normal application boundary is a versioned JSON manifest:

```console
mix ptc.run path/to/manifest.json
mix ptc.run path/to/manifest.json --trace traces/run.jsonl
mix ptc.run path/to/manifest.json --trace traces/run.jsonl \
  --inspect traces/run.inspection.jsonl
```

Use `mix ptc.repl --manifest path/to/manifest.json` for an interactive
session over the same frozen environments and provider registry.

For a bounded mission session over an immutable capture of canonical traces,
select the code-owned log-analysis profile:

```console
mix ptc.repl \
  --profile log-analysis-v1 \
  --resource traces=path/to/traces
```

The [Kernel REPL guide](docs/guides/kernel-repl.md) covers direct,
manifest-backed, and profile-backed sessions, including JSONL output for coding
agents and separate analysis-trace persistence.

Start with the
[Kernel tutorial](docs/guides/kernel-tutorial.md) for complete deterministic,
DeepSeek, model-authored program, feedback, logging, and Viewer examples that
primarily use JSON manifests and PTC-Lisp rather than Elixir.

The credential-free
[Kernel inspection lab](examples/kernel-inspection-lab/README.md) runs a
scripted agent across file, native, and MCP read capabilities and produces the
canonical/private artifacts used by the local Viewer tests.

The active product-readiness roadmap under `docs/plans/lisp-kernel/` describes
current limitations, the recommended next milestone, and the gates for a
standalone non-Elixir developer experience.
The [Kernel maintainer guide](docs/guides/kernel-maintainer.md) documents the
implemented MCP-first connector, canonical/private observability boundaries,
and local Viewer inspection lifecycle. Later connector families and
authenticated shared services remain roadmap work until a host product
requires them.

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
