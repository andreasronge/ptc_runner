# Maintainer documentation

> **Audience:** people and coding agents changing PtcRunner itself.

End-user workflows live in [`docs/guides/`](../guides/), exhaustive product
contracts live in [`docs/reference/`](../reference/), and installation routes
live in [`docs/installation/`](../installation/). This directory owns the
runtime implementation, repository workflow, and host-integration view.

- [Development setup](development-setup.md) — toolchain, worktrees, hooks, and
  local CI modes.
- [Kernel architecture](kernel.md) — ownership, environments, evaluation,
  providers, events, and cleanup.
- [Embedding and host APIs](embedding.md) — construct and drive the Kernel from
  a host application.
- [Documentation guidelines](documentation.md) — audience and layer ownership,
  examples, generated pages, and verification.
- [Coding-agent review](coding-agent-review.md) — independent review workflow.
- [Duplication gate](duplication-gate.md) — baseline, suppression, and shared
  helper rules.
- [Signature integration](signature-integration.md) — host projection and
  schema-generation implementation details.
- [Conformance review](conformance/review-program.md) — standing language
  compatibility review method and classification records.
- [Release procedure](releasing.md) — package, documentation, standalone, and
  launcher release gates.

`AGENTS.md` remains the canonical repository instruction file. Do not duplicate
its changing worktree, testing, or release commands here when a link is enough.
