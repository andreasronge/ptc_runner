# Implementation plans

This directory contains active, partially completed, and explicitly
trigger-gated future plans. Completed implementation records are removed; Git
history preserves them. Current architecture belongs in the
[Kernel maintainer guide](../guides/kernel-maintainer.md), exact runtime
contracts belong in the owning module documentation, and user-facing behavior
belongs in guides or retained specifications.

## Remaining Kernel product work

- [`lisp-kernel/product-readiness.md`](lisp-kernel/product-readiness.md)
  tracks the remaining command-line, diagnostics, model-boundary,
  distribution, and release work.
- [`lisp-kernel/real-flow-e2e-hardening.md`](lisp-kernel/real-flow-e2e-hardening.md)
  tracks the unfinished private-sink, overflow, real-pagination, and
  cache-usage journeys.
- [`mcp-oauth.md`](mcp-oauth.md) plans principal-scoped OAuth authorization for
  remote Streamable HTTP MCP servers without weakening host authority or tool
  replay safety.

## Future, trigger-gated

- [`future/mcp-exact-resources.md`](future/mcp-exact-resources.md) records the
  unmet first-party trigger and minimum authority shape required before MCP
  exact-resource work can begin.
- [`future/launcher-repository-extraction.md`](future/launcher-repository-extraction.md)
  records the prerequisites and migration sequence for moving the independently
  released native launcher companion into its own Git repository. Extraction
  is not scheduled while core and launcher protocol changes still benefit from
  atomic commits.

Plans are disposable staging contracts, not API references. When a slice
lands, move its durable behavior into module documentation and the relevant
guide or specification, update any remaining plan status, and delete a plan
that has no approved work left.
