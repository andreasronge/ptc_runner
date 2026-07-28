# MCP write support and bounded client surfaces

**Status:** active; the protocol baseline is reconciled and the effect-aware
Dispatcher foundation is implemented, but MCP write authority remains
unapproved. Revised 2026-07-28 against the final MCP `2026-07-28` tag at
`modelcontextprotocol/modelcontextprotocol@5f5440bb26a62e2cf3440b92da5a667efa03b267`.

PtcRunner installs MCP sources read-only. Every mapped tool must declare
`effect: "read"`, and the source rejects writes outright. This plan covers the
smallest safe change that permits write-effect tools, the remaining HTTP
cancellation gap, and the authority decision required before adding other MCP
client surfaces.

Backward compatibility is not a constraint. PtcRunner is a 0.x library and
should delete obsolete restrictions rather than preserve compatibility shims.
The hard parts are semantic: what constitutes authorization to mutate, what a
timeout means after a write may have arrived, and how an operator freezes
authority over server-owned prompt and resource namespaces.

## Goals

- Allow an operator to install and select a write-effect MCP tool without
  making an indeterminate write look safely retryable.
- Preserve read-only provider assembly: discovery and snapshot identity must
  never mutate external state.
- Verify protocol-correct request cancellation for Streamable HTTP.
- Record a bounded authority model for future MCP resources before adding any
  new runtime surface.
- Keep server-initiated model access permanently unavailable.

## Non-goals

- No automatic retry or deduplication of writes.
- No trust in server-supplied tool annotations. Effect remains
  operator-declared in the host document.
- No per-call human approval mechanism. Host installation plus manifest
  selection is standing authorization for mission code to invoke the selected
  write capability. `--check` must make that grant conspicuous.
- No raw server namespace exposed through a generic prompt name, resource URI,
  URI template, or completion reference.
- No change to the frozen-catalog model. Discovery still happens once per run
  build.
- **Server-initiated model access will not be supported.** See section 5. This
  is a permanent design position, not deferred work.

## Current state

Established by reading the implementation on 2026-07-28. Recorded so a later
slice does not re-derive it.

### Specification release check

The final `2026-07-28` release and dated schema were published at
2026-07-28 16:47 UTC. The final tag was compared with the draft commit used for
this plan,
`7d6c7b86eb2f1442051849ca76429fde3c3008b0`. The post-RC protocol details that
matter to PtcRunner remain:

| Post-RC change | PtcRunner consequence |
| --- | --- |
| `io.modelcontextprotocol/serverInfo` moved from the `server/discover` result body to optional result `_meta` on every response | Already aligned: discovery reads the result metadata and treats absent or invalid identity as unavailable |
| `io.modelcontextprotocol/clientInfo` changed from required to SHOULD on each request | Already aligned: PtcRunner continues to send it, which remains valid |
| Cancellation became explicitly transport-specific | Confirms section 3: stdio sends `notifications/cancelled`; HTTP closes the response stream |
| `Mcp-Name` gained the Base64 sentinel encoding used by `Mcp-Param-*` | Already aligned through `MCPProtocol.encode_header/1` |
| `x-mcp-header` is valid only on statically reachable property paths and its emission is independent of cache TTL | Already aligned by the bounded property-path scan and unconditional request-time projection |
| Draft-specific error codes moved to `-32020..-32022` | No current literal-code dependency; PtcRunner classifies JSON-RPC errors structurally |
| `InputRequiredResult` permits `requestState` without `inputRequests` | Section 5 must validate this as structurally valid before applying PtcRunner's policy refusal |
| `subscriptions/listen` gained a graceful terminal result and stricter acknowledgement ordering | No immediate work because subscriptions remain deferred |

Final-release reconciliation:

