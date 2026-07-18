# Lisp Kernel implementation and readiness

The minimal programmable Kernel migration is implemented. Current architecture
is documented in the [Kernel maintainer guide](../../guides/kernel-maintainer.md)
and exact API contracts live in the `PtcRunner.Kernel.*` module documentation.
This directory contains active product plans and retained implementation
records for recently completed cross-cutting work.

- [`product-readiness.md`](product-readiness.md) assesses what is usable now,
  current limitations, prioritized improvements, and release gates for a
  non-Elixir developer experience.
- [`viewer-ready-run-observability.md`](viewer-ready-run-observability.md)
  plans compact prelude dependency metadata with complete-payload bounds, a
  coarse shipped-agent annotation vocabulary, strict Viewer validation, and
  inspection-destination preflight for trustworthy Viewer runs.
- [`real-flow-e2e-hardening.md`](real-flow-e2e-hardening.md) plans REPL
  manifest runtime-tool grants, scheduled e2e execution, private-sink and
  overflow journeys, and delivers remote MCP e2e flows against a public
  read-only server.
- [`swappable-agent-prompt-and-viewer-context.md`](swappable-agent-prompt-and-viewer-context.md)
  records the implemented `agent.prompt` prelude with bounded policy state, a
  compact PTC-Lisp reference, manifest-selectable capability visibility,
  deterministic model-facing context, stronger inspection correlation, and a
  state-aware private inspection experience in the Viewer.
- [`runtime-prelude-contract-validation.md`](runtime-prelude-contract-validation.md)
  plans strict runtime input and output validation for public prelude
  signatures, compile-time constant checks, safe model correction feedback,
  and continued JSON Schema enforcement at raw capability boundaries.

Current user-facing material lives in [`../../guides/`](../../guides/). Git
history is the archive for the completed Kernel migration, removed experiments,
and superseded product plans. The retained
[`../../trace-log-contract.md`](../../trace-log-contract.md) owns the canonical
event/query contract; the maintainer guide owns implemented connector,
inspection, and prelude-selection boundaries.

Planned shapes in this directory are staging contracts, not claims about the
current API. In the implementation commit that makes one real, move its exact
contract into the owning module documentation and relevant guide: manifest
forms into `Kernel.Manifest`, capability metadata into `Kernel.Capability`,
canonical/inspection records into `Kernel.EventSink`/`Kernel.TraceLog`, and
Telemetry metadata into `PtcRunner.Lisp`. Update
`docs/ptc-lisp-specification.md` only when Lisp syntax or evaluation semantics
change; the connector, manifest, Viewer, and host-observability work does not
currently require a language-specification change.
