# Lisp Kernel implementation and readiness

The minimal programmable Kernel migration is implemented. Current architecture
is documented in the [Kernel maintainer guide](../../guides/kernel-maintainer.md)
and exact API contracts live in the `PtcRunner.Kernel.*` module documentation.
This directory contains active product and extension plans only.

- [`product-readiness.md`](product-readiness.md) assesses what is usable now,
  current limitations, prioritized improvements, and release gates for a
  non-Elixir developer experience.
- [`capability-connectors.md`](capability-connectors.md) is the active MCP-first
  plan for one host-installed read-only external-tools route and its inspectable
  developer validation journey. Other adapters and inbound frontends remain
  demand-triggered follow-ons.
- [`host-access-and-prelude-workspaces.md`](host-access-and-prelude-workspaces.md)
  defines the narrow local inspection and read-only installed-prelude work that
  can land now, while deferring shared host authorization, authenticated remote
  Viewer access, writable prelude candidates, and promotion services.

- [`tracelog-contract.md`](tracelog-contract.md) defines canonical event
  storage, source grants, bounded queries, and the swappable `log/` library.

Current user-facing material lives in [`../../guides/`](../../guides/). Git
history is the archive for the completed Kernel migration, removed experiments,
and superseded product plans.

Planned shapes in this directory are staging contracts, not claims about the
current API. In the implementation commit that makes one real, move its exact
contract into the owning module documentation and relevant guide: manifest
forms into `Kernel.Manifest`, capability metadata into `Kernel.Capability`,
canonical/inspection records into `Kernel.EventSink`/`Kernel.TraceLog`, and
Telemetry metadata into `PtcRunner.Lisp`. Update
`docs/ptc-lisp-specification.md` only when Lisp syntax or evaluation semantics
change; the connector, manifest, Viewer, and host-observability work does not
currently require a language-specification change.