| Final delta from the recorded draft | Classification | PtcRunner consequence |
| --- | --- | --- |
| Draft specification links were promoted to the dated `2026-07-28` paths | Plan-only change | This plan and future reviews now cite the final tag; no runtime behavior changes |
| `SubscriptionsListenResultResponse` was added and `SubscriptionsListenResultMeta` was renamed to `SubscriptionsListenResultMetaObject` | No impact | PtcRunner does not implement subscriptions; the surface remains deferred |
| Cancellation, MRTR, stdio, Streamable HTTP, discovery, tools, and caching retained their normative draft behavior | No impact | The transport and policy conclusions in this plan remain valid |
| Final-baseline review exposed the existing requirement that every page of one list operation use the same `cacheScope`; `ttlMs` may differ by page | Code change | Catalog reduction now carries the first page's scope and rejects mixed-scope pagination |
| The official Go SDK [released `v1.7.0`](https://github.com/modelcontextprotocol/go-sdk/releases/tag/v1.7.0), two commits after the pinned pseudo-version | Code change | The interoperability harness is pinned to `v1.7.0`; the two SDK commits update conformance data and fix a Streamable HTTP nil dereference |

The dated schema is now the authoritative fixture source for protocol-facing
tests. The final release introduced no new PtcRunner runtime prerequisite.

### Effects and retry safety

The Kernel already models and resolves effects end to end:

| Fact | Location |
| --- | --- |
| Effect vocabulary is `:read \| :write \| :unknown`, default `:unknown` | `capability.ex:30`, `:43` |
| Actual non-read capability activity forbids whole-evaluation retry | `evaluation.ex:582` |
| Mission inventory joins an export's static metadata with effects of its frozen capability dependencies | `mission_inventory.ex:283` |
| A regression already covers a read-declared wrapper around an installed write capability | `mission_inventory_test.exs:136` |
| Effect appears in the safe provider snapshot | `mcp_source.ex:834` |

`Prelude.Compiler` uses `:read` as a context-free hint for an export that
references a tool. That is not the runtime authority seam: `MissionInventory`
resolves the effective effect against the installed mission capabilities, and
`Evaluation` classifies retry safety from the capabilities actually invoked.
Write support must not make the provider-independent compiler depend on a host
installation.

`Dispatcher` now classifies every mission failure produced after callback
invocation with `Capability.effect` and trusted provider dispatch provenance.
Read failures retain their provider policy; write and unknown failures after
possible dispatch are non-retryable and carry the orthogonal
`mutation_state: :indeterminate` field. Workflow provider policy remains
independent. The remaining per-call work for MCP writes is to make `MCPSource`
populate the shared mutation state and provenance from its transport boundary.

### Read-only MCP installation

Read-only is enforced at these MCP installation sites:

| Site | Lock |
| --- | --- |
| Generated host JSON Schema | `"effect": {"const": "read"}` |
| `HostConfig` | tool type, decoding, and normalized mapping fix `:read` |
| `MCPSource` installation | mapping normalization accepts only `:read` |
| `MCPSource` assembly and snapshot | capability and snapshot hardcode `:read` |
| Host configuration guide | documents effect as always `read` |

`snapshot_identity` names one installed tool and is invoked automatically with
an empty argument map while the provider is assembled, even when that tool is
not selected into the mission. Today that is safe only because every mapping
is read-only.

### Protocol surface

Avoid a single method count: the protocol mixes client requests,
notifications, and server-initiated requests. The relevant disposition is:

| Surface | Current disposition |
| --- | --- |
| `server/discover`, `tools/list`, `tools/call` | implemented |
| stdio `notifications/cancelled` | implemented on timeout and caller death |
| Streamable HTTP cancellation | incomplete; must close the request's response stream |
| `prompts/list`, `prompts/get` | deferred pending a first-party interactive use |
| `resources/list`, `resources/read`, `resources/templates/list` | authority design required before implementation |
| `completion/complete` | deferred pending a first-party interactive use |
| subscriptions, list-change notifications, progress, and request-scoped logging | deferred |
| sampling, elicitation, and roots through MRTR | refused |

Every result currently passes through `MCPProtocol.outcome/2`.
`InputRequiredResult` is already rejected generically as
`:mcp_unsupported_result`; the remaining improvement is method-sensitive
validation and classification, not initial enforcement.

## 1. Unlock write effects without mutating during assembly

Widen installed tool mappings from a fixed `:read` to the operator-declared
enum `read | write`. `:unknown` remains unavailable in a host document: an
operator granting a tool must classify its authority deliberately.

Update the generated schema, `HostConfig`, `MCPSource`, safe provider snapshot,
`--check` projection, tests, and durable host-configuration documentation
together. Server annotations remain ignored.

Before any transport is acquired, validate that a tool referenced by
`snapshot_identity` has declared effect `read`. Repeat the validation inside
`MCPSource.builder/1` so direct callers cannot bypass the host decoder. A write
identity is invalid configuration, not a provider failure.

`--check` must visibly distinguish selected write capabilities from reads.
Installation plus manifest selection constitutes standing authorization; there
is no hidden approval prompt at invocation time.

Write authority must never arrive through the current implicit “allow every
installed mapping” default. If an MCP installation contains any `write`
mapping, its manifest selection must contain an explicit, non-empty `allow`
list. Every selected write name therefore appears in model-authorable
application text. Adding a write mapping to an existing host installation makes
an unchanged implicit selection fail closed rather than silently widening it.
Keep the existing omitted-`allow` convenience only for installations whose
mapped tools are all `read`, and enforce this rule in both host-installation
selection and direct `MCPSource` selection.

Acceptance:

- an operator can install and select a write tool;
- every write-bearing installation requires an explicit manifest `allow`, and
  adding a write to an existing read-only installation cannot widen unchanged
  manifests;
- a manifest can narrow selection and model visibility but cannot change the
  installed effect;
- `--check` and the safe provider snapshot report the effective write grant;
- a write mapping cannot be used as `snapshot_identity`;
- rejection of a write identity occurs before credential resolution, transport
  acquisition, discovery, or any RPC; and
- server annotations cannot widen or narrow the operator-declared effect.

## 2. Make per-call failure semantics effect-aware

A timeout, transport loss, or callback-process exit after dispatch does not
prove whether a write happened. Cancellation does not change that fact.

The Dispatcher mission boundary is already effect-aware. `MCPSource` must now
classify request failures with the mapped tool's declared effect and trusted
transport dispatch provenance.

Do not apply this rule blindly to workflow capabilities. In particular,
`llm-request` deliberately has `effect: :unknown` while its trusted provider
classifies some availability failures as retryable; the workflow agent owns
that retry policy. The Dispatcher preserves that contract. A later proposal
may replace the LLM's coarse effect with a more precise capability semantic,
but MCP write support must not change it as a side effect.

For a read capability, the existing retryable timeout and transport semantics
remain. For `write` or `unknown`, a failure after remote dispatch may have
begun is non-retryable and explicitly classified as an indeterminate outcome.
The public Dispatcher envelope represents that state independently from the
diagnostic cause with the bounded `mutation_state: :indeterminate` field while
preserving `kind` and `reason` as the specific timeout, domain, protocol,
validation, or transport diagnosis. Successful calls and failures proven to
occur before dispatch omit the field. Do not encode mutation state as a
replacement error kind or only in prose.

Callback entry is not the dispatch boundary. Header-parameter projection,
outbound-header validation, a request context already being closed, and other
deterministic local checks can fail after the callback starts but before bytes
can reach the transport. Carry a bounded internal dispatch provenance on
provider failures (`not_dispatched | possibly_dispatched`). `MCPSource` sets
`not_dispatched` only for a path that proves no transport send was attempted;
once the HTTP request operation begins or a stdio request write may have been
accepted, it uses `possibly_dispatched`. Dispatcher may omit mutation state for
a non-read failure only when trusted provider provenance proves
`not_dispatched`. Missing provenance, callback exit/crash, timeout, or a
Dispatcher-generated replacement after callback entry remains conservative:
`possibly_dispatched`. Do not expose transport internals in the public
envelope.

Known failures that prove no invocation occurred, such as argument validation
or capability denial, retain their existing specific classifications. Do not
derive idempotency from `idempotentHint`: it is server-supplied, defaults to
false, and is outside the operator-owned authority contract.

For a non-read call, every non-success received after dispatch must remain
non-retryable: JSON-RPC errors, tool `isError` results, malformed or oversized
responses, and unsupported alternate results as well as transport failures.
Preserve the specific diagnostic cause, but separately mark the external
mutation state indeterminate unless the protocol proves the tool was not
invoked. A syntactically complete error response does not prove rollback.

The existing evaluation-level effect ledger remains authoritative for
whole-evaluation correction. No compiler change is required. Add an MCP
integration regression showing that an undeclared prelude wrapper around a
mapped write tool projects as `write` and suppresses whole-evaluation retry
through the existing `MissionInventory` and `Evaluation` seams.

Acceptance:

- a read timeout remains retryable;
- write and unknown mission timeouts, transport losses, callback exits, and
  callback crashes after possible dispatch are non-retryable and indeterminate;
- deterministic parameter-header, outbound-header, and closed-context failures
  proven to precede transport dispatch preserve their cause without claiming an
  indeterminate mutation;
- forwarded provider errors without trusted `not_dispatched` provenance,
  oversized or schema-invalid results, arbitrary callback returns, run closure
  after callback completion, and inspection-output failures preserve their
  cause while reporting indeterminate mutation state for non-read calls;
- JSON-RPC errors, tool `isError` results, malformed or oversized responses,
  and unsupported alternate results preserve their cause while reporting
  indeterminate mutation state for non-read calls;
- the Dispatcher cannot overwrite a non-retryable MCP result with a retryable
  outer timeout;
- cancellation is never treated as proof that a write did not happen; and
- an export wrapping a write tool reports the installed write effect without
  injecting host knowledge into `Prelude.Compiler`.

The remaining MCP changes in sections 1 and 2 are one atomic write-support
slice.

## 3. Complete Streamable HTTP cancellation

Cancellation is transport-specific:

- stdio uses `notifications/cancelled`; this is already implemented and covered
  for timeout and caller death;
- Streamable HTTP cancels by closing that request's response stream. It must
  not send `notifications/cancelled`.

Current HTTP code kills the local Req task when its deadline expires, and Req
also halts a response stream after a complete SSE response, an oversized body,
or an SSE parser error. Existing tests prove the caller returns, but not that
the server observes a disconnected response stream. Add a live loopback
integration harness that records the disconnect and covers timeout, caller
death, run/provider close, and every early `{:halt, ...}` response path. If task
termination or Req stream halt does not reliably close the stream, introduce an
explicitly owned, cancellable streaming request handle.

Cancellation is advisory and races with server execution. Write calls that are
cancelled after dispatch remain indeterminate and non-retryable.

Acceptance:

- the server observes its Streamable HTTP response stream close after timeout,
  caller death, provider close, a complete SSE response, response-size
  rejection, and SSE parser rejection;
- no HTTP cancellation notification is emitted;
- stdio cancellation behavior remains unchanged; and
- repeated cancellation leaves no request tasks, response streams, or
  descriptors behind.

This slice is independent from write support.

## 4. Authority gate for additional client surfaces

Prompts, resources, and completion are not interchangeable with tools:

- prompts are server-authored text normally selected by a user;
- resources occupy a server-controlled URI namespace and may change after
  discovery;
- completion is an interactive utility over prompt or resource references.

Exposing their raw list/read/get operations would let the server determine
runtime authority after the host document was frozen. Therefore no additional
surface is implementation-approved until its host grammar answers:

- what exact upstream names, URIs, or templates the operator grants;
- how each grant maps to a bounded public capability name;
- which entries may be model-visible;
- which aggregate catalog, page, argument, and result ceilings apply;
- how duplicates and changes between discovery and invocation fail closed;
- what metadata enters the safe provider snapshot and its hashes;
- whether an MCP installation may be resource-only rather than requiring a
  non-empty tool map; and
- how `Mcp-Name` is emitted for `prompts/get` and `resources/read` over HTTP.

Use the common installed `timeout_ms` and `max_result_bytes` ceilings for calls.
Add family-specific catalog item/page ceilings only where acquisition needs
them; do not create a separate timeout and result ceiling for every method.
Every paginated list operation must carry the first page's `cacheScope` through
the reduction and reject a later page with a different scope; page `ttlMs`
values remain independently variable.
MCP `cacheScope: "private"` limits cache reuse to one authorization context; it
is not a PtcRunner data classification and must not implicitly change
`data_class` or `accepts_data`.

The first acceptable resource shape, when a concrete application needs it, is
an operator mapping of exact upstream resource URIs to public zero-argument
read capabilities. `resources/list` is then assembly-time validation, not a raw
mission capability, and `resources/read` is reachable only through those frozen
mappings. Every returned `ResourceContents.uri` must exactly equal the granted
URI; reject the whole result if any item names another URI. Sub-resources
require their own explicit grants and are not inferred from URI prefixes.
Treat returned prompt or resource text as inert, untrusted result data; never
splice it automatically into workflow or system prompts.

URI-template capabilities require a separate bounded parameter design and stay
deferred. Prompts and completion stay deferred until a first-party interactive
consumer provides requirements. The frozen catalog freezes membership and
contracts, not the external contents returned by a later resource read.

Subscriptions, list-change notifications, progress, and request-scoped logging
also remain deferred. They need bounded push delivery into a deadline-scoped run
and a clear reconciliation story with frozen catalogs.

## 5. Keep server-initiated authority refused

The `2026-07-28` protocol replaces server-initiated roots, sampling, and
elicitation requests with Multi Round-Trip Requests. A server can answer
`tools/call`, `prompts/get`, or `resources/read` with
`InputRequiredResult`.

Supporting a model request would let an MCP server reached through mission code
invoke the workflow's LLM. That violates the two-environment authority split.
Elicitation requires a human while missions are deliberately non-interactive,
and roots presume ambient filesystem scope that PtcRunner replaces with
explicit grants.

PtcRunner declares empty client capabilities and already rejects
`InputRequiredResult`. Harden the existing classifier rather than describing
this as missing support:

- a structurally valid state-only `InputRequiredResult` on one of its permitted
  methods is an explicit, non-retryable policy refusal;
- any `inputRequests` value is a protocol capability-negotiation error while
  PtcRunner declares no elicitation, sampling, or roots capability, even if the
  result is otherwise structurally valid;
- `InputRequiredResult` on any other method is a protocol error;
- a malformed MRTR result is a protocol error; and
- state-only MRTR is never automatically retried, especially after a write.

The classifier must validate the final `2026-07-28` schema requirements before
distinguishing policy refusal from malformed input. Tests must use a valid MRTR
example rather than an empty result object.

Trigger to revisit: a first-party need for host-mediated elicitation, where the
*host*—never mission code and never the model—supplies the response. Sampling
has no trigger.

## Delivery slices and review checkpoints

Review at architectural seams rather than after every commit. Each checkpoint
reviews the complete slice against the stated invariants, resolves all
correctness and authority findings, and runs the slice's focused tests plus
`mix precommit`. Cosmetic findings do not trigger a new review round unless the
fix changes behavior. Dependent slices do not begin from an unreviewed
authority or wire contract.

### Slice 1 — MCP write authority end to end

**Scope**

- Implement sections 1 and 2 across the generated host schema, `HostConfig`,
  `MCPSource`, capability assembly, safe snapshots, manifests, and `--check`.
- Require explicit manifest `allow` for every installation containing a write
  mapping in both selection implementations; retain omitted `allow` only for
  read-only installations.
- Reject a write `snapshot_identity` before credentials, transport acquisition,
  discovery, or RPC.
- Make MCP transport failures use the mapped tool effect, trusted
  pre-dispatch/possible-dispatch provenance, and the shared indeterminate
  outcome.
- Preserve diagnostic causes while making every non-success response after a
  possible write non-retryable with indeterminate mutation state.
- Prove a prelude wrapper around a write tool resolves to write through the
  existing mission-inventory seam.
- Update the `MCPSource` module docs plus
  `docs/guides/host-configuration.md`,
  `docs/guides/manifests-and-capabilities.md`,
  `docs/guides/building-agents.md`, and
  `docs/guides/kernel-maintainer.md` in the same slice. Remove their explicit
  read-only claims and document the explicit write-selection rule.

Do not split configuration enablement from its safety checks or reporting. This
is one atomic merge even if developed as several commits.

**Review checkpoint**

- Trace one read and one write mapping from host JSON through the generated
  schema, normalized installation, capability, `--check`, and safe snapshot.
- Prove an unchanged manifest with omitted `allow` fails closed after a write
  mapping is added, while omitted `allow` retains its read-only convenience.
- Mutation-test the `snapshot_identity` guard and prove rejection occurs before
  any authority-bearing activity.
- Exercise parameter-header validation, outbound-header validation, and a
  closed request context as proven pre-dispatch failures for a write mapping;
  preserve their causes and omit indeterminate mutation state.
- Exercise timeout, transport loss, callback exit, and callback crash for both
  read and write mappings.
- Exercise JSON-RPC errors, tool `isError`, malformed and oversized responses,
  and unsupported alternate results after a possible write.
- Verify server annotations cannot affect the installed effect.
- Run one local stdio write fixture and one independent third-party read server
  to catch regressions outside synthetic unit paths.

### Slice 2 — Streamable HTTP cancellation

**Scope**

- Implement section 3 with a loopback server that observes response-stream
  closure.
- Cover deadline expiry, caller death, provider close, and repeated
  connect/cancel cycles.
- Cover every Req early-halt path: a complete SSE result, an oversized body,
  and an SSE parser error.
- Introduce an explicitly cancellable request owner only if killing the Req
  task does not reliably close the stream.

This slice is independent from write support. Its result never changes the
indeterminate classification of an abandoned write.

**Review checkpoint**

- Review packet-level behavior, not only the Elixir caller result: the server
  must observe the HTTP stream close on cancellation and every early-halt path.
- Confirm HTTP never sends `notifications/cancelled` and stdio behavior remains
  unchanged.
- Run descriptor/task leak stress tests on Linux and macOS.
- Verify cancellation races cannot turn an indeterminate write into a retryable
  failure.

### Slice 3 — MRTR validation and policy refusal

**Depends on:** Slice 1.

**Scope**

- Harden section 5's existing rejection into method-sensitive structural
  validation and policy classification.
- Use valid examples with `inputRequests`, `requestState`, and both together.
- Preserve the permanent refusal of sampling, roots, elicitation, and automatic
  state-only retries.

This slice is independent from cancellation. It follows write support because
its `tools/call` regression must exercise both read and write mappings through
the centralized result classifier.

**Review checkpoint**

- Generate or copy fixtures from the pinned final schema rather than inventing
  approximately valid MRTR objects.
- Cover all three permitted methods and at least one forbidden method.
- Distinguish malformed protocol data, an input-bearing capability-negotiation
  violation, and a structurally valid state-only result refused by policy.
- For `tools/call`, exercise each MRTR classification through both read and
  write mappings; preserve the specific cause and retain indeterminate mutation
  state for the write after dispatch.
- Confirm empty client capabilities never lead to fulfilling an input request
  or automatically retrying a state-only response.

### Slice 4 — exact-resource authority design

**Trigger:** a concrete first-party application that needs MCP resources.

**Scope**

- Decide the operator-owned exact-URI mapping grammar and public capability
  projection described in section 4.
- Require every returned resource item to repeat the exact granted URI; do not
  infer sub-resource authority.
- Decide whether resource-only MCP installations are valid.
- Freeze catalog, pagination, result, snapshot, and change-detection semantics.
- Keep URI templates, prompts, and completion out of this slice.

This is a specification slice. It changes no runtime code.

**Review checkpoint**

- Walk through one allowed URI, one unlisted URI, a catalog change, duplicate
  aliases, a private result, and a resource-only server.
- Prove no generic URI or raw list operation reaches mission code.
- Approve generated-schema shape, safe-snapshot identity, and manifest
  narrowing before implementation begins.
- Reject the slice if its consumer could instead use an ordinary mapped MCP
  tool without losing an important capability.

### Slice 5 — exact-resource mappings

**Depends on:** approved Slice 4.

**Scope**

- Discover and validate operator-granted exact resources during assembly.
- Expose each mapping as a bounded zero-argument read capability.
- Implement `resources/read`, required cache fields, `Mcp-Name`, text-result
  normalization, safe snapshots, and resource-only installations as approved.
- Reject binary/blob content until a separate bounded representation is
  designed.

**Review checkpoint**

- Trace every public resource capability back to one exact host-granted URI.
- Test pagination limits, catalog changes, missing resources, text bounds,
  private cache scope, mixed-scope pagination rejection, varying page TTLs, and
  unsupported content.
- Reject a single mismatched returned URI and a mixed multi-item response where
  only some items match the grant.
- Verify `cacheScope` affects caching semantics only and never reclassifies
  result data.
- Verify a server cannot introduce a new reachable URI after assembly.
- Run an independent third-party resource server over both stdio and HTTP.

Prompts, completion, URI templates, subscriptions, and progress remain
unscheduled. They receive their own plan only after a concrete consumer exists.

## Common acceptance

Every implementation slice must:

- keep effect and namespace authority operator-declared;
- preserve frozen, bounded safe snapshots;
- carry a regression for the unsafe-by-default path, not only the happy path;
- update generated host schemas and durable module/guide documentation with the
  code; and
- pass `mix precommit`.

When a slice lands, move its durable contract into the relevant modules and
guides, then delete its completed material from this plan rather than keeping a
historical checklist.
