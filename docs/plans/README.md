# Implementation plans

This directory contains active, partially completed, and explicitly
trigger-gated future plans. Completed implementation records are removed; Git
history preserves them. Current architecture belongs in the
[Kernel maintainer guide](../maintainers/kernel.md), exact runtime
contracts belong in the owning module documentation, and user-facing behavior
belongs in guides or retained specifications.

## Local gates

- [`faster-hooks.md`](faster-hooks.md)
  records measured warm times for the git pre-commit hook, `mix precommit`,
  and git pre-push, and the slices that can still shrink them. `mix precommit`
  is quality-only (slice 3). The serial test floor is the remaining way to
  make push substantially faster; `command_engine_test.exs` is split.

## Remaining Kernel product work

- [`lisp-kernel/promote-authored-component.md`](lisp-kernel/promote-authored-component.md)
  closes the loop from model-authored runtime source to an attested component:
  host-side materialization, descriptor provenance, and a promotion gate.
- [`lisp-kernel/stable-cli-contract.md`](lisp-kernel/stable-cli-contract.md)
  retains only the unfinished macOS/container distribution and final
  acceptance work for the completed standalone command.
- [`lisp-kernel/product-readiness.md`](lisp-kernel/product-readiness.md)
  tracks the remaining command-line, diagnostics, model-boundary,
  distribution, and release work.
- [`lisp-kernel/real-flow-e2e-hardening.md`](lisp-kernel/real-flow-e2e-hardening.md)
  tracks the unfinished private-sink, overflow, real-pagination, and
  cache-usage journeys.
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
- [`future/ptc-lisp-library-extraction.md`](future/ptc-lisp-library-extraction.md)
  records the measured boundary, the unconditional boundary-cleanup slice,
  and the trigger-gated plan for extracting the PTC-Lisp implementation into
  a nested Mix library. A separate Git repository is explicitly not planned
  while language and Kernel changes still benefit from atomic commits.
- [`future/reqllm-removal.md`](future/reqllm-removal.md) records the trigger
  and required adapter shape for replacing the optional `req_llm`/`llm_db`
  closure with a direct `Req` adapter for OpenAI-compatible endpoints.

Plans are disposable staging contracts, not API references. When a slice
lands, move its durable behavior into module documentation and the relevant
guide or specification, update any remaining plan status, and delete a plan
that has no approved work left.

## Active documentation work

- [`documentation-product-onboarding.md`](documentation-product-onboarding.md)
  restructures the README and published documentation around executable and
  container onboarding, short end-user guides, retained references, explicit
  maintainer boundaries, package usage rules, and controlled improvement from
  run evidence.
