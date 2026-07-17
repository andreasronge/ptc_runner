# Real-flow e2e hardening

Status: planned, not implemented, except the parts included in the current
change set: the remote MCP e2e tests plus the MCP interop fixes they forced
(schema dialect handling, vendor-annotation policy, tool-entry forward
compatibility, and task-support parsing). Created 2026-07-17 from a
real-flow audit of the branch (live provider runs, generated traces and
inspection artifacts, and live Viewer checks).

This plan closes the gap between the branch's boundary-heavy unit/property
coverage and what actually happens in end-to-end flows with real providers.
The audit found two defects that only real flows expose, plus several
boundaries that have never been exercised outside fixtures.

## Findings driving this plan

### The REPL cannot load any manifest that uses the shipped agent stack

`mix ptc.repl --manifest ptc.json` is a documented flow. It fails with
`prelude_attach_failed: export workflow.event/annotate requires granted tool
workflow-annotate` for every manifest whose workflow bundle includes
`agent.core` — which includes every kernel-tutorial and viewer-demo manifest.
`PtcRunner.Kernel.RuntimeTools` grants `workflow-annotate` only on the
Runner's workflow path; the REPL session assembles the same bundle without
that grant, and fail-closed prelude attach (correctly) rejects the missing
requirement.

The fix belongs in the REPL's manifest mode: when reusing a manifest's
workflow bundle, grant the same workflow runtime tools the Runner grants, so
one bundle has one meaning. Weakening fail-closed attach is not an option.

### Excluded e2e tests rot silently

`test/ptc_runner/kernel/deepseek_e2e_test.exs` was broken by the provider
resource-lifecycle change (`ProviderRegistry.build/4` now returns
`%{capabilities, snapshot, close}`, not a bare capability) and nobody noticed:
`:e2e` is excluded by CI, `mix precommit`, and `mix prepush`. The call-shape
fix landed during the audit; the process gap remains. Real-provider tests
need a scheduled or pre-release execution path, or they will rot again.

### Real remote MCP transport was never exercised — and rejected every server

The branch rewrote MCP transport lifecycle (`MCPSource`, `MCPLease`) and its
only executions were the protocol-faithful loopback fixture and
`mcp_source_test.exs`. Building the remote e2e revealed that the source could
not connect to **any** probed public server:

- DeepWiki: schemas rejected (`x-fastmcp-wrap-result` vendor key from the
  FastMCP framework);
- Cloudflare docs: schemas rejected (`$schema` dialect marker, emitted by the
  official SDKs by default);
- Context7: schemas rejected (`$schema`), tool entries rejected
  (spec-standard `title` and `execution` fields);
- Microsoft Learn: correctly rejected — it negotiates protocol `2025-06-18`
  against the pinned `2025-11-25`.

The interop fixes included in the current change set, all test-first:

- `PtcRunner.Kernel.JSONSchema` treats a root `$schema` as what it is — the
  dialect selector. Absence means the MCP default (2020-12); the allowlisted
  2020-12 and draft-07 URIs are accepted (the bounded profile is a common
  subset of both) and removed; unknown, malformed, and nested markers are
  rejected. Vendor `x-…` extension keys are discarded from every level as a
  deliberate client policy. Neither reaches normalized output, encodings, or
  hashes, and semantic keywords such as `anyOf` and `default` remain
  rejected.
- `MCPSource` ignores genuinely unknown tool-entry fields (`title`, `_meta`,
  vendor metadata) per MCP forward compatibility, but parses the known
  `execution` field: absent, `"forbidden"`, and `"optional"` task support
  execute as ordinary calls, `"required"` fails assembly with the stable
  `:mcp_tool_task_required` error (this synchronous client does not
  implement task invocation), and malformed pinned-protocol values are
  rejected as `:mcp_invalid_catalog`.

Version pinning is intentionally unchanged.

### Bare capabilities advertise no invocation syntax

The live agent flow exposed a prompt-content gap: the frozen mission
inventory lists capability names and schemas but no call form, and prelude
exports are the only entries carrying a `call` shape. A live model given a
bare `docs.resolve` capability invented `(tool-call …)`, `(call …)`, and
`(json-object …)` across turns and never produced `(tool/docs.resolve …)` —
even when the task spelled it out. The supported pattern is a prompt-visible
mission wrapper export (as the tutorial and inspection lab use), which the
delivered agent e2e follows. Closing this is planned work item 6.

