# Active implementation plans

This directory contains only active or partially completed plans. Completed
implementation records are removed; Git history preserves them. Current
architecture belongs in the [Kernel maintainer guide](../guides/kernel-maintainer.md),
exact runtime contracts belong in the owning module documentation, and
user-facing behavior belongs in guides or retained specifications.

## MCP and manifest-authored applications

- [`mcp-capability-platform-direction.md`](mcp-capability-platform-direction.md)
  is the active MCP client, stdio, host-installation, and filesystem migration
  plan.
- [`manifest-authored-applications-direction.md`](manifest-authored-applications-direction.md)
  defines the generic runner, classified artifacts, native PTC snapshot
  sources, and isolated candidate-evaluation work built on MCP.
- [`manifest-authored-applications-tutorial.md`](manifest-authored-applications-tutorial.md)
  is the target-state acceptance tutorial and API design probe for those two
  plans; it is not current user documentation.

## Remaining Kernel product work

- [`lisp-kernel/product-readiness.md`](lisp-kernel/product-readiness.md)
  tracks the remaining non-Elixir product boundary, diagnostics, schemas,
  distribution, and release gates.
- [`lisp-kernel/real-flow-e2e-hardening.md`](lisp-kernel/real-flow-e2e-hardening.md)
  retains only the unfinished private-sink/overflow/pagination journeys and
  cache-usage diagnosis; its MCP, REPL, inventory, and scheduled-E2E slices
  are implemented.

Plans are disposable staging contracts, not API references. When a slice
lands, move its durable behavior into module documentation and the relevant
guide or specification, update any remaining plan status, and delete a plan
that has no approved work left.
