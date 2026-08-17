# Inbound MCP gateway: serving governed compound tools

**Status:** future, trigger-gated; written 2026-07-31, narrowed after review
the same day. Mode M0 and scope tier 2 (HTTP, single shared authority) were
activated on 2026-08-17 and sliced into pull requests by
[`../mcp-gateway-m0.md`](../mcp-gateway-m0.md) (issue #1465), with two
recorded amendments: the static M0 configuration may hold several entries
(each still exactly one application exposed as one tool), and pooled
provider services are staged — boot performs a validation acquisition and
every call revalidates digests, while pooled retention keeps its own
trigger. Everything else remains unapproved. This plan assumes the
completed [stable CLI contract](../lisp-kernel/stable-cli-contract.md): the
transport-neutral `ApplicationPackage`/`ExecutionInput`/`ExecutionPolicy`/
`RunRequest` seam, the memory acquisition adapter, the
`InstallationCatalog`/`ProviderRuntimeServices` split, closed `phase/code`
diagnostics, monotonic `provider_activity`, the portable logical-name
grammar, the domain-separated application digests, and standalone packaging.
`product-readiness.md` defers "inbound service frontends" to a separate plan;
this document is that plan's product half. The adversarial service boundary
(per-principal authentication, tenant isolation, quotas) remains outside it.

The product is a compiler and serving layer for small, governed compound
tools: many noisy, weakly governed upstream tools in, a few content-addressed,
schema-enforced, authority-bounded compound tools out, exposed to MCP
clients. Generic aggregation and code-mode proxying are already
commoditizing; the differentiated artifact is the compiled, governed compound
tool — exact identity, enforced contracts in both directions, provable
authority, canonical traces, refusal on upstream drift.

## Relationship to the removed `ptc_runner_mcp`

The repository shipped a standalone MCP server (`ptc_lisp`) with `lisp_eval`,
an upstream aggregator, sessions, HTTP bearer deployment, and an experimental
planner-LLM `lisp_task`. Commit `ec5806d1` removed it and the parallel
`upstream/` runtime after Kernel capabilities became the sole extension seam.
None of that code returns; the guardrail against restoring deleted products
stands. That product also demonstrates the cost being reintroduced: server
lifecycle, concurrency, and transport work is real even when the execution
core is sound.

What the Kernel generation adds that the old shape could not express:

| | Old `ptc_runner_mcp` | This plan |
| --- | --- | --- |
| Inbound payload | source code per call | structured input; source only through `lisp_eval` |
| Program identity | none; every call throwaway | content-addressed; cacheable; promotable |
| Tool authority | dynamic — whatever the next program used | the served application's grant, provable before run |
| Contracts | optional per-call schema | compiled bounded contracts, both directions |
| Evidence | debug JSONL | canonical trace and private inspection planes |
| Accumulation | none | compiled tools, handles, gated promotion |

## Trigger

Start mode M0 when a compiled application worth consuming over MCP exists —
the [incident-evidence compiler](incident-evidence-compiler.md) is the
intended first served tool — and at least one real MCP client journey
(Claude Code or equivalent) motivates it. The product hypothesis M0 must
test, shared with that plan's baseline comparison: one compiled, read-only
compound tool materially reduces client round trips and context while
producing a more reviewable result than the same client using the raw
upstream tools. If that fails, the gateway is plumbing, not a product.

## Modes

Each mode is separately shippable and separately triggered. Earlier modes
never depend on later ones.

| Mode | Adds |
| --- | --- |
| M0 `serve` | one compiled application exposed as one MCP tool over stdio |
| M1 `eval` | one fixed bounded-evaluation tool for client-authored PTC-Lisp |
| M2 `handles` | `compile_tool`/`run_tool` over content-addressed tool references |

M0–M2 introduce **no gateway-owned authoring model**: authoring intelligence
stays in the client, so the gateway itself installs no LLM provider and holds
no authoring credential. A *served application* may still select installed
LLM providers — the incident compiler does — so provider activity, provider
deadlines, long-running calls, and cancellation are M0 concerns, not later
ones.

### M0. One application, one tool

A static gateway configuration supplies: tool name and approved description;
one application source (directory or memory adapter); required input and
result contracts; the derived effect/authority summary; and expected
application and provider snapshot digests. Startup validates and compiles
this once into an immutable serving template; a digest mismatch refuses
startup. Each `tools/call` constructs a fresh `ExecutionInput` and policy
and executes one ordinary bounded Kernel run: own heap, own deadline,
canonical trace, closed diagnostics mapped to MCP tool errors.

No boot Lisp program, no multiple exports, no dynamic surface, no
notifications. Read-only compound tools only: the configuration refuses an
application whose grant includes a write-effect tool. Write-bearing compound
tools are deferred behind an explicit trigger because multiple upstream
writes are not transactional; they require idempotency, partial-effect
reporting, and possibly compensation semantics before they are honest to
serve.

One application per exposed tool is the authority model, not a convenience.
The compiler does record every `tool:name` an export reaches, transitively,
but the runtime grant is per-run, and a provider-bearing application whose
model writes mission programs can reach its whole mission grant. Making the
application boundary and the tool boundary coincide keeps "what this tool
can reach" exactly equal to "what this application was granted" — provable
from the manifest before any call.

### M1. One fixed `lisp_eval`

A developer/code-mode tool: client-authored PTC-Lisp through the existing
bounded kernel-eval path against the granted read-only mission environment.
Valuable for filtering large tool results, joins and reductions,
deterministic computation, and cutting model round trips. This space is
competitive and client models know JavaScript better than PTC-Lisp; the
differentiation is bounded execution, mediated MCP authority, and that every
evaluated program has a content hash — the on-ramp to M2. Task text and
source arriving over MCP are untrusted data under ordinary limits.

### M2. Content-addressed tool handles

The pinned MCP generation is stateless, and this repository's protocol
surface carries no dynamic tool-list notification; a served tool list is
fixed for the server process lifetime. M2 therefore adds experimentation
through explicit values rather than list mutation:

1. `compile_tool` accepts bounded source plus contract documents, compiles
   and validates them, and returns a content-addressed `tool_ref` — no new
   MCP tool appears;
2. `run_tool` accepts a `tool_ref` and structured input and executes it as
   an ordinary bounded run;
3. compiled objects live in a bounded, host-owned cache keyed by content
   hash; and
4. promotion is an operator action that adds the compiled tool to the static
   M0 configuration, taking effect on configuration reload or restart.

Promotion is the only path from model-authored source to a served tool.
Names use the portable logical-name grammar; descriptions are bounded and
promotion-approved; model-authored description text never reaches another
session's context without passing that gate. `compile_tool`/`run_tool`
authority is a host grant distinct from `lisp_eval`.

## Later, separately triggered work

- **Computed proxy surface.** A bounded boot run that returns an exposure
  table as data — for example wrapping every granted read-effect upstream
  tool into renamed, contract-annotated passthroughs — giving the surface
  itself a content identity. Deferred until M0–M2 journeys prove client
  behavior; for one or a few tools the static configuration wins.
- **Compose.** Server-side task-to-program authoring is a different product:
  an installed authoring model inside the activity boundary, domain-blind
  prompts, a bounded progress story for multi-minute calls, cost and
  evaluation concerns. It gets its own plan when client-side authoring (M1/
  M2) demonstrably fails a real population of users.
- **Qualification is not a gateway mode.** Comparing two compiled tools
  belongs to an operator command (`ptc qualify`) and CI, not to the serving
  surface. A run corpus alone is not an evaluation set: qualification needs
  retained replayable inputs (the LLM replay machinery), authored cases,
  expected properties, scoring, and trustworthy outcome joins — and
  canonical traces deliberately omit exact and private material. Qualification
  needs a dedicated candidate-evaluation chain, and promotion remains human.

## Design decisions

### The gateway is a frontend, not a runtime

The MCP listener is the third frontend on the shared command engine, after
argv and the host-owned memory path. `PtcRunner.Kernel.MCPProtocol` remains
the client-side validator; server-side JSON-RPC framing, capability
advertisement, and result construction are a new bounded module.

### Serving template and pooled provider services

A fresh acquisition per call would repeat compilation, preflight, and — for
MCP-bearing applications — connection and discovery on every `tools/call`.
The gateway compiles once into an immutable serving template and holds
gateway-scoped, host-owned provider runtime services so upstream connections
stay warm across calls, while every run remains individually bounded and
individually traced. Defining the ownership, cleanup, and drift-recheck
contract for pooled provider services relative to the execution-scoped
services of the CLI plan is the largest genuinely new engineering item in
this plan.

### Admission control and cancellation

Per-run heap and deadline bounds do not protect the VM from unbounded
concurrent calls; even a stdio client can issue calls concurrently. The
gateway enforces a bounded in-flight call limit with explicit rejection —
no hidden unbounded queue. Client disconnect or cancellation must reach the
run owner, which already kills and drains attached provider work before
connector cleanup; the gateway wires transport lifecycle to that existing
contract.

### Contracts, schemas, and attestation

Exposed tools' MCP `inputSchema` and `outputSchema` come from compiled
`ValueContract`-profile documents — the same bounded JSON Schema profile as
application contracts — validated on both directions of every call. The
signature grammar has no JSON Schema projection and does not gain one here.
Effect annotations derive from compiled effects, never free text. The
serving template's digests (application, contracts, provider snapshots) are
reported through a namespaced MCP `_meta` extension rather than invented
server-info fields, so attestation is interoperable without forking the
protocol surface.

### Single-authority scope

1. **stdio, per-user** — M0 target. The operating-system user is the
   principal; host document and credentials are theirs.
2. **HTTP, single shared authority** — one bearer-authenticated endpoint on
   loopback or a private network, every client seeing the same surface under
   the same authority. In scope once stdio journeys are proven.
3. **HTTP, per-principal authority** — different clients, different
   surfaces, per-identity audit, inbound OAuth. Out of scope; this is the
   adversarial service boundary assigned to a separate service plan, and the
   natural seat of a hosted product.

This plan claims a *local or single-authority governed gateway*. It does not
claim an enterprise proxy: centralized identity, per-user policy, and fleet
management are what that term implies, and they live beyond the boundary
above. What the single-authority gateway does offer an organization is
already distinct — enforced schemas, provable per-tool authority, compound
tools replacing dozens of raw ones, and an attestable surface.

## Non-goals

- No restoration of `lib/ptc_runner/upstream/` or `mcp_server/` code.
- No dynamic tool-list mutation or session-scoped served tools.
- No write-effect compound tools before their explicit trigger.
- No gateway qualification mode; `ptc qualify` is operator tooling.
- No inbound per-principal authentication, tenant isolation, quotas, or
  inbound OAuth resource-server role.
- No public tool registry, marketplace, or cross-organization sharing.
- No OpenAPI/GraphQL adapters — MCP remains the only door, both directions.
- No autonomous promotion of model-authored tools.
- No server-initiated sampling, elicitation, or roots; no `input_required`.
- No stateful session tools; stdio subprocess lifetime is transport-local
  behavior, not a protocol session.

## Related documents

- [Stable CLI contract](../lisp-kernel/stable-cli-contract.md) — the command
  engine, acquisition seam, diagnostics, and packaging this plan builds on.
- [Product readiness](../lisp-kernel/product-readiness.md) — records the
  inbound-frontend deferral this plan resolves the product half of.
- [Incident-evidence compiler](incident-evidence-compiler.md) — the intended
  first served application and the shared baseline experiment.
- [MCP OAuth durable store](mcp-oauth-durable-store.md) — outbound
  authorization persistence a long-running gateway will eventually motivate.
- [Manifests and capabilities](../../guides/manifests-and-capabilities.md) —
  installation, narrowing, effects, and contract behavior.
