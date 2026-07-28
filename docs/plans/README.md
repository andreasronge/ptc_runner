# Active implementation plans

This directory contains only active or partially completed plans. Completed
implementation records are removed; Git history preserves them. Current
architecture belongs in the [Kernel maintainer guide](../guides/kernel-maintainer.md),
exact runtime contracts belong in the owning module documentation, and
user-facing behavior belongs in guides or retained specifications.

## Remaining Kernel product work

- [`lisp-kernel/product-readiness.md`](lisp-kernel/product-readiness.md)
  tracks the remaining command-line, diagnostics, model-boundary,
  distribution, and release work.
- [`lisp-kernel/real-flow-e2e-hardening.md`](lisp-kernel/real-flow-e2e-hardening.md)
  tracks the unfinished private-sink, overflow, real-pagination, and
  cache-usage journeys.

## Proposed, not scheduled

- [`mcp-write-and-surface.md`](mcp-write-and-surface.md) investigates write-effect
  MCP tools, the remaining read-oriented client surface, and why
  server-initiated model access stays refused.

Plans are disposable staging contracts, not API references. When a slice
lands, move its durable behavior into module documentation and the relevant
guide or specification, update any remaining plan status, and delete a plan
that has no approved work left.
