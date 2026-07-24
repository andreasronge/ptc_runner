# Real-flow E2E hardening

**Status:** active, partially implemented; reviewed 2026-07-24.

This plan retains only the real-flow gaps that remain after the Kernel
integration work. Deterministic unit and integration tests remain the
authority for confinement and lifecycle correctness; these journeys prove that
the same boundaries survive realistic artifact sizes, Viewer pagination, and
provider metadata.

## Implemented baseline

The following former slices are complete and documented by their owning
modules, tests, workflows, and the
[Kernel maintainer guide](../../guides/kernel-maintainer.md):

- credential-free direct and provider-backed remote MCP E2E flows;
- REPL manifest assembly with the same reserved workflow runtime tools as
  normal runs;
- the scheduled/manual `:e2e` workflow and its skip/instrumentation contract;
- strict inspection-destination preflight before provider activity;
- V2 mission-inventory call forms, shared by Runner and REPL and exercised by
  a prompt-inspecting scripted provider; and
- clean shipped-agent annotations with zero protocol errors.

These are no longer active planning items.

## Remaining gap 1: private sinks, overflow, and real pagination

The private canonical event policy, bounded loss accounting, and Viewer cursor
logic have focused coverage, but the repository still lacks one realistic
journey connecting each complete path.

Add deterministic host-driven journeys that:

1. run with the private event policy, prove the `.private.jsonl` destination
   is mode `0600` before content, prove ordinary directory discovery and the
   normal Viewer omit it, and prove only an explicit private grant can read
   it;
2. lower the normal event budget enough for terminal usage to contain
   non-empty `events_dropped`, then prove the Viewer presents those counts
   instead of implying a complete trace; and
3. spread calls across several bounded capability names to retain more than
   200 canonical events under installed defaults, then prove eager multi-page
   fetch is complete and a separately lowered Viewer page budget produces
   explicit partial labeling.

Pagination must not be tested by raising production ceilings or by accepting
invalid fixtures. The run must pass the same canonical validation and query
path as normal traces.

## Remaining gap 2: cache-usage diagnosis

Live runs with `"cache": true` have so far reported `cache_read: 0`. A zero may
be legitimate, but the current normalization does not yet prove the nested
OpenRouter-style
`usage.prompt_tokens_details.cached_tokens` path. Top-level
`cached_tokens` and nested cache-write metadata have separate focused
coverage.

Complete this in order:

1. add a focused adapter regression for nested
   `usage.prompt_tokens_details.cached_tokens` and normalize it into
   `cache_read`;
2. issue two bounded live requests sharing a sufficiently large prompt prefix
   and record the normalized provider result; and
3. if the provider reports non-zero reads, extend the Viewer journey to render
   them from real data; otherwise document that a legitimate zero is
   provider/model dependent and do not retry indefinitely.

## Recorded non-defect

Pure PTC-Lisp computation normally reaches deterministic loop or evaluator
heap limits before the outer capability-worker `timeout` or process-level
`memory_exceeded` statuses. Reaching those outer statuses requires a
deliberately slow or allocation-heavy capability. This is expected boundary
ordering, not a missing pure-computation test.

## Delivery and acceptance

The private/overflow/pagination journeys are the release-hardening priority.
Cache diagnosis may follow independently because a provider returning zero
cache reads is not a correctness failure.

This plan is complete when:

- a private-policy journey proves permissions, omission, and explicit access;
- one real trace contains non-empty loss accounting rendered by the Viewer;
- one valid run above 200 events renders completely across pages and is
  clearly labeled partial under a lower page budget;
- nested cached-token normalization has a regression test; and
- the live cache outcome is either rendered from real non-zero metadata or
  documented as a legitimate provider limitation.

Before deleting this plan, keep exact normalization behavior in
`PtcRunner.LLM.ReqLLMAdapter` documentation, keep event policy and loss
semantics in their owning Kernel module docs, and retain only the high-level
E2E contract in the maintainer guide.
