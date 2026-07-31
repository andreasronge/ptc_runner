# Inbound MCP gateway: serve, eval, publish, compose, improve

**Status:** future, trigger-gated; written 2026-07-31. No approved
implementation work. This plan assumes the completed
[stable CLI contract](../lisp-kernel/stable-cli-contract.md): the
transport-neutral `ApplicationPackage`/`ExecutionInput`/`ExecutionPolicy`/
`RunRequest` seam, the memory acquisition adapter, the
`InstallationCatalog`/`ProviderRuntimeServices` split, closed `phase/code`
diagnostics, monotonic `provider_activity`, the portable logical-name
grammar, the domain-separated application digests, and standalone packaging.
`product-readiness.md` defers "inbound service frontends" to a separate plan;
this document is that plan's product half. The adversarial service boundary
(per-principal authentication, tenant isolation, quotas) remains outside it.

The gateway is one inbound MCP server product built on the Kernel seam. It
exposes compiled PtcRunner applications as MCP tools, lets a capable client
model author new tools through bounded evaluation, and gates every durable
change behind explicit promotion. The runtime consumes tools only through MCP
today; this product makes MCP the door in both directions: many raw upstream
tools in, few governed compound tools out.

## Relationship to the removed `ptc_runner_mcp`

The repository shipped a standalone MCP server (`ptc_lisp`) with `lisp_eval`,
an upstream aggregator, sessions, HTTP bearer deployment, and an experimental
planner-LLM `lisp_task`. Commit `ec5806d1` removed it and the parallel
`upstream/` runtime after Kernel capabilities became the sole extension seam.
None of that code returns; the guardrail against restoring deleted products
stands. The product interface, however, was validated once and the code-mode
gateway category has since been validated externally.

What the Kernel generation adds that the old shape could not express:

| | Old `ptc_runner_mcp` | This plan |
| --- | --- | --- |
| Inbound payload | source code per call | task input; source only through `lisp_eval` |
| Program identity | none; every call throwaway | content-addressed; cacheable; promotable |
| Per-tool authority | dynamic — whatever the next program used | static, compiled, provable before run |
| Contracts | optional per-call schema | compiled bounded contracts, both directions |
| Evidence | debug JSONL | canonical trace and private inspection planes |
| Accumulation | none | published components, run corpus, qualification |

## Trigger

Start mode M0 when a compiled application worth consuming over MCP exists —
the [incident-evidence compiler](incident-evidence-compiler.md) is the
intended first published tool — and at least one real MCP client journey
(Claude Code or equivalent) motivates it. Later modes have their own gates
below; do not build ahead of them.

## Staged modes

Each mode is separately shippable and separately triggered. Earlier modes
never depend on later ones.

| Mode | Adds | Requires a server-side model |
| --- | --- | --- |
| M0 `serve` | one compiled application exposed as MCP tools over stdio | no |
| M1 `eval` | bounded PTC-Lisp evaluation authored by the client's model | no |
| M2 `publish` | client-minted tools, session-scoped; explicit promotion to durable | no |
| M3 `compose` | server-side task-to-program authoring | yes |
| M4 `improve` | qualification packets over the accumulated run corpus | evaluation only |

M0 through M2 form the complete minimum product: authoring intelligence stays
in the client, so the gateway needs no LLM installation, no provider
credential, and no long-running calls.

## Design decisions

### The gateway is a frontend, not a runtime

The MCP listener is the third frontend on the shared command engine, after
argv and the host-owned memory path. Every inbound `tools/call` constructs a
`RunRequest` through the same bounded acquisition and preflight phases as a
CLI run and executes as one ordinary bounded Kernel run: own heap, own
deadline, canonical trace, closed diagnostics mapped to MCP tool errors.
Per-call process isolation is what makes one-run-per-call viable; nothing
about execution semantics is gateway-specific.

`PtcRunner.Kernel.MCPProtocol` remains the client-side validator. Server-side
JSON-RPC framing, capability advertisement, and result construction are a new
bounded module; do not extend the client module to serve.

As a server, the gateway advertises tools only. It never advertises or uses
sampling, elicitation, or roots — the mirror of the client-side refusals —
and never emits an `input_required` result.

### The served surface is data produced by a bounded boot run

A gateway application declares its surface by running an ordinary bounded
workflow program at startup that returns an exposure table: exposed tool
name, backing component export, compiled contract references, and effect. The
host shell enacts the table, owns the listener and its lifecycle, and
executes each inbound call as a fresh run. Lisp never holds a socket, a
listener, or a long-lived registration; a boot program that fails its
contract fails startup.

Because the table is data, the surface has a content identity: a
domain-separated digest over the canonical exposure table, the gateway
application's `effective_application_digest`, and the installed provider
snapshot hashes. The server reports this surface digest in its MCP server
info metadata and refuses to start when any input drifted from a pinned
value. A boot program may compute its table from the frozen mission
inventory — for example wrapping every granted read-effect upstream tool
into a renamed, contract-annotated passthrough — which is the enterprise
proxy expressed as a reviewable, hashed program.

### Published schemas use the bounded contract profile

