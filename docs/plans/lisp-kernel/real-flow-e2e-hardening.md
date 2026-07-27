# Real-flow E2E hardening

**Status:** active; reviewed 2026-07-27.

Focused tests cover private event policy, bounded loss accounting, Viewer
cursors and partial labeling, and provider usage normalization. This plan
contains only the missing realistic journeys that must connect those
implemented pieces.

## 1. Private sinks, overflow, and real pagination

Add deterministic host-driven journeys that:

1. run with private event policy, prove the `.private.jsonl` destination is
   mode `0600` before content, prove ordinary directory discovery and the
   normal Viewer omit it, and prove only an explicit private grant can read
   it;
2. lower the normal event budget enough for terminal usage to contain
   non-empty `events_dropped`, then prove the Viewer presents those counts
   instead of implying a complete trace; and
3. spread calls across several bounded capability names to retain more than
   200 canonical events under installed defaults, then prove eager multi-page
   fetch is complete and a separately lowered Viewer page budget produces
   explicit partial labeling.

Pagination must not be tested by raising production ceilings or accepting
invalid fixtures. The run must pass normal canonical validation and the same
query and rendering paths as an ordinary trace.

## 2. Cache-usage diagnosis

Live runs with `"cache": true` have so far reported `cache_read: 0`. A zero may
be legitimate, but normalization does not yet cover the nested
OpenRouter-style
`usage.prompt_tokens_details.cached_tokens` path. Top-level `cached_tokens`
and nested cache-write metadata have focused coverage.

Complete this in order:

1. add a focused adapter regression for nested
   `usage.prompt_tokens_details.cached_tokens` and normalize it into
   `cache_read`;
2. issue two bounded live requests sharing a sufficiently large prompt prefix
   and record the normalized provider result; and
3. if the provider reports non-zero reads, extend the Viewer journey to render
   them from real data; otherwise document that zero is provider/model
   dependent and do not retry indefinitely.

## Delivery and acceptance

The private/overflow/pagination journeys are the release-hardening priority.
Cache diagnosis may proceed independently because a provider returning zero
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
