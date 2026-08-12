# Implementation plans

This directory contains active, partially completed, and explicitly
trigger-gated future plans. Completed implementation records are removed; Git
history preserves them. Current architecture belongs in the
[Kernel maintainer guide](../guides/kernel-maintainer.md), exact runtime
contracts belong in the owning module documentation, and user-facing behavior
belongs in guides or retained specifications.

## Remaining Kernel product work

- [`issue-1237-named-missions.md`](issue-1237-named-missions.md) replaces the
  singular mission environment with bounded named missions that isolate
  components, data, grants, continuations, prompts, and durable evidence.
- [`lisp-kernel/generated-program-boundary.md`](lisp-kernel/generated-program-boundary.md)
  separates runtime values from subordinate program source and adds a bounded,
  mission-aware source-checking path for generated PTC-Lisp.
- [`lisp-kernel/promote-authored-component.md`](lisp-kernel/promote-authored-component.md)
  closes the loop from model-authored runtime source to an attested component:
  host-side materialization, descriptor provenance, and a promotion gate that
  does not depend on the removed `run --check`.
- [`lisp-kernel/stable-cli-contract.md`](lisp-kernel/stable-cli-contract.md)
  turns the product-readiness CLI slice into an implementation-ordered
  protocol, diagnostics, and filesystem-independent application-source plan.
- [`lisp-kernel/product-readiness.md`](lisp-kernel/product-readiness.md)
  tracks the remaining command-line, diagnostics, model-boundary,
  distribution, and release work.
- [`lisp-kernel/real-flow-e2e-hardening.md`](lisp-kernel/real-flow-e2e-hardening.md)
  tracks the unfinished private-sink, overflow, real-pagination, and
  cache-usage journeys.
- [`lisp-kernel/private-analysis-agent-access.md`](lisp-kernel/private-analysis-agent-access.md)
  fixes the capability-memory bug blocking `inspection-analysis-v2`
  evaluation and adds `--private-unattended` so a coding agent can use it
  non-interactively.
- [`mcp-oauth.md`](mcp-oauth.md) plans principal-scoped OAuth authorization for
  remote Streamable HTTP MCP servers without weakening host authority or tool
  replay safety.

## Runtime quality

- [`memory-observability.md`](memory-observability.md) restores the orphaned
  soak gate, adds a committed per-use-case heap baseline, and extends leak
  detection to the long-lived owner lifecycle the current soak tests never
  reach.

## Future, trigger-gated

- [`future/incident-evidence-compiler.md`](future/incident-evidence-compiler.md)
  defines the first business-facing reference application — a read-only
  incident-evidence compiler with fail-closed citations — and the staged
  benchmark that turns it into release evidence.
- [`future/mcp-compose-gateway.md`](future/mcp-compose-gateway.md) designs the
  inbound MCP gateway for serving governed compound tools — static
  one-application-one-tool serving, bounded client-authored evaluation, and
  content-addressed tool handles with gated promotion — on the completed
  stable-CLI seam.
- [`future/mcp-dcr.md`](future/mcp-dcr.md) retains the deprecated Dynamic Client
  Registration compatibility state machine until a concrete server that lacks
  CIMD and practical pre-registration creates an implementation trigger.
- [`future/mcp-oauth-durable-store.md`](future/mcp-oauth-durable-store.md)
  retains the encrypted persistent-adapter conformance work until a concrete
  hosted or embedding store exists to make that protocol representative.
- [`future/mcp-exact-resources.md`](future/mcp-exact-resources.md) records the
  unmet first-party trigger and minimum authority shape required before MCP
  exact-resource work can begin.
- [`future/launcher-repository-extraction.md`](future/launcher-repository-extraction.md)
  records the prerequisites and migration sequence for moving the independently
  released native launcher companion into its own Git repository. Extraction
  is not scheduled while core and launcher protocol changes still benefit from
  atomic commits.
- [`future/reqllm-removal.md`](future/reqllm-removal.md) records the trigger
  and required adapter shape for replacing the optional `req_llm`/`llm_db`
  closure with a direct `Req` adapter for OpenAI-compatible endpoints.

Plans are disposable staging contracts, not API references. When a slice
lands, move its durable behavior into module documentation and the relevant
guide or specification, update any remaining plan status, and delete a plan
that has no approved work left.