### Boundaries never exercised with real data

- The private canonical event policy (`.private.jsonl` writing: `0600`
  restriction, fail-closed sink behavior) has unit coverage but no end-to-end
  journey; only read-side discovery omission was verified live.
- `events_dropped` accounting has never been observed in a real trace; no
  flow lowers the event budget far enough.
- No real run exceeds 100 canonical events, so the Viewer's multi-page turn
  fetch and partial-run labeling rest solely on synthetic fixtures. A single
  capability name is capped at 32 mission calls, but installed defaults
  allow 128 mission calls across names and 256 retained normal events, so a
  deterministic journey spreading calls over four bounded capability names
  can cross 200 events under supported production configuration — no raised
  ceilings required.

### Observed non-defects worth recording

- Pure computation cannot reach the canonical `timeout` or process-level
  `memory_exceeded` evaluation statuses: the deterministic loop bound and the
  in-evaluator heap budget fire first as `evaluation_error`. Reaching those
  statuses requires a deliberately slow or allocation-heavy capability. This
  is by design and belongs in the maintainer guide, not a bug list.
- `"cache": true` on the `llm` provider yielded `cache_read: 0` across all
  live DeepSeek runs. Whether the alias, the provider, or the upstream lacks
  prompt caching is undiagnosed; until it is, Viewer cache display is covered
  only by synthetic fixtures.

## Planned work

### 1. Remote MCP e2e flows (included in the current change set)

Two `:e2e`-tagged tests run against a fixed public read-only MCP endpoint
(default `https://mcp.context7.com/mcp`, overridable via
`PTC_TEST_MCP_ENDPOINT`):

- `mcp_remote_e2e_test.exs` — a direct Kernel run granting one discovered
  remote tool to the workflow environment and calling it from a fixed
  program: real session initialization and echo, discovery, schema
  compilation of real SDK output, SSE result handling, and lease cleanup;
- `mcp_remote_agent_e2e_test.exs` — a full manifest agent flow
  (`RunBuilder.run` with an injected registry): live DeepSeek plans a
  program that calls the remote MCP tool through a prompt-visible mission
  wrapper, with `--trace`/`--inspect` artifacts written and audited in-test
  for endpoint, session-ID, and header absence.

Assertions cover the connector snapshot (provider, protocol, public tool
names, schema hashes), capability start/stop events, and scrubbing of
transport facts from canonical events and inspection records. The tests skip
without the required environment (API key for the agent flow) and fail loudly
on protocol or lifecycle regressions.

### 2. REPL manifest runtime-tool grants

1. Failing regression test: `mix ptc.repl --manifest` (or the underlying
   `ReplSession` manifest mode) with a workflow bundle including `agent.core`
   must attach successfully and evaluate one expression.
2. Grant the Runner's workflow runtime tools in the REPL's manifest mode from
   one shared definition, so Runner and REPL cannot drift.
3. Keep mission-side assembly unchanged; the REPL gains no annotation
   authority beyond what a Runner-executed manifest already has.
4. Verify the REPL trace still renders in the Viewer.

### 3. Scheduled e2e execution

This item depends on the shipped-agent annotation vocabulary fix owned by
`viewer-ready-run-observability.md`: today every agent turn records a failed
`workflow-annotate` call and one protocol error, so the agent e2e cannot yet
assert clean instrumentation. That fix must land first; the agent e2e then
adds `usage.protocol_errors == 0` and no-failed-instrumentation assertions
before the schedule becomes the rot guard.

1. Add a CI workflow (scheduled and manually dispatchable) running
   `mix test --include e2e` with the provider key from repository secrets.
2. Keep e2e excluded from push/PR pipelines; the schedule is the rot guard.
3. Document the tag's contract in the testing section of the maintainer
   guide: anything tagged `:e2e` must skip cleanly without its environment
   and must not depend on fixture-only state.

### 4. Private-sink and overflow journeys

1. Extend the inspection lab (or add a sibling host script) with one journey
   that runs under the private event policy: assert the `.private.jsonl`
   destination is `0600` before content, normal directory discovery and the
   live Viewer omit it, and a separate explicit private grant reads it.
