# Lisp Kernel implementation and readiness

The minimal programmable Kernel migration is implemented on
`exp/minimal-kernel`. The contract and migration documents record the completed
replacement. Product-readiness work continues in a separate active roadmap so
future usability work is not confused with unresolved Kernel-contract work.

- [`product-readiness.md`](product-readiness.md) assesses what is usable now,
  current limitations, prioritized improvements, and release gates for a
  non-Elixir developer experience.
- [`capability-connectors.md`](capability-connectors.md) is the future plan for
  host-installed MCP, HTTP/OpenAPI, database, file, and native capability
  sources plus separate inbound HTTP/MCP frontends.

- [`kernel-contract.md`](kernel-contract.md) is the normative V1 runtime
  contract.
- [`tracelog-contract.md`](tracelog-contract.md) defines canonical event
  storage, source grants, bounded queries, and the swappable `log/` library.
- [`kernel-migration.md`](kernel-migration.md) records the completed vertical
  implementation, cutover, deletion, and verification sequence.
- [`kernel-inventory.md`](kernel-inventory.md) is the closed as-built
  retain/migrate/delete record.

Current user-facing material lives in [`../../guides/`](../../guides/). Git
history is the archive for removed experiments and superseded product plans.
