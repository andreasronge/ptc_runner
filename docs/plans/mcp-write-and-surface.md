# MCP bounded client surfaces

**Status:** active; MCP write authority, effect-aware failures, Streamable
HTTP cancellation, and MRTR refusal are implemented. Exact-resource authority
design is the next delivery slice. Revised 2026-07-28 against the final MCP
`2026-07-28` tag at
`modelcontextprotocol/modelcontextprotocol@5f5440bb26a62e2cf3440b92da5a667efa03b267`.

PtcRunner supports operator-declared read and write MCP tools while keeping
write selection explicit and post-dispatch failure outcomes conservative. This
plan tracks the authority decision required before adding other MCP client
surfaces.

Backward compatibility is not a constraint. PtcRunner is a 0.x library and
should delete obsolete restrictions rather than preserve compatibility shims.
The remaining hard part is semantic: freezing operator authority over
server-owned resource namespaces.

## Goals

- Record a bounded authority model for MCP resources before adding that runtime
  surface.
- Keep server-initiated model access permanently unavailable.

## Non-goals

- No trust in server-supplied tool annotations.
- No raw server namespace exposed through a generic prompt name, resource URI,
  URI template, or completion reference.
- No change to the frozen-catalog model. Discovery still happens once per run
  build.
- No automatic retry or deduplication of writes.
- **Server-initiated model access will not be supported.**

## Current protocol disposition

The final `2026-07-28` release and dated schema are the authoritative fixture
source for protocol-facing tests. The interoperability harness is pinned to
the official Go SDK `v1.7.0`.

| Surface | Current disposition |
| --- | --- |
| `server/discover`, `tools/list`, `tools/call` | implemented |
| stdio `notifications/cancelled` | implemented on timeout and caller death |
| Streamable HTTP cancellation | implemented by closing the response stream; no cancellation notification |
| `prompts/list`, `prompts/get` | deferred pending a first-party interactive use |
| `resources/list`, `resources/read`, `resources/templates/list` | authority design required before implementation |
| `completion/complete` | deferred pending a first-party interactive use |
| subscriptions, list-change notifications, progress, and request-scoped logging | deferred |
| sampling, elicitation, and roots through MRTR | refused |

The post-RC protocol details relevant to remaining work are:

- every page of one list operation must use the same `cacheScope`, although
  page `ttlMs` values may differ;
- `Mcp-Name` uses the same Base64 sentinel encoding as `Mcp-Param-*`; and
- server identity is optional result metadata and client identity remains
  valid on each request.

## 1. Authority gate for exact resources

Prompts, resources, and completion are not interchangeable with tools:

- prompts are server-authored text normally selected by a user;
- resources occupy a server-controlled URI namespace and may change after
  discovery; and
- completion is an interactive utility over prompt or resource references.

Exposing raw list/read/get operations would let a server determine runtime
authority after the host document was frozen. The resource surface therefore
needs an operator mapping of exact upstream resource URIs to bounded public
zero-argument read capabilities. `resources/list` is assembly-time validation,
not a raw mission capability, and `resources/read` is reachable only through
frozen mappings.

The design must decide:

- the host grammar for exact URI grants and public names;
- manifest narrowing and model visibility;
- aggregate catalog, page, argument, and result ceilings;
- duplicate and catalog-change failure behavior;
- safe provider snapshot fields and hashes;
- whether resource-only MCP installations are valid; and
- `Mcp-Name` emission for `resources/read` over HTTP.

Use the common installed `timeout_ms` and `max_result_bytes` ceilings. Add
family-specific catalog item/page ceilings only where acquisition needs them.
Every paginated list must preserve the first page's `cacheScope` and reject a
later different scope; page `ttlMs` values remain independently variable.
`cacheScope: "private"` restricts cache reuse to one authorization context; it
does not change PtcRunner `data_class` or `accepts_data`.

Every returned `ResourceContents.uri` must exactly equal the granted URI;
reject the entire result if any item names another URI. Sub-resources require
their own grants and are not inferred from URI prefixes. Returned text is
inert, untrusted result data and is never automatically spliced into workflow
or system prompts.

URI templates, prompts, and completion remain deferred until a concrete
first-party consumer provides requirements. The frozen catalog freezes
membership and contracts, not later resource contents.

## Delivery slices and review checkpoints

Review each complete slice against its invariants, resolve every correctness
and authority finding, and run focused tests plus `mix precommit`. Dependent
slices do not begin from an unreviewed authority or wire contract.

### Slice 1 — exact-resource authority design

**Trigger:** a concrete first-party application that needs MCP resources.

Decide section 1's operator-owned exact-URI grammar, public capability
projection, resource-only installation rule, frozen catalog semantics, and
safe snapshot identity. Keep URI templates, prompts, and completion out.

Walk through one allowed URI, one unlisted URI, a catalog change, duplicate
aliases, a private result, and a resource-only server. Prove no generic URI or
raw list operation reaches mission code. Reject the slice if its consumer could
use an ordinary mapped MCP tool without losing an important capability.

This is a specification slice and changes no runtime code.

### Slice 2 — exact-resource mappings

**Depends on:** approved Slice 1.

Discover and validate operator-granted exact resources during assembly. Expose
each as a bounded zero-argument read capability. Implement `resources/read`,
required cache fields, `Mcp-Name`, text-result normalization, safe snapshots,
and resource-only installations as approved. Reject binary/blob content until
a bounded representation is designed.

Trace every public resource capability to one exact host-granted URI. Test
pagination limits, catalog changes, missing resources, text bounds, private
cache scope, mixed-scope rejection, varying page TTLs, and unsupported
content. Reject any mismatched returned URI. Verify a server cannot introduce
a new reachable URI after assembly. Run an independent third-party resource
server over stdio and HTTP.

Prompts, completion, URI templates, subscriptions, and progress remain
unscheduled. They require their own plan after a concrete consumer exists.

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
