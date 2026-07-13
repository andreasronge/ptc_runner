# Lisp Kernel implementation and readiness

The minimal programmable Kernel migration is implemented. Current architecture
is documented in the [Kernel maintainer guide](../../guides/kernel-maintainer.md)
and exact API contracts live in the `PtcRunner.Kernel.*` module documentation.
This directory contains active product and extension plans only.

- [`product-readiness.md`](product-readiness.md) assesses what is usable now,
  current limitations, prioritized improvements, and release gates for a
  non-Elixir developer experience.
- [`capability-connectors.md`](capability-connectors.md) is the future plan for
  host-installed MCP, HTTP/OpenAPI, database, file, and native capability
  sources plus separate inbound HTTP/MCP frontends.
- [`host-access-and-prelude-workspaces.md`](host-access-and-prelude-workspaces.md)
  defines the shared host authorization substrate, authenticated TraceLog and
  Viewer path, versioned prelude candidates, promotion gates, implementation
  slices, and appendix usage examples.

- [`tracelog-contract.md`](tracelog-contract.md) defines canonical event
  storage, source grants, bounded queries, and the swappable `log/` library.

Current user-facing material lives in [`../../guides/`](../../guides/). Git
history is the archive for the completed Kernel migration, removed experiments,
and superseded product plans.