An exposed tool's MCP `inputSchema` and `outputSchema` come from compiled
`ValueContract`-profile documents, the same bounded JSON Schema profile as
application input/result contracts. The signature grammar has no JSON Schema
projection and does not gain one for this; signed component signatures remain
the runtime check behind the contract. The runtime validates inbound
arguments before the body and results before the response, so gateway tools
are MCP tools whose schemas are enforced rather than advisory.

Exposed tool names use the portable logical-name grammar. Descriptions are
bounded, host- or promotion-approved text; model-authored description text
never reaches another session's context without passing the promotion gate.
Each tool carries accurate read-only/destructive annotations derived from
its compiled effect, never from free text.

### Evaluation authority and publication authority are distinct

`lisp_eval` executes client-authored source through the existing bounded
kernel-eval path against the granted mission environment. Task text and
source arriving over MCP are untrusted data under ordinary limits; an abusive
session can waste only its own bounded budget.

`publish_tool` is a separate host-granted capability. A published tool is
visible only to its publishing session and dies with it. Making a tool
durable — visible to later sessions — is an explicit promotion step gated
outside the model: host configuration or an operator action, recording the
component hash, contract hashes, effect, and authority set. Promotion is the
only path from model output to durable surface, and `tools/list_changed` is
emitted only for the publishing session before promotion.

A published tool's reachable capability set is a compiled subset of the
publishing run's grants, frozen at publish time. It can lose access when an
upstream pin drifts (refusal), never gain it.

### No server-side model before M3, and M3 has protocol prerequisites

M0–M2 mark no provider activity for the model path at all. M3 `compose`
introduces a planner/author model as an ordinary installed LLM provider
inside the activity boundary, with prompts that remain domain-blind. Compose
runs a multi-turn loop against clients that time out; it is blocked on a
bounded progress story — MCP progress notifications or MCP Tasks, whichever
the pinned protocol generation supports at build time. MCP Tasks stay
deferred until M3 itself is triggered by demand.

### M4 `improve` returns evidence; humans promote

`improve` runs the candidate-evaluation chain — base-hash verification,
confined override materialization, case matrix, trusted trial join,
power-aware aggregate — over the run corpus that served tools accumulate,
and returns a qualification packet. The repo-analyst record is the honest
state: diagnosis and evaluation machinery work; autonomous decide-to-act and
promotion are not established. The gateway API encodes that: `improve`
never mutates the surface, and promotion reuses the M2 gate.

### Transport gradient, with the service boundary marked

1. **stdio, per-user** — M0 target. The operating-system user is the
   principal; host document and credentials are theirs.
2. **HTTP, single shared authority** — one bearer-authenticated endpoint on
   loopback or a private network, every client seeing the same surface under
   the same authority. In scope once stdio journeys are proven.
3. **HTTP, per-principal authority** — different clients, different
   surfaces, per-identity audit, inbound OAuth. Out of scope. This is the
   adversarial service boundary `stable-cli-contract.md` assigns to a
   separate service plan, and the natural seat of a hosted product.

Stateless per-call execution is the default. Stateful sessions (persistent
bindings, REPL-like flows) are deferred with the standalone-REPL streaming
question; `ReplSession` process affinity is not weakened for the gateway.

## Enterprise proxy deployment

The gateway's deployment story for organizations is: allow exactly one MCP
endpoint. The operator-owned host document is the approval record for every
upstream server; installations narrow, rename, and effect-classify upstream
tools; snapshot pins refuse drift; every call leaves a canonical trace; and
the perimeter itself is a short reviewed boot program with a content hash.
Differentiation over pass-through MCP gateways is not proxying — it is
enforced schemas, provable per-tool authority, compound tools that replace
dozens of raw ones, and a surface whose exact identity can be attested.

## Non-goals

- No restoration of `lib/ptc_runner/upstream/` or `mcp_server/` code.
- No inbound per-principal authentication, tenant isolation, quotas, or
  inbound OAuth resource-server role; those belong to a separate
  service-boundary plan.
- No public tool registry, marketplace, or cross-organization sharing.
- No OpenAPI/GraphQL adapters — MCP remains the only door, both directions.
- No autonomous promotion of model-authored tools or candidates.
- No server-initiated sampling, elicitation, or roots; no `input_required`.
- No MCP Tasks work before the M3 trigger.
- No stateful session tools in M0–M2.

## Related documents

- [Stable CLI contract](../lisp-kernel/stable-cli-contract.md) — the command
  engine, acquisition seam, diagnostics, and packaging this plan builds on.
- [Product readiness](../lisp-kernel/product-readiness.md) — records the
  inbound-frontend deferral this plan resolves the product half of.
- [Incident-evidence compiler](incident-evidence-compiler.md) — the intended
  first served application.
- [MCP OAuth durable store](mcp-oauth-durable-store.md) — outbound
  authorization persistence a long-running gateway will eventually motivate.
- `repo-analyst-self-improvement.md` (branch
  `exp/self-improvement-loop-closure`) — candidate-evaluation machinery and
  its honest state.
- [Manifests and capabilities](../../guides/manifests-and-capabilities.md) —
  installation, narrowing, effects, and contract behavior.