2. Add one journey with a deliberately small event budget so `run-stopped`
   reports non-empty `events_dropped`, and assert the Viewer renders the
   drop counts rather than presenting a silently truncated run.
3. Add one deterministic journey spreading calls across four bounded
   capability names to produce a run above 200 canonical events under
   installed default limits, and verify the Viewer's eager multi-page fetch
   and (with a lowered page budget) its partial labeling against real data.
   Staying under the 256 retained normal events keeps the run complete;
   pagination must not be conflated with custom ceilings.

### 5. Cache-usage diagnosis

1. Unit-test the normalized token seam first: OpenRouter reports cache reads
   under `usage.prompt_tokens_details.cached_tokens`, and the provider
   normalization must map that field into the normalized `cache_read` count.
2. Then run two live requests sharing one sufficiently large prompt prefix
   and compare reported cache reads. A legitimate zero remains an acceptable
   outcome and is documented with the `llm` provider rather than retried
   indefinitely.
3. When real cache counts exist, extend the viewer-demo journeys so cache
   tiles and columns render from real data.

### 6. Capability invocation syntax in the frozen inventory

1. Bump the frozen mission inventory schema from V1 to V2, adding an exact
   `call` form (for example `(tool/NAME {…})`) to every bare capability
   entry, mirroring the `call` field prelude exports already carry.
2. Add golden and hash tests: the rendered inventory, its byte count, and
   `mission_inventory_hash` change together and deterministically.
3. Prove Runner and REPL emit the identical V2 inventory from one shared
   renderer.
4. Add a scripted-model journey that drives a bare capability directly from
   the advertised `call` form — no prompt-visible wrapper — proving the
   inventory alone is sufficient for correct invocation.

## Non-goals

- Weakening fail-closed prelude attach, sanitization, or scrubbing to make
  flows pass.
- Making e2e tests part of push/PR gates.
- Building a general MCP conformance suite or supporting non-pinned protocol
  versions; version negotiation policy is out of scope here.
- Forcing canonical `timeout`/`memory_exceeded` statuses from pure
  computation.
- Standing up authenticated MCP servers; the public read-only endpoint is
  deliberate so the suite stays credential-free.

## Delivery sequence

1. Remote MCP e2e tests and interop fixes (the current change set).
2. REPL manifest runtime-tool grants with its regression test.
3. Capability invocation syntax in the frozen inventory (V2).
4. Agent-e2e instrumentation assertions (after the annotation vocabulary fix
   from `viewer-ready-run-observability.md`), then the scheduled e2e CI
   workflow and maintainer-guide testing contract.
5. Private-sink, events-dropped, and multi-page journeys.
6. Cache-usage diagnosis and demo extension.

## Acceptance gate

- Both remote MCP e2e tests pass against the default public endpoint and
  skip cleanly without their environment.
- `mix ptc.repl --manifest examples/kernel-tutorial/03-file-agent/ptc.json`
  starts, evaluates an expression, and its trace renders in the Viewer.
- After the annotation vocabulary fix lands, the agent e2e asserts
  `usage.protocol_errors == 0` and no failed workflow instrumentation calls.
- A scripted-model journey invokes a bare capability correctly from the V2
  inventory `call` form alone, with matching inventory golden and hash tests
  and identical Runner/REPL rendering.
- The scheduled e2e workflow has at least one green run including the
  DeepSeek and MCP flows.
- A private-policy journey produces a `0600` `.private.jsonl` invisible to
  normal discovery and the live Viewer.
- A real trace shows non-empty `events_dropped` and the Viewer surfaces it.
- A real run above 200 events renders completely through the Viewer's eager
  page fetch, and partial labeling appears when the page budget is lowered.
- Cache display either renders real nonzero counts or the limitation is
  documented where the `llm` provider is documented.

## Documentation migration when implemented

This file is a disposable plan. Before deleting it:

- move the REPL runtime-tool grant contract into the REPL task/module docs
  and the maintainer guide;
- move the `:e2e` tag contract and schedule into the maintainer guide's
  testing section;
- record the pure-computation limit-status behavior in the maintainer guide;
- record the cache-usage outcome with the `llm` provider documentation; and
- keep remote-endpoint details only in the e2e test and its module doc.

Remove this plan and its plans-index entry once those retained contracts and
their tests are in place.
