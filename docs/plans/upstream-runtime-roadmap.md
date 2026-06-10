# Upstream Runtime Roadmap

This document is the consolidated **deferred / forward-looking** design for the
upstream tool subsystem (OpenAPI + external MCP tool servers driven from core
`ptc_runner`). It folds the remaining future work from four superseded planning
docs into one place; all shipped extraction, migration, and checkpoint mechanics
have been dropped because that work now lives in code and tests. The **shipped**
runtime is documented for users in [`docs/upstream-runtime.md`](../upstream-runtime.md)
and lives in `lib/ptc_runner/upstream/` (`Runtime`, `Eval`, `OpenApi`, the MCP
client transports, `Catalog`, `Credentials`, `RunContext`, `Collector`,
`CallTool`, `Discovery`, `Effect`, `SideEffectGuard`). The kernel-level RunEnv /
capability-runtime design surface stays in
[`docs/plans/capability-kernel-runtime.md`](capability-kernel-runtime.md); the
broader capability-profile/provider direction stays in
[`docs/plans/capability-prelude-discovery.md`](capability-prelude-discovery.md).
The MCP ledger hardening sequence (§4.2) has shipped and is retained here
as historical context. The remaining forward-looking work is the Phase 2 facade
plus optional Phase 3b ledger retirement ([§3](#3-subagent-bridge-future),
[§4](#4-mcp-ledger-boundary)).

Contents:

1. [Two-layer ownership contract](#1-two-layer-ownership-contract)
2. [Core runtime deferred items](#2-core-runtime-deferred-items)
3. [SubAgent bridge future](#3-subagent-bridge-future)
4. [MCP ledger boundary](#4-mcp-ledger-boundary)
5. [OpenAPI adapter roadmap](#5-openapi-adapter-roadmap)

---

## 1. Two-layer ownership contract

The durable architectural principle: **core owns *how* an agent drives an
upstream runtime; the embedding host owns *selection*, *policy*, and *UX*.**

Use this two-layer ownership sentence consistently:

- **Root `ptc_runner` owns the upstream runtime machinery**: config parsing,
  transports, OpenAPI execution, catalog/discovery, credential attachment,
  redaction helpers, result normalization, caps, and `RunContext` lifecycle —
  including neutral catalog metadata, generic side-effect classification, and
  policy *extension points* (`continuation_guard`, `on_upstream_call`, approval
  callbacks, caps) with safe defaults. Core should own attempt recording only if
  a committed audit-completeness requirement needs a provider-neutral
  pre-dispatch ledger.
- **The embedding host owns deployment selection and presentation**: which (if
  any) upstreams a deployment selects, authorization, and the UX/protocol around
  approval, denial, continuation, retries, and audit export. For the MCP
  deployment this is `mcp_server`: whether and which root runtime a server
  process starts, its CLI/env aliases, deployment secret materialization and
  redaction ETS, MCP envelopes/prompts, sessions, debug/trace UX, and release
  packaging.

`mcp_server` is **one such host**: it configures and exposes `ptc_runner` and
installs MCP-specific policy callbacks; it is **not** the architectural home for
upstream execution or generic side-effect logic. Otherwise `ptc_runner`-standalone
users would have to reimplement safety policy.

Remaining blocking contracts that this boundary depends on:

- runtime handle lifecycle;
- per-run budget/context ownership and teardown;
- separate catalog exposure and snapshot semantics;
- explicit naming for MCP client transports in root;
- transport-owned result normalization so root does not depend on MCP envelopes;
- config, dependency, redaction, and REPL precedence decisions.

Standing non-goals for the host/core split:

- Do not move endpoint/credential authority into preludes. A future
  capability-profile facade may provide a more general host-owned selection
  surface, but upstream runtime *selection* stays host-owned (in the MCP case,
  `RootUpstreamRuntime` — see [§3](#3-subagent-bridge-future)).
- Do not keep backward-compatible MCP-specific Lisp aliases indefinitely; this
  is a 0.x library.
- Do not turn root `ptc_runner` into an MCP server, and avoid circular
  dependencies: root must not depend on `ptc_runner_mcp`.

---

## 2. Core runtime deferred items

These are the open core-runtime design items that remain after the upstream
subsystem extraction. The RunEnv struct/contract *design surface itself* lives in
[`capability-kernel-runtime.md`](capability-kernel-runtime.md) — link there as
the kernel-mechanics source rather than duplicating it here.

### 2.1 RunEnv typed projection

`PtcRunner.Lisp` remains the owner of evaluation; upstream stays a thin
projection/bridge over `PtcRunner.Upstream.RunContext`. A future
`PtcRunner.Lisp.RunEnv` projection can make the eval-input boundary **typed** —
but only if the conversation control-plane work becomes committed work and gives
it a downstream consumer. Rationale and constraints:

- A `RunEnv` projection is **deferred until it has a committed downstream
  consumer**; the immediate runtime hardening (the closed-context guard) shipped
  ahead of it.
- If a Lisp-specific helper is kept, it should stay a thin convenience over
  `with_run_context/3`, `eval_options/1`, and `PtcRunner.Lisp.run/2`. If `RunEnv`
  ships later, that helper can project into `PtcRunner.Lisp.RunEnv` internally
  while preserving the same closeable run-context contract.
- The kernel mechanics (per-context `:closed` atomic semantics, `:max_tool_calls`
  overload handling, `signature_supplied?` post-merge ordering) are owned by the
  kernel-runtime spec — do not re-specify them here.

### 2.2 Neutral `PtcRunner.Runtime.with_run/3`

A future **neutral** `PtcRunner.Runtime.with_run/3` can generalize the
`with_run_context/3` shape *after another lifecycle-bearing provider needs it*.
Until then, all normal caller paths use `Upstream.Eval.with_run_context/3`, and a
neutral `with_run/3` projection would simply delegate to it. Do not introduce the
neutral runtime before a second provider exists; Lisp evaluation remains owned by
`PtcRunner.Lisp`, not by `PtcRunner.Upstream`.

### 2.3 Qualified-symbol tool/call dispatch (open question)

The Lisp surface is `(tool/call ...)`. The **map form** is the implemented call
syntax; the **qualified-symbol form**
`(tool/call 'observatory/list-traces {:limit 3})` remains an open question:

- Whether the qualified-symbol form can be implemented without parser/runtime
  changes is unresolved; the map form remains the implementation fallback until
  that is confirmed.
- The call closure should accept both the map form and the qualified-symbol form
  once the parser/runtime supports symbols in that position.
- Internally, the symbol form is syntax sugar at the Lisp boundary only; it must
  normalize to the same explicit string-keyed map shape the existing machinery
  uses (`%{"server" => ..., "tool" => ..., "args" => %{...}}`) so validation,
  telemetry, ledgers, and registry dispatch stay keyed by `server`/`tool` without
  a second `ref` parsing path.

Related still-open core-runtime choice: whether the namespace stays
`PtcRunner.Upstream` or is renamed consistently (e.g. `PtcRunner.ToolServers` /
`PtcRunner.Connectors`) to avoid the audit-tooling "upstream" terminology
collision. If renamed, rename the whole namespace consistently — do not mix names.

---

## 3. SubAgent bridge future

The shipped bridge is `PtcRunner.Upstream.Eval.run_subagent/3`: it owns one
`RunContext` for the whole SubAgent run, enriches the agent with the upstream
`"call"` tool before prompt generation, threads `discovery_exec`, installs a core
default `continuation_guard`, and returns drained records. The remaining
forward-looking items follow.

### 3.1 Phase 2 — `SubAgent.run(runtime:)` delegating facade

The thin convenience facade is **deferred to Phase 2**.

```elixir
SubAgent.run(agent, llm: llm, context: ctx, runtime: upstream_runtime)
```

Today, `runtime:` on `SubAgent.run/2` is a **passthrough**, not a bridge
delegate: it reaches `Lisp.run`'s attach path and validates a prelude's
`requires`, but it opens **no** `RunContext`, does **not** enrich the agent with
the upstream `"call"` tool, and drains **no** records. A bare
`SubAgent.run(agent, runtime: rt)` therefore validates `requires` but cannot
dispatch upstream calls — with no `RunContext` there is no `"call"` tool in scope,
so a call attempt fails safe (raises undefined-tool); it does **not** silently
dispatch a partial write. `Upstream.Eval.run_subagent/3` is the supported entry
point today.

When the facade lands it becomes a full **bridge delegate** (enriches `"call"`,
opens one `RunContext`, drains records, executes upstream). Three things the
facade must get right:

- **Avoid recursion.** The bridge re-enters SubAgent via the internal
  `PtcRunner.SubAgent.Runner.run/2`, **not** the public `SubAgent.run/2` — the
  bridge passes `runtime:` and the facade keys on `runtime:`, so calling the
  public entry would recurse (facade → bridge → `SubAgent.run` → facade → …).
  (The bridge already calls `Runner.run/2` directly and is `Definition`-only, so
  the recursion is pre-empted the moment the facade lands.)
- **Return shape.** `SubAgent.run(runtime:)` returns only the `SubAgent.run/2`
  result, **dropping** the bridge's `records` — mirroring `run_lisp/3` vs
  `run_lisp_with_records/3`.
- **One public meaning.** After the facade, treat the public
  `SubAgent.run(runtime:)` as having a **single** meaning — the bridge — and treat
  the `:runtime` opt at the `Runner.run` / `Loop.run` / `LispOpts` level as
  internal plumbing the bridge sets for per-turn attach validation, **not** a
  public entry point for upstream execution. Audit existing public
  `SubAgent.run(..., runtime:)` call sites when the facade lands (e.g.
  `test/ptc_runner/upstream/eval_run_subagent_test.exs`): they flip from
  passthrough to bridge semantics and must move to `Runner.run/2` if they only
  wanted attach validation. Tests and comments must not conflate "runtime reaches
  attach validation" with "runtime-backed upstream execution."

Phase 2 may also add a run-scoped `upstreams: config` convenience for selecting or
owning a runtime for the run's duration. It must not pre-empt the broader
profile/provider design in
[`capability-prelude-discovery.md`](capability-prelude-discovery.md), and the
bridge still does **not** need `:runtime` lifecycle ownership inside the loop.

### 3.2 Section-4 target-boundary principle

The Phase 1 split (MCP keeps its `"call"` wrapper / ledger / `continuation_guard`
server-side, passed into the bridge as a decorator + guard) is **compatibility
with the existing contract, not the target boundary**. The target is the
two-layer contract in [§1](#1-two-layer-ownership-contract): core owns *how* an
agent drives an upstream — including neutral catalog metadata, generic
side-effect classification, and policy *extension points* with safe defaults —
while the host owns selection plus the authorization/approval/denial/audit-export
UX. Phase 3a already moved generic classification and the default guard into core;
the residual host-owned pieces (selection, MCP ledger format, retention/projection/
export) are addressed by [§4](#4-mcp-ledger-boundary).

### 3.3 Phase 3c — frozen-snapshot validation

`catalog_snapshot_mode` defaults to `:live`, which re-fetches upstreams per
catalog op, so a turn-N `requires` re-validation can fail where turn 1 passed.
The V1 mitigation is to treat `:prelude_attach_failed` as a **hard stop** on the
multi-turn path (a missing backing is not a program error the LLM can fix by
rewriting). Phase 3c is the more elegant long-term answer:

- **Validate `requires` once** at run-context open against a **frozen-for-the-run
  snapshot**, removing per-turn redundancy *and* the live-catalog hazard.
- Keep the effect/guard primitives **provider-neutral** where practical: upstream
  is the first concrete provider, but the same concepts should be able to serve
  future local, sandbox, and SubAgent capability providers.
- Do not let the per-turn-redundancy argument motivate caching state inside
  `Loop`; that would re-introduce the lifecycle coupling the bridge design avoids.
- The "fail-closed on the multi-turn path" claim must remain qualified to
  *before any side-effecting turn*, not whole-run side-effect freedom under a live
  catalog.

### 3.4 Outstanding tests

Two test-plan items remain from the bridge plan:

- **`:e2e` test (outstanding).** Real LLM + the bridge over the dummy upstream —
  the combined path that currently has no single home. Distinct from the
  default-guard canary, which pins behavior but does not exercise a real LLM.
- **Round-trip / raise-through-bridge.** The deterministic round-trip (multi-turn
  agent calls a tool-backed export against a reachable upstream via the bridge,
  reusing `start_http_fixture` / `examples/ptc_repl_dummy_upstream`) and the
  raise-through-bridge fault test are delivered; the fault test currently
  **documents** that pre-raise upstream call records are unavailable after the
  context closes (`drain_calls/1` returns `[]`). A future durable-audit change
  must deliberately improve this rather than assume records survive bridge raises
  — see the Phase 3b migration step in [§4](#4-mcp-ledger-boundary) that pairs a
  drain-in-`after` with this fault test.

---

## 4. MCP ledger boundary

The MCP ledger currently owns side-effect policy + wire projection server-side.
This section covers (a) the deferred Phase 3b decision to move attempt recording
into core, including its triggers and migration order, (b) the shipped PR1–PR3
ledger hardening the Phase 3b migration builds on, and (c) non-goals.

### 4.1 Phase 3b — core attempt-record ledger + MCP ledger retirement (DEFER)

**Decision (2026-06-09): defer.** A design investigation (5 parallel source
audits + adversarial verification) confirmed Phase 3b is, today,
**MCP-ledger-retirement only** — there is no correctness reason to build a core
attempt-record surface yet. Build nothing in core until a trigger fires.

**Why defer (source-verified):**

- **No consumer.** The only non-test caller of `Eval.run_subagent/3` is
  `mcp_server`'s `agentic.ex`, and it **discards** the bridge records
  (`{result, _records}`), using its own ledger. `ptc_viewer` (a disk JSONL reader)
  and `demo` consume zero upstream records. The total absence of any record
  consumer is itself the decisive defer signal.
- **The ledger works and is test-locked.** MCP closes the holes server-side via
  **pre-dispatch** `record_attempt` + `call_with_ledger`'s rescue/reraise; the
  in-flight block is locked by `agentic_contract_test.exs`
  (`{:attempted_during_dispatch, true}`).
- **The holes are real but bite nobody.** `CallTool.dispatch` records
  post-dispatch only. H1: a raise in the post-`{:ok, value}` helpers (realistically
  only `Runtime.scrub`, a `GenServer.call` that `:exit`s if the Runtime died)
  unwinds past `RunContext.record`. H2: a sandbox timeout / heap kill — an
  untrappable `Process.exit(pid, :kill)` — destroys the worker mid-dispatch before
  the record reaches the separate-process Collector. On a raise *through* the
  bridge, `with_run_context`'s `after` runs `Collector.stop` (destroy, no drain)
  and re-raises, losing *all* records. The upstream-side call timeout is **not** a
  hole (transports catch `:exit` → `{:error, :timeout, _}`, recorded). These holes
  only bite a standalone non-MCP consumer reading `run_subagent/3` records as an
  audit trail — none exists; MCP plugs all of them.
- **Building now adds cost for a hypothetical.** The minimal correct design
  re-introduces the guard↔record coupling Phase 3a deliberately removed, needs a
  non-destructive attempt reader the append-only Collector lacks, and still would
  not close the raise-through-bridge hole without an extra drain-in-`after`.

**Triggers to implement (any one):**

1. a committed **non-MCP consumer** of `run_subagent/3` (or
   `run_lisp_with_records/3`) that reads `records` and needs killed-in-flight /
   raised writes audited;
2. the **Phase-2 `SubAgent.run(runtime:)` facade** lands returning only
   `{:ok, step}` (records no longer reach callers via the tuple) — forces a
   `Step.upstream_calls` surface;
3. **child/nested SubAgents** whose upstream calls must roll up to a parent that
   sees only the child `%Step{}`;
4. a decision to **delete the MCP decorator** for maintenance reasons (e.g. to
   stop maintaining two effect classifiers). **Do not execute this trigger before
   migration Steps 1–2 below land**, or retiring the ledger *regresses* the
   in-flight-killed-write continuation block (a genuine, operator-config-reachable
   safety property — `retry_turns > 0` / `max_turns > 1` — that the pre-dispatch
   ledger provides and the Phase-3a `Turn`-reading guard does not).

**When triggered — minimal record surface (do not pre-build):** core records gain
only `"id"` (a `make_ref` correlation token) + `"effect"`
(`Upstream.Effect.classify`, captured pre-dispatch on the `:proceed` arm so an
interrupted write keeps its classification) + an `"attempted"` status value. Keep
`args_hash` **OUT** (SHA-256 read by no consumer; if MCP wants byte parity,
compute it in a thin MCP-side projection), `turn` **OUT** (a hardcoded literal `1`
today — let the MCP projection stamp it), and `Step.upstream_calls` **OUT**
(records already reach root via the tuple; a `%Step{}` field would be a second
source of truth). Use **fork (a)**: two correlated rows (`:attempted` + terminal),
merged by a stateless end-of-run projection — the only design that keeps the
single destructive drain and the `{result, records}` contract without giving the
append-only Collector an upsert.

**When triggered — safe migration order (retire the ledger without double-counting
or regression):**

1. Add core pre-dispatch recording in `CallTool.dispatch` (write an `:attempted`
   row with `id`+`effect` *before* `Runtime.call_tool`; finalize to `:ok`/`:error`
   after; finalize to `:error` on raise via `try/rescue`) **plus** a
   non-destructive `RunContext` attempt reader. Lock with a core test that an
   attempt exists mid-dispatch and survives a transport raise. MCP unchanged,
   ledger still authoritative → **no double-count yet.**
2. Add `SideEffectGuard.from_records/1` and default the bridge to it; lock the
   in-flight block at the guard level (mirror the `{:attempted_during_dispatch,
   true}` assertion). `put_new` lets MCP's explicit guard still win → no behaviour
   change.
3. *(The only step that retires the ledger as a counting site — do atomically.)*
   Replace `continuation_guard(ledger)` with the core record-aware guard, and
   **re-source both** `side_effecting_attempted?` and `entries` from the drained
   core records in one change. Stop passing `on_upstream_call`; delete
   `call_with_ledger` / `root_tools_with_ledger`; move the
   `agentic_contract_test.exs` in-flight lock onto the core path.
4. Pair fork (a) with **draining-in-`after`** (or a bridge catch-and-attach) so a
   raise-through-bridge still surfaces records; update the delivered §3.4 bridge
   fault test, which currently pins that records are unavailable after close.
5. Delete the `Ledger` module once unreferenced.

Verify with `mix precommit` + the mcp `agentic_contract_test` + `codex review` at
each step. The three counting/observation sites have **disjoint authority** — keep
them so: `RunContext` call-cap atomics own *rate limiting* only; the (retiring)
ledger owns *side-effect policy + wire projection*; Phase-3a's `Turn.tool_calls`
guard stays *guard-only* and must never be projected to the audit surface (that
would be a third count).

**Caveat — preview parity is scrubbed now.** PR1 changed MCP's ledger overview
path to build `upstream_results[]` `result_overview` from
`Runtime.scrub(RootUpstreamRuntime.runtime(), value)`, matching core's
`call_tool.ex` path. Future Phase 3b work should preserve the scrubbed preview
semantics and must not reintroduce raw upstream-value previews. Re-pointing the
MCP `upstream_calls[]` ledger shape onto core records is still straightforward
(only `effect`/`turn`/`args_hash` differ, all stampable), but a core-sourced
`upstream_results[]` projection should be locked with a credentialed parity test
so `[REDACTED]` preview/shape behavior stays intentional.

### 4.2 Shipped ledger hardening (PR1–PR3)

Three PR-sized hardening changes have landed on `main`; they are recorded here
as context for the Phase 3b migration that inherits their state. The code lives
in `mcp_server/lib/ptc_runner_mcp/agentic.ex` and
`agentic/{ledger,projection}.ex`.

- **PR1 — success-overview redaction** (`319ef732`). The `%{ok: true}` ledger
  path builds `result_overview` from `Runtime.scrub(RootUpstreamRuntime.runtime(),
  value)`, closing the credential-preview leak in `lisp_task` while keeping raw
  `result_bytes` accounting. A future Phase 3b migration inherits core's
  already-scrubbed overview and can delete this duplication (see the §4.1
  preview-parity caveat).
- **PR2 — canonical effect classification** (`7225a8c3`). MCP side-effect policy
  now calls `PtcRunner.Upstream.Effect.classify/3` (fail-closed
  `rescue -> :unknown`) instead of the deleted MCP-local `find_tool_annotations/3`
  / `annotations_effect/1` / `annotation_true?/2`, so there is one effect
  classifier, not two.
- **PR3 — ledger slimming** (`75732434`). `Ledger.record_attempt/6` became
  `record_attempt/4` (`ledger, server, tool, effect`); the untruthful `args`/`turn`
  arguments, the `:args_hash`/`:turn` entry fields, `hash_args/1`, and the
  projected `"turn"`/`"args_hash"` keys (with their `lisp_task` schema entries)
  are gone. A real turn is deliberately **not** threaded here; that belongs to a
  future Phase 3b record surface.

### 4.3 Non-goals

- Do not add core pre-dispatch attempt recording (until a Phase 3b trigger fires).
- Do not change `Eval.with_run_context/3` drain-on-raise behavior.
- Do not add an envelope-level redactor for `lisp_task`.
- Do not change upstream error redaction; the current error path already receives
  scrubbed details from core.
- Do not introduce compatibility shims for removed `turn` or `args_hash` fields.

The raise-through-bridge record-loss behavior is now pinned by the §3.4 fault
test: a bridge-owned context closes on raise, and records from a pre-raise
upstream call are unavailable after close. This remains a deliberate current
limitation until a real Phase 3b trigger creates a consumer for bridge records on
raise.

---

## 5. OpenAPI adapter roadmap

V1 of the OpenAPI adapter is a curated, explicitly-included, read-only JSON `GET`
adapter (no response projection — return decoded JSON and let PTC-Lisp shape it).
The forward-looking adapter work follows.

### 5.1 Catalog refresh

OpenAPI schemas evolve, so a later explicit refresh operation should be planned:

- Refresh one upstream's schema and compiled catalog.
- Preserve stable operation names when possible.
- Report added/removed/changed tools in diagnostics.
- Avoid refreshing implicitly during tool calls.

For v1, keep refresh **restart-only or admin/release-only**. Do not expose catalog
refresh as a normal Lisp discovery form; the current catalog model is
intentionally frozen at boot. **Open question:** whether refresh should be an MCP
admin tool, a PTC-Lisp discovery form, a release command, or all of the above.

### 5.2 Exec credential source

A future `exec` credential source, deferred until file/env rotation is
insufficient:

```json
{
  "source": "exec",
  "command": "/usr/local/bin/get-observatory-token",
  "scheme_hint": "bearer",
  "cache_ttl_ms": 300000
}
```

It adds process-spawn security, timeout, caching, and error-surfacing questions,
which is why it stays deferred behind the existing `env`/`file`/`literal` sources.

### 5.3 Write / safe-POST gating

Write methods (`POST`, `PUT`, `PATCH`, `DELETE`) are disabled in v1. Safe `POST`
query endpoints are deferred to a later milestone with **explicit operation
allow-listing and a process-level write/safe-post gate**. When method-based
classification is wired for writes, prefer the `_ptc.method` descriptor over the
synthesized `readOnlyHint` so a future write method does not silently classify as
read. Operator `operation_overrides` may narrow or rename `x-ptc-*` metadata, but
schema metadata must never widen capability beyond `include_operations` and
process-level gates.

### 5.4 JSONPath / JSON Pointer projection

Deferred from v1: both JSONPath and JSON Pointer response projection. V1 returns
decoded JSON and PTC-Lisp does local shaping. The `x-ptc-result-path` vendor
extension (e.g. `$.traces`) and `x-ptc-pagination` (cursor arg + next-cursor path)
are reserved schema/discovery metadata for when projection and auto-pagination
land; they are read at catalog compile time and never sent on the wire.

### 5.5 Synthetic-call sugar

**Open question:** whether direct synthetic calls like
`(observatory/list-traces {...})` should be added later as sugar over
`(tool/call 'observatory/list-traces {...})`. Generating dynamic namespaces is a
v1 non-goal; if added, the synthetic form must normalize to the same explicit map
shape (see [§2.3](#23-qualified-symbol-toolcall-dispatch-open-question)).

### 5.6 Authentication security rules

Authentication stays in config/runtime, never in PTC-Lisp. These security rules
are load-bearing for any adapter extension:

- HTTPS required by default for `schema_url` and `base_url`.
- Plain HTTP requires explicit opt-in.
- Sending auth over plain HTTP requires a **second** explicit opt-in.
- Secret-bearing headers are rejected from `static_headers`; use `auth`.
- PTC-Lisp cannot override `Authorization`, `Cookie`, `Host`,
  `Proxy-Authorization`, `Mcp-Session-Id`, or protocol-controlled headers.
- Auth values never appear in `tool/meta`, traces, debug output, result
  envelopes, or error messages.
- OpenAPI schema fetch should use the same auth model if schema access is private.

Reuse the existing credential model (sources `env`/`file`/`literal`; emitters
`bearer`/`basic`/`custom_header`; `scheme_hint` checks; per-request materialization
for `env`/`file` with no in-process value cache). Production recommendation: prefer
`file` source for service-token rotation (deployment replaces the file atomically;
next request uses the new token without restart).

### 5.7 Deferred questions

- How much JSON Schema validation/coercion should happen before the request in
  v1?
- Should OpenAPI operation names preserve snake_case or be normalized to
  kebab-case for PTC-Lisp display? Current preference: kebab-case at the Lisp
  surface, original operation id in metadata.
- Should direct synthetic calls like `(observatory/list-traces {...})` be added
  later as sugar over `(tool/call 'observatory/list-traces {...})`?
- Should write operations require **both** config allow-listing and a
  process-level `--aggregator-allow-writes` style flag?
