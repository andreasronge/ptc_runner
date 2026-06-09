# SubAgent ↔ Upstream Runtime: First-Class Integration

**Status:** Phase 1 implemented on `main` as of 2026-06-05 · **Created:**
2026-06-05 · **Revised:** 2026-06-06 (Phase 1.5 merged; the
`SubAgent.run(runtime:)` delegating facade is **deferred**, two §6 test-plan
items remain outstanding, and the capability-profile discussion is
cross-referenced so this plan stays the concrete upstream-provider bridge rather
than the generic capability-runtime design)
**Owner:** TBD · **Related:** `docs/plans/root-upstream-runtime.md`,
`docs/plans/transport-neutral-tool-upstreams.md`,
`docs/plans/capability-prelude-discovery.md`,
`docs/guides/capability-prelude.md` §5/§7

---

## 0. Implementation Status

Phase 1 has shipped in core:

- `PtcRunner.Upstream.Eval.run_subagent/3` owns one `RunContext` for the whole
  SubAgent run, enriches the agent with upstream `"call"` before prompt
  generation, threads `discovery_exec`, and returns drained upstream records.
- `SubAgent.run/2` **forwards** a caller-supplied `runtime:` opt through to
  `Loop.run/2`, so a prelude's `requires` is validated on the multi-turn loop
  path. It does **not** delegate to `run_subagent/3`: it opens no `RunContext`,
  does not enrich the agent with the upstream `"call"` tool, and drains no
  records. A bare `SubAgent.run(agent, runtime: rt)` therefore validates
  `requires` but cannot dispatch upstream calls — with no `RunContext` there is
  no `"call"` tool in scope, so a call attempt fails safe (raises
  undefined-tool); it does **not** silently dispatch a partial write. The
  dedicated thin facade that *delegates to the bridge* (§3.1) is **deferred to
  Phase 2**; `Upstream.Eval.run_subagent/3` is the supported entry point today.
- `Loop.run/2` threads an opaque `:runtime` handle through `State` and
  `Loop.LispOpts.build/4` so each turn's `Lisp.run/2` can validate prelude
  `requires` before user code.
- `:prelude_attach_failed` is terminal in PTC-Lisp, native tool-call, and
  combined text-mode paths rather than recoverable retry feedback.
- The single-shot fast-path bypass is closed for preludes with non-empty
  `requires`, even when `tool_refs` is empty.
- Child SubAgents remain upstream-blind unless explicitly run with their own
  runtime, matching the existing `discovery_exec` ownership boundary.
- `mcp_server` delegates agent-over-upstream execution to the core bridge while
  keeping its ledger and continuation-guard policy server-side.

Phase 2/3 items remain future work: a convenience facade for selecting/owning an
upstream runtime for a run, validate-once against a frozen-for-run snapshot, and
an optional Phase-3b core attempt record surface if audit completeness requires
it (**decision 2026-06-09: deferred — see the [Phase 3b decision](#phase-3b-decision-2026-06-09--defer)
block in §7**). Phase 3a's core default continuation guard driven by existing
`Turn.tool_calls` evidence is delivered. The broader capability-profile/provider
direction is tracked in
[`capability-prelude-discovery.md`](capability-prelude-discovery.md); this plan
stays scoped to the concrete upstream provider bridge.

Still outstanding *within* Phase 1's own plan:

- **The thin `SubAgent.run(runtime:)` delegating facade** (§3.1) — deferred to
  Phase 2; today `runtime:` on `SubAgent.run/2` is a passthrough, not a bridge
  delegate (see the bullet above).
- **§6 raise/fault test through the bridge** — close-on-raise is exercised on
  `with_run_context` directly (`upstream_runtime_test.exs`), but not through a
  genuinely-raising `run_subagent/3` path (a raising `llm` callback or a
  malformed `continuation_guard`, per §5.2).
- **§6 `:e2e` test** — real LLM + the bridge over the dummy upstream is not yet
  written.

Delivered status notes:

- **Guide docs (delivered, §9 T4)** — `docs/guides/capability-prelude.md` §7 now
  documents `run_subagent/3` as the multi-turn SubAgent↔upstream seam alongside
  `run_lisp/3`. (§5's cross-turn guarantee wording was already corrected to
  *fail-closed before any side-effecting turn*.)
- **Default side-effect guard (Phase 3a, delivered)** — standalone bridge
  consumers now get a core default `continuation_guard` from
  `Upstream.Eval.run_subagent/3`: read-classified upstream calls continue, while
  write or unknown calls stop before the next LLM turn with
  `:partial_side_effects`. Host-supplied `continuation_guard` still completely
  overrides the default. The guide §5/§7 documents the current default.

**Phase 1.5 (delivered) — see [§9 Implementation Checklist](#9-phase-15--implementation-checklist-do-now-workflow-executable).**
A small, behaviour-preserving cleanup batch the 2026-06-05 design review surfaced,
now shipped: the bridge calls the internal `Runner.run/2` (`Definition`-only — §9
T1), a Definition-contract test (T2) and the later Phase-3a default-guard tests
are in `test/ptc_runner/upstream/eval_run_subagent_test.exs`, and the guide
§7/§5 + §8 side-effect-guard docs are current (T4). Architecture unchanged; the
Phase-2 facade and optional Phase-3b record-surface work stay deferred. The §6
raise-through-bridge fault test and the `:e2e` test remain outstanding — T2/T3
do not close them.

Sections below preserve the original pre-implementation design record; read
current-architecture claims there as historical context unless this status
section says otherwise.

### Relationship to Capability Profiles

The capability-profile discussion reframes this plan's long-term role without
changing the shipped Phase 1/1.5 bridge:

- `PtcRunner.Upstream.*` remains the concrete upstream provider implementation
  for OpenAPI and external MCP tools.
- `PtcRunner.Upstream.Eval.run_lisp/3` and `run_subagent/3` are upstream adapters
  around `Lisp.run/2` / the SubAgent runner, not the generic capability runtime.
- Future generic record, effect, guard, and descriptor work should be designed so
  upstream can become the first capability provider rather than the only special
  case.
- Child SubAgents being upstream-blind today maps to a broader future principle:
  child agents should not inherit a parent's capability profile or provider
  authority unless the host explicitly grants that composition.
- A run-scoped `upstreams:` convenience may still be useful, but it should not
  pre-empt a future capability-profile facade that can own upstream plus other
  providers.

## 1. Problem

A multi-turn `PtcRunner.SubAgent` cannot drive an upstream (MCP/HTTP/OpenAPI)
runtime through a first-class core API. The orchestration that lets it happen
lives in the **mcp_server** app (`PtcRunnerMcp.Agentic.run_subagent/5`), not in
`ptc_runner`. Two consequences:

1. **Misplaced layer.** Post-refactor, `mcp_server` should only *expose*
   `ptc_runner` as an MCP server. Agent-over-upstream orchestration is core
   capability, not server-exposure logic. A `ptc_runner`-only consumer (no
   mcp_server) has no supported way to run a multi-turn agent over upstream
   tools — they'd have to re-implement the adaptation.
2. **Weakened prelude safety on the path agents actually use.** A tool-backed
   capability prelude's attach-time `requires` validation is **fail-closed only
   when a `:runtime` is threaded into the attach path** (`lisp.ex:409-415`). The
   SubAgent loop never threads `:runtime` (`lisp_opts.ex:30-50`), so on the
   multi-turn path `requires` is **not** validated; the prelude's "a missing
   backing can never cause a partial run with side effects" guarantee (guide §5)
   silently degrades to a runtime-recoverable error. For write-effect upstream
   ops this is the difference between "never attempted" and "attempted, then
   rejected" — and in the requires/body-divergence case (§3.5 #1) it is the
   difference between "rejected" and an **actually-dispatched unauthorized
   write**.

> The upstream **client** (`lib/ptc_runner/upstream/*` — `Runtime`, `Eval`,
> `OpenApi`, MCP transports, `Catalog`, `Credentials`) is **already in core**.
> `Upstream.Eval.run_lisp/3` works standalone. The gap is purely the
> **SubAgent ↔ runtime bridge**, plus the multi-turn lifecycle around it.

---

## 2. Current architecture (grounded)

### What's where

| Concern | Location | Notes |
|---|---|---|
| Upstream client (Runtime/Eval/transports/catalog/creds) | `lib/ptc_runner/upstream/*` (core) | ✅ correct |
| Single-shot eval against a runtime | `Upstream.Eval.run_lisp/3` (core) | sets `:runtime` → prelude `requires` validated |
| Run-context lifecycle | `Upstream.Eval.with_run_context/3` (core, `eval.ex:33-43`) | opens/closes one `RunContext` (ledger, discovery, limits); `try/after` closes on return *and* raise |
| Runtime → tools + discovery hooks | `Upstream.Eval.eval_options/1` (core, `eval.ex:24`) | yields `tools` `"call"` fn + `discovery_exec` |
| SubAgent loop opts builder | `Loop.LispOpts.build/4` (core, `lisp_opts.ex:30-50`) | threads `tools:`, `prelude:`, `discovery_exec:` — **never `:runtime`** |
| Prelude attach + requires gate | `Lisp.attach_prelude/4` (core, `lisp.ex:407-415`) | `nil` runtime → `compile_prelude_only` (no validation); non-nil → `PreludeAttach.attach` (`lisp.ex:414`) |
| **SubAgent ↔ upstream glue** | **`PtcRunnerMcp.Agentic.run_subagent/5`** (mcp_server) | **misplaced** |
| Server's aggregated-upstreams config | `PtcRunnerMcp.RootUpstreamRuntime` (mcp_server) | reasonably server-specific — **stays** |

### How the bridge works today (`agentic.ex:165-194`)

```elixir
Eval.with_run_context(RootUpstreamRuntime.runtime(), root_context_opts(), fn context ->
  eval_opts = Eval.eval_options(context)
  root_agent = %{agent | tools: root_tools_with_ledger(eval_opts[:tools], ledger)}
  SubAgent.run(root_agent,
    llm: llm,
    context: validated.context,
    discovery_exec: eval_opts[:discovery_exec],
    ...)
end)
```

The runtime is **adapted into a `tools` function map + a `discovery_exec` hook**;
the runtime object never enters SubAgent. The whole multi-turn `SubAgent.run`
executes inside **one** `with_run_context` (so the ledger, discovery cache, and
limits span all turns). Critically, `:runtime` is *not* passed to the prelude
attach path → `requires` validation is skipped.

### Why it's like this (legit forces, not just history)

1. **SubAgent's tool seam is deliberately "just functions"** (`fn args -> result`).
   Zero dependency on the upstream process subsystem. SubAgent runs identically
   over pure Elixir / child agents / MCP / HTTP / test stubs. Decoupling has real
   value (it is a *choice*, not a forced dependency — both are one OTP app).
2. **One run-context must span all turns.** `with_run_context` opens/closes a
   `RunContext` (ledger, discovery backend, per-call limits, response caps). A
   multi-turn run spans N evals; the ledger/limits/discovery cache must aggregate
   across **all** of them.

   **Correction (this revision):** the original sketch read this force as
   "core SubAgent must *own* the run-context lifecycle inside its turn loop."
   That conflates two different things:

   - the **runtime handle** — a long-lived `%Upstream.Runtime{}`/pid GenServer,
     used by `Lisp.run` in exactly one place: read-only attach-time `requires`
     validation (`PreludeAttach.attach` → `Runtime.upstream/2`). Threading it
     into `Lisp.run` opens **no** context and touches **no** counter; and
   - the **per-run `RunContext`** — the ledger/caps/discovery wrapper.

   Cross-turn aggregation does **not** require the loop to own the context. The
   `tools`/`discovery_exec` closures returned by `eval_options/1` capture the
   process-external `Collector` and the `:atomics` counters; they aggregate
   across turns *regardless of where the context is opened*. `agentic.ex` already
   proves this — it wraps the **entire** `SubAgent.run` in one `with_run_context`
   with **zero** changes to `Loop.run`. So the right boundary is an **outer
   bridge**, not lifecycle ownership inside the loop.
3. **History.** mcp_server was the first/only consumer needing
   agent-over-aggregated-upstreams; the glue grew there.

---

## 3. Proposed design

Add a first-class upstream story to core as a **bridge module** that owns the
run-context lifecycle from *outside* the SubAgent loop — the same shape
`agentic.ex` already uses — so the loop stays upstream-light and mcp_server's
`run_subagent` collapses to "pass the server's runtime (and its ledger policy) to
the core bridge."

### 3.1 Public API

**Primary — the core bridge (mirrors `Upstream.Eval.run_lisp/3`):**

```elixir
PtcRunner.Upstream.Eval.run_subagent(runtime, agent, opts)
```

The bridge owns the whole lifecycle:

1. open **one** `RunContext` (`with_run_context`) spanning the entire run;
2. derive `{tools, discovery_exec}` via `eval_options/1`;
3. build an **enriched agent** whose tool map merges the upstream `"call"` tool
   into `agent.tools` (collision policy in §3.4) — done **before** the agent runs
   so it is prompt-visible (§3.2.1);
4. call the **internal runner** `Runner.run(enriched, … discovery_exec:,
   runtime:)` — **not** the public `SubAgent.run/2`, so the optional
   `SubAgent.run(runtime:)` facade can delegate to the bridge without recursing
   (see the implementation note below);
5. drain upstream records, then close the context (the existing
   `with_run_context` `after`).

`opts` accepts the normal `SubAgent.run` opts plus the upstream context-limit
keys (`:max_tool_calls`, `:max_catalog_ops`, `:call_timeout_ms`,
`:max_response_bytes`, `:max_catalog_result_bytes`) and an optional
`on_upstream_call`/tool-decorator + `continuation_guard` (§3.4). `:discovery_exec`
and `:runtime` are **bridge-owned**: `run_subagent/3` drops any caller-supplied
values for these keys and sets them itself from the `RunContext`, so the facade's
"one public meaning" holds — a caller cannot smuggle a different runtime or
discovery hook into the bridge path. (This differs from `run_lisp/3`'s
`Keyword.put_new(:runtime, runtime)` precedent, where an explicit caller key
wins.)

**Optional — a convenience facade (sugar, *not* the primary architecture):**

```elixir
SubAgent.run(agent, llm: llm, context: ctx, runtime: upstream_runtime)
```

This delegates to `Upstream.Eval.run_subagent/3` (so it also enriches the agent
and routes through the loop). It exists purely for call-site ergonomics; the
bridge is the real entry point. Keep the delegation thin — the facade is the
*only* place `SubAgent` references `Upstream`, and it should add no behaviour of
its own. When `runtime:` is absent, behaviour is exactly as today (tools-only).

**Implementation note (facade↔bridge recursion, return shape, and the semantics
change).** Three things the facade must get right:

- *Avoid recursion.* The bridge re-enters SubAgent via the internal
  `PtcRunner.SubAgent.Runner.run/2`, **not** the public `SubAgent.run/2` (as the
  §3.2 lifecycle shows). The bridge passes `runtime:` in its opts and the facade
  keys on `runtime:`, so calling the public entry would recurse (facade → bridge
  → `SubAgent.run` → facade → …). *Delivered in **Phase 1.5** (§9 T1): the bridge
  now calls `PtcRunner.SubAgent.Runner.run/2` directly — decoupled from the
  deferred facade, behaviour-preserving (the `%Definition{}` clause of
  `SubAgent.run/2` is a pure forward to `Runner.run/2`), and pre-empting the
  recursion the moment a Phase-2 facade lands. The switch also narrowed
  `run_subagent/3` to **`Definition`-only** (`@spec` → `Definition.t()`;
  `enrich_agent/3` matches `%Definition{}` specifically, so a non-Definition fails
  closed at enrich with `FunctionClauseError` rather than slipping through to raise
  later in `Runner.run/2`).*
- *Return shape.* `SubAgent.run(runtime:)` returns only the `SubAgent.run/2`
  result, **dropping** the bridge's `records` — mirroring `run_lisp/3` vs
  `run_lisp_with_records/3`. This keeps the public facade unsurprising and leaves
  any records-on-`Step` surface for the optional Phase 3b audit-completeness work
  (§3.4).
- *Semantics change — only one public meaning.* The facade changes what
  `SubAgent.run(agent, runtime: rt)` *means*. Today it is an attach-validation
  **passthrough**: `runtime:` reaches `Lisp.run`'s attach path and validates the
  prelude's `requires`, but it does **not** enrich `"call"`, open a `RunContext`,
  or execute upstream calls (a call attempt fails safe with undefined-tool). Once
  the facade lands it becomes a full **bridge delegate** (enriches `"call"`,
  opens one `RunContext`, drains records, executes upstream). After the facade,
  treat the public `SubAgent.run(runtime:)` as having a **single** meaning — the
  bridge — and treat the `:runtime` opt at the `Runner.run` / `Loop.run` /
  `LispOpts` level as internal plumbing the bridge sets for per-turn attach
  validation, **not** a public entry point for upstream execution. Audit existing
  public `SubAgent.run(..., runtime:)` call sites when the facade lands (e.g.
  `test/ptc_runner/upstream/eval_run_subagent_test.exs`): they flip from
  passthrough to bridge semantics and must move to `Runner.run/2` if they only
  wanted attach validation. Tests and comments must not conflate "runtime reaches
  attach validation" with "runtime-backed upstream execution."

### 3.2 Lifecycle: the bridge owns it, the loop stays upstream-light

```
Upstream.Eval.run_subagent(runtime, agent, opts)
  └─ with_run_context(runtime)                 ── ONE context, spans the whole run (OUTSIDE the loop)
       ├─ {tools, discovery_exec} = eval_options(context)
       ├─ enriched = %{agent | tools: merge "call" tool}   ── before prompt generation
       └─ Runner.run(enriched, discovery_exec:, runtime:)   ── internal runner (not public SubAgent.run ⇒ no facade recursion)
            ├─ turn 1: Lisp.run(prog, …, runtime: rt)   ── rt = HANDLE (attach validation only)
            ├─ turn 2: Lisp.run(prog, …, runtime: rt)   ── same closures ⇒ same ledger/caps/discovery
            └─ turn N: …
  └─ drain records → close                     ── with_run_context `after`: fires on return AND raise
```

Implementation notes:

- **The SubAgent loop gains exactly one thing: a `:runtime` *handle*
  passthrough.** Plumb it `Loop.run/2` opts → `run_opts` → `State` →
  `LispOpts.build/4`, mirroring how `discovery_exec` already flows
  (`loop.ex:159 → 207 → 306`). `LispOpts.build/4` gains a single
  `|> maybe_put(:runtime, Map.get(state, :runtime))` next to the existing
  `:prelude`/`:discovery_exec` lines (`lisp_opts.ex:48-49`). The loop never opens
  or closes a `RunContext`; it only forwards the handle so each turn's `Lisp.run`
  can validate `requires` (§3.3).
- **No new `try/after` inside `Loop.run`.** The single `RunContext`'s
  open/drain/close lives in `with_run_context` (`eval.ex:33-43`), already
  exercised by the "closes the collector when callback raises" test. Reuse it;
  don't re-implement teardown in the loop. (Note: on a *raise*, `with_run_context`
  closes **without** draining — records are lost. Match or deliberately improve
  this when porting; don't change it by accident.)
- **Cross-turn aggregation is automatic.** The `tools`/`discovery_exec` closures
  capture the process-external `Collector` + `:atomics` counters from the one
  `RunContext`, so the ledger, caps, and discovery cache aggregate across all
  turns exactly as `agentic.ex` achieves today.
- **No `Runner.run/2` fast-path change for the bridge path.** Because the bridge
  enriches `agent.tools` with the `"call"` tool *before* the runner runs,
  `map_size(agent.tools) != 0`, so the run already routes to `Loop.run` (the
  single-shot predicate at `runner.ex:85-87` requires an empty tools map). The
  prompt inventory is built from the enriched `agent.tools`, so it matches the
  execution surface by construction. (The single-shot fast path still needs the
  `requires` guard for an agent with *no* local tools that is **not** enriched by
  the bridge — i.e. the internal passthrough / plain `SubAgent.run` with a
  `runtime_prelude` — independent of the facade; see §3.5 #1, which must be fixed
  regardless.)

### 3.2.1 Prompt-visible tool enrichment

The SubAgent prompt is built from `agent.tools` /
`BuiltinTools.effective_tools(agent)` before the first turn, and the per-turn
execution surface is re-derived from the same `agent.tools` each turn. So the
upstream `"call"` tool must be merged into **`agent.tools` itself**, once, by the
bridge before the agent runs — exactly what `agentic.ex:173` does today
(`%{agent | tools: root_tools_with_ledger(eval_opts[:tools], ledger)}`).

Do **not** also merge upstream tools inside the per-turn `LispOpts.build/4`
opts: the per-turn path needs only the runtime *handle* (for attach validation),
not the tool merge. Two merge sites would re-introduce the `LispOpts`-divergence
bug class (#874) the single builder exists to prevent. One merge, on the agent,
in the bridge.

### 3.3 Prelude `requires` validation (the safety fix)

Once each turn's `Lisp.run` receives `:runtime`, `attach_prelude/4`
(`lisp.ex:414`) takes the `PreludeAttach.attach/2` branch → `requires` is
validated **before any user code runs**, fail-closed. This restores the guide §5
**per-turn fail-closed validation** on the multi-turn path (initial attach, plus
re-validation each turn) — though under the default `:live` catalog the resulting
guarantee is *fail-closed before any side-effecting turn*, not whole-run
side-effect freedom (§3.5 #2). The same fix must also cover the **single-shot
path** (§3.5 #1), so the validation does not depend on which execution surface the
agent happens to select.

### 3.4 Tool merge + side-effect policy

**This is a Phase 1 compatibility choice, not the target boundary** (see §4's
principle and §7 Phase 3). The mcp side-effect machinery already proves the
policy shape, but Phase 3 should migrate it incrementally rather than treating a
new core ledger as the gating first step:

- The `continuation_guard` (`agentic.ex:346-354`) blocks continuation via
  `Ledger.side_effecting_attempted?`, which keys on each entry's **`:effect`**
  (`:write`/`:unknown`), recorded **before** dispatch so an interrupted write
  still blocks (`agentic_contract_test.exs` locks "records attempt before
  dispatch"). This is already an MCP-side Phase-0 contract, not a greenfield
  design problem.
- That `:effect` classification is **not** inherently mcp-specific: it is a
  trivial, domain-blind pure function (`annotations_effect/1`,
  `agentic.ex:275-283`) over `readOnlyHint`/`destructiveHint` **catalog
  annotations that core already exposes** (the `:meta` discovery dispatch returns
  `tool_entry["annotations"]`, `upstream/discovery.ex`; and they ride on
  `Runtime.catalog_snapshot/1`, `upstream/runtime.ex:107-108`;
  `upstream/open_api/compiler.ex:78` synthesizes `readOnlyHint` for GETs). Core
  can compute the same classification from its own catalog. For OpenAPI, prefer
  the `_ptc.method` descriptor (`compiler.ex:82`) over the synthesized
  `readOnlyHint`; OpenAPI v1 is GET-only today (`require_get`, `compiler.ex:90`),
  but method-based classification avoids a latent trap if write methods are added
  later. For MCP, treat `readOnlyHint`/`destructiveHint` as **weak, untrusted
  server-supplied hints**: the `unknown ⇒ side-effecting` default protects the
  *absent*-annotation case, but a present-but-lying `readOnlyHint: true` still
  classifies as `:read` and therefore does not trip the default guard — that
  residual trust is the host's risk to accept, not something core can close.
- Core already has the continuation stop hook (`:continuation_guard`) and already
  has turn-local evidence: the upstream `"call"` tool is merged into
  `agent.tools`, so `(call ...)` / `(tool/call ...)` appears in
  `Turn.tool_calls` with `name: "call"` and args containing `server`, `tool`, and
  `args`. That is enough for the Phase-3a default guard. A guard can scan the
  completed turn, classify each upstream call, and stop before the next LLM turn
  when any call is `:write` or `:unknown`. No `RunContext` drain, `:turn`
  threading, `:args_hash`, or `Step.upstream_calls` schema is required for that
  cooperative stop-after-observed-side-effect property.
- The default guard should mirror the proven MCP stop shape without depending on
  MCP modules: emit the core reason atom `:partial_side_effects`, return
  `{:stop, {:error, %Step{}}}`, and build the failed step from `next_state` with
  `StepAssembler.finalize/3` (`turn_offset: -1`, `is_error: true`) so the
  side-effecting turn is preserved under trace filters. Classify and collect
  matched calls from `turn.tool_calls`, but build memory, turns, journal,
  child-steps, and usage from `next_state`.
- Guard details must be sanitized. `Turn.tool_calls` carries full upstream args
  and result payloads; `Step.fail.details` must project only minimal
  `%{server: server, tool: tool, effect: effect}` entries. Do not copy raw
  `args`, `result`, or the whole tool-call map into the failure details. If a
  `"call"` entry is malformed and lacks `server` or `tool`, treat it as
  `:unknown` and stop fail-closed.
- The pre-dispatch record surface remains useful, but it is **Phase 3b audit
  completeness**, not Phase 3a's gate. It closes holes the turn-surface guard
  cannot close: a write whose request is already on the wire when the sandbox
  timeout fires, or a transport that raises after dispatch. If built, record only
  on the `:proceed` arm before `Runtime.call_tool`, classify there, and retire
  any overlapping MCP decorator/ledger path in the same migration so metrics and
  call limits are not double-counted.

The Phase-3a default is therefore: neutral classification in core, unknown
effect treated as side-effecting, and absent a host policy core stops
continuation after an observed side-effecting upstream call. The host may
override the decision via `:continuation_guard` (allow / prompt / require
approval) and still owns deployment policy plus protocol/UX. Be precise about
the guarantee: this is a **turn-boundary circuit breaker**, not write
prevention. The first side-effecting call, same-turn `pmap` siblings, terminal
turns, and single-shot paths are outside that guarantee unless a later
pre-dispatch deny/approval seam is added.

So **Phase 1 keeps mcp's `"call"` wrapper and `continuation_guard` mcp-owned**,
passed into the bridge as opts:

- Collision policy: the bridge reserves the upstream `"call"` key when `runtime:`
  is present and raises on a silent local override (mirroring
  `validate_tool_data_conflict!`'s raise style, `runner.ex:180-213`) unless an
  explicit override flag is supplied (tests/stubs). A local `"call"` would make
  `requires` validation (against the runtime) and execution (a local fn)
  disagree. The collision check lives in the bridge, not in `Loop`/`LispOpts` —
  the string key `"call"` stays out of generic loop code.
- The bridge accepts an optional **tool decorator** (`on_upstream_call` /
  `upstream_tool_wrapper`) and a `continuation_guard`; mcp passes its
  `root_tools_with_ledger` decorator + guard and keeps `Ledger`/`Projection`
  entirely server-side. **No mcp `Ledger` format enters core.** Phase 3a can
  coexist with this because a host-supplied guard overrides the core default;
  Phase 3b must delete or replace overlapping MCP ledger decoration if core
  starts recording pre-dispatch attempts.
- The bridge returns the drained `RunContext` records to the caller (and may
  attach them to the final `Step`). Do not design `Step.upstream_calls` solely for
  Phase 3a; no current consumer requires it. Revisit a single core record surface
  only if Phase 3b makes audit-complete attempts a committed requirement.
- `discovery_exec` from `eval_options` flows to the loop exactly as today.

### 3.5 Phase 1 correctness requirements (promoted from "risks")

These are **requirements**, not open questions. Each has a failing test written
first (repo bug-fix rule).

1. **Single-shot path must not skip `requires` validation.** The fast-path
   predicate (`runner.ex:85-87`) gates on `map_size(agent.tools) == 0` and
   `not prelude_tool_backed?(agent.runtime_prelude)`, but `prelude_tool_backed?/1`
   (`runner.ex:122-125`) keys on **`tool_refs`** (AST-derived), **not**
   `requires`. These diverge: an export with explicit
   `{:requires ["upstream:crm/do_write"] :effect :write}` and a body containing
   **no** literal `(tool/…)` form compiles to `tool_refs = []` →
   `prelude_tool_backed? = false` → the agent routes to `run_single_shot`, which
   calls `Lisp.run(code, …, prelude: agent.runtime_prelude)` with **no**
   `:runtime` (`runner.ex:316-322`). Its write-effect `requires` is never
   validated, and because the declared id and the literal args diverge, the
   runtime call guard can't catch it either → an unauthorized write can actually
   dispatch. **Fix:** make any prelude with non-empty `requires` ineligible for
   the single-shot fast path (preferred — add a `prelude_requires_backed?` clause
   to the predicate), **or** thread `:runtime` into the single-shot `Lisp.run`
   when present. Either way the agent's `requires` validation must not depend on
   which execution surface it lands on.

2. **A mid-run attach failure must fail closed, not become a retry turn.**
   `catalog_snapshot_mode` defaults to **`:live`** (`runtime.ex:37`), which
   re-fetches upstreams per catalog op, so a turn-N `requires` re-validation can
   fail where turn 1 passed (a tool disappears upstream mid-run). But a turn-N
   `Lisp.run` returning `{:error, :prelude_attach_failed}` currently flows
   through the **recoverable** error branch (`loop.ex:841`) → builds LLM feedback
   → `{:continue, …}` (`loop.ex:871`). By then turns 1..N-1 may already have
   executed write-effect upstream calls — directly contradicting "never a partial
   run with side effects." **Fix (V1):** treat `:prelude_attach_failed` as a
   **hard stop** — a missing backing is not a program error the LLM can fix by
   rewriting, so terminate the run rather than feeding it back. (Phase 3's
   validate-once-against-a-frozen-run-snapshot is the more elegant long-term
   answer: it removes both the per-turn redundancy *and* the live-catalog hazard.
   Until then, hard-stop is the minimal change that restores the guarantee.) The
   "fail-closed on the multi-turn path" claim must be qualified to "before any
   side-effecting turn," not "on every turn under a live catalog."

3. **Child agents are upstream-blind in V1 (explicit, not an open question).**
   `SubAgentTool`/`as_tool` children build run_opts that inherit only
   `llm`/`llm_registry`/`context`/`_nesting_depth`/`_remaining_turns`/
   `_mission_deadline` (+`max_heap`) — **not** `discovery_exec`, **not**
   `continuation_guard`, and **not** `runtime`
   (`tool_normalizer.ex:380-389`; `discovery_exec` is explicitly "caller-owned,
   not inherited" at `loop.ex:157-159`). Phase 1 **decides: a child SubAgent does
   not inherit the parent's runtime — it is upstream-blind unless it carries its
   own `runtime_prelude` *and* is run through its own runtime/bridge.** Rationale:
   matches the existing
   `discovery_exec` ownership model and avoids accidental shared upstream
   authority across a composition boundary. Consequence: the fail-closed
   guarantee holds for the agent the bridge enriches, **not transitively** for
   its children; a child whose own `runtime_prelude` carries `requires` has those
   `requires` **left unvalidated** (the child runs upstream-blind) unless it is
   itself run through its own bridge/runtime. Document this boundary in the guide.

---

## 4. Migration / what moves vs. stays

| Item | Action |
|---|---|
| `Agentic.run_subagent/5` | Collapse to `Upstream.Eval.run_subagent(RootUpstreamRuntime.runtime(), agent, llm:, context:, continuation_guard:, on_upstream_call: ledger_decorator, …)` |
| `with_run_context`-spans-the-run wrapper + agent enrichment | **Move to core** (`Upstream.Eval.run_subagent/3`) |
| `:runtime` handle threading through the SubAgent loop | **New** — one passthrough (`Loop.run` opts → `State` → `LispOpts.build`) |
| `root_tools_with_ledger/2`, `call_with_ledger/3`, effect classification, `continuation_guard`, retry-feedback rendering | **Phase 1: stay in mcp_server**, passed into the bridge as a tool decorator + guard. **Phase 3a:** move neutral effect classification and the default stop-after-observed-side-effect `continuation_guard` policy to **core** using `Turn.tool_calls`; mcp keeps deployment policy + protocol/UX and may continue overriding the guard. **Phase 3b, only if audit completeness is required:** move pre-dispatch attempt recording into core and delete/replace the overlapping MCP ledger decorator. |
| `RootUpstreamRuntime` (upstream runtime *selection*/config) | **Stays in mcp_server** (host-owned: which upstreams a deployment selects). A future capability profile may provide a more general host-owned facade, but this plan should not move endpoint/credential authority into preludes. |
| `Ledger` retention / projection / export format | **Stays** mcp-side. Phase 3a does not move the MCP ledger format or add `Step.upstream_calls`. Revisit a generic core attempt record only in Phase 3b if the audit-completeness holes justify it; mcp still owns retention/projection/export. |
| `SubAgent.run(runtime:)` facade | Optional thin delegate to the bridge |

Principle (target boundary): **core owns *how* an agent drives an upstream
runtime — including neutral catalog metadata, generic side-effect
classification, and policy *extension points* (`continuation_guard`,
`on_upstream_call`, approval callbacks, caps) with safe defaults. Core should own
attempt recording only if a committed audit-completeness requirement needs a
provider-neutral pre-dispatch ledger. The embedding host owns upstream runtime *selection* and
deployment-specific *decisions* — authorization, and the UX/protocol around
approval, denial, continuation, retries, and audit export.** `mcp_server` is
**one such host**: it configures and exposes `ptc_runner` and installs
MCP-specific policy callbacks; it is **not** the architectural home for upstream
execution or generic side-effect logic. Otherwise `ptc_runner`-standalone users
would have to reimplement safety policy — the very layering problem this bridge
exists to fix. The Phase 1 split above is **compatibility with the existing
contract**, not the target; Phase 3a (§7) moves the generic classification and
default guard into core, ideally in a shape that can later be reused by a
capability-provider runtime above `PtcRunner.Upstream.*`.

---

## 5. Risks & open questions

(The three former entries here — single-shot bypass, live-catalog re-validation,
child inheritance — are now Phase 1 requirements in §3.5.)

1. **Coupling SubAgent → Upstream — now minimal.** The loop gains only an opaque
   `:runtime` handle passthrough (it never interprets it beyond forwarding to
   `Lisp.run`). The bridge lives in the `Upstream` namespace, consistent with
   `Upstream.Eval`/`Session`. The optional `SubAgent.run(runtime:)` facade is the
   only `SubAgent → Upstream` reference; keep it a thin delegate. Guard the
   `runtime:` codepath so a `nil` runtime is a pure no-op (today's behaviour).
2. **Context lifetime on raise.** Reuse `with_run_context`'s tested `after`
   close. Note records are **not** drained on a raise today (lost); decide
   deliberately whether the port matches or improves that. Add a fault test that
   exercises an **actually-raising** path (a raising `llm` callback, or a
   `continuation_guard` returning a malformed value → `loop.ex:487`) — asserting
   close-on-*sandbox-timeout* proves nothing, since that path returns an
   `{:error, Step}` normally, not a raise.
3. **Per-turn re-validation cost.** Re-attaching/validating `requires` each turn
   is idempotent and cheap (pure reads of the runtime handle's catalog). The
   Phase 3 frozen-snapshot validate-once both removes the redundancy and closes
   §3.5 #2's live-catalog hazard. Don't let the redundancy argument motivate
   caching state inside `Loop` (that would re-introduce the lifecycle coupling
   this design avoids).
4. **Core record surface.** Do not add a drained-records-on-`Step` or
   `step.upstream_calls` schema for Phase 3a's default guard. Revisit one core
   record surface only if Phase 3b commits to audit-complete pre-dispatch
   attempts.
5. **Catalog snapshot mode.** `live`/`frozen` is a property of the **Runtime**,
   orthogonal to how many `RunContext`s wrap the run. The real decision driven by
   it is §3.5 #2, not "does one context freeze the catalog" (it doesn't).

---

## 6. Test plan

*Status legend (added on status reconciliation): items without a status marker
are delivered — see `test/ptc_runner/upstream/eval_run_subagent_test.exs`,
`test/ptc_runner/sub_agent/loop/lisp_opts_test.exs`, and the mcp_server
`agentic_contract_test.exs`; items marked **outstanding** are not yet written.*

- **Core unit:** `LispOpts.build` threads `:runtime`; `nil` runtime is inert.
- **Bridge lifecycle:** one `RunContext` opens/closes per
  `Upstream.Eval.run_subagent`; ledger/caps aggregate across turns; drained
  records are available before close; closes on success, recoverable error, and
  **raise** (fault test against a genuinely-raising path, per §5.2).
  *(Status: happy-path, recoverable-error, round-trip, and the direct
  `with_run_context` close-on-raise are covered; the genuinely-raising path
  **through the bridge** is **outstanding**.)*
- **Prelude requires — loop path (the safety fix):** a tool-backed prelude whose
  `requires` is *not* satisfied fails fast with `:prelude_attach_failed` **on the
  SubAgent multi-turn path** before any turn runs. Mirror
  `test/ptc_runner/lisp/prelude/attach_test.exs` via the bridge.
- **Prelude requires — single-shot path (§3.5 #1):** an agent with `output:
  :ptc_lisp`, `max_turns: 1`, no local tools, `retry_turns: 0`, and a
  `runtime_prelude` whose export has **non-empty `requires` but empty
  `tool_refs`** must **not** take `run_single_shot`; its `requires` validates
  fail-closed (or the run is routed to the loop). This is the path with no
  existing test and the one that can dispatch an unauthorized write.
- **Mid-run hard stop (§3.5 #2):** a multi-turn run where `requires` becomes
  unsatisfiable at turn N (live catalog) → `:prelude_attach_failed` **terminates**
  the run; it is **not** fed back as a recoverable turn, and no side-effecting
  call fires after the failure.
- **Child upstream-blind (§3.5 #3):** a parent with a runtime and an `as_tool`
  child whose own `runtime_prelude` carries `requires` but is given no runtime →
  the child is upstream-blind: its `requires` are **not validated** (attach
  proceeds without runtime-backed checks) unless it is run through its own
  bridge/runtime; assert the documented boundary (no transitive inheritance).
- **Prompt/execution alignment:** with the bridge, the first-turn prompt
  inventory includes the upstream `"call"` tool and the per-turn execution
  surface matches.
- **Collision policy:** local `"call"` plus `runtime:` is rejected unless an
  explicit override flag is supplied.
- **Round-trip:** real upstream (reuse `start_http_fixture` /
  `examples/ptc_repl_dummy_upstream`) — a multi-turn agent calls a tool-backed
  export against a reachable upstream and surfaces the result (deterministic
  counterpart to `upstream_roundtrip_test.exs`, now via the bridge).
- **e2e (`:e2e`):** real LLM + the bridge over the dummy upstream — the combined
  path that currently has no single home. *(Status: **outstanding** — not yet
  written.)*
- **mcp_server regression:** `agentic_contract_test.exs` still green after
  `run_subagent` collapses onto the core bridge (the ledger decorator + guard are
  unchanged mcp-side, so its `Ledger`/`root_tools_with_ledger` units still pass).
- **Definition-only contract (§9 T1/T2, delivered):** `run_subagent/3` runs a
  `%Definition{}` and **raises** `FunctionClauseError` at `enrich_agent/3` for a
  non-Definition agent — a bare string, a `%CompiledAgent{}`, and (critically) a
  bare map that *does* carry a `:tools` field. The map case asserts the raise
  originates in `enrich_agent/3` specifically, so a loose `%{tools: _}` regression
  (which would instead raise later in `Runner.run/2`) fails the test. Locks the
  contract that the bridge re-enters the internal `Runner.run/2`, not the public
  facade.
- **Default side-effect guard (§7 Phase 3a, delivered):** the old no-default
  canary has been replaced. `eval_run_subagent_test.exs` now pins three core
  behaviours: unknown/write-effect upstream calls stop continuation with
  `:partial_side_effects`; read-classified upstream calls reach turn 2; and a
  host-supplied `continuation_guard` overrides the default. The stop details use
  the sanitized `%{matched_calls: [%{server, tool, effect}, ...]}` shape and
  never include upstream args, results, or raw tool-call maps. *(Distinct from
  the still-outstanding
  raise-through-bridge fault test and `:e2e` test — the canary pins behaviour, it
  does not exercise a raising path or a real LLM.)*

---

## 7. Phasing

1. **Phase 1 (core bridge + safety, all required):**
   - `PtcRunner.Upstream.Eval.run_subagent/3` bridge: one `RunContext` spanning
     the run, `eval_options` closures, agent-tool enrichment **before** prompt
     generation, drain + close; accepts a tool decorator + `continuation_guard`.
   - `:runtime` handle passthrough in the SubAgent loop (`Loop.run` →
     `State` → `LispOpts.build`).
   - **§3.5 #1** single-shot `requires` validation, **§3.5 #2** mid-run hard
     stop, **§3.5 #3** children upstream-blind — all three.
   - Collapse `Agentic.run_subagent` onto the bridge, keeping mcp's ledger
     decorator + guard (§3.4 option 3).
   - Optional: the thin `SubAgent.run(runtime:)` facade (trivial once the bridge
     exists). **Deferred to Phase 2** — not shipped in Phase 1; `runtime:` on
     `SubAgent.run/2` is currently a loop passthrough, not a bridge delegate.

   This closes both the misplacement and the prelude fail-closed gap without
   moving the existing MCP ledger contract (its retention/projection/export
   format) into core yet — the *generic* ledger/classification/guard mechanism
   does belong in core; that move is Phase 3 (§4 target boundary).

   **Phase 1.5 (delivered, §9):** behaviour-preserving cleanups from the
   2026-06-05 review, now shipped — bridge → internal `Runner.run/2`
   (`Definition`-only), Definition-contract tests, and the guide §7/§5 + §8
   seam docs. No architecture change; did not gate or block Phases 2/3. The
   later Phase-3a default side-effect guard is also now delivered. The §6
   raise-through-bridge fault test and the `:e2e` test remain outstanding.
2. **Phase 2 (convenience):** a run-scoped convenience for selecting or owning
   an upstream runtime for the run's duration, plus the thin
   `SubAgent.run(runtime:)` delegating facade (deferred from Phase 1). One
   possible API is an `upstreams: config` facade over the bridge; another is a
   small capability-profile facade that imports existing upstream JSON. Do not
   let the convenience API pre-empt the broader profile/provider design in
   `capability-prelude-discovery.md`. The bridge still does **not** need
   `runtime:` lifecycle ownership inside the loop.
3. **Phase 3a (default side-effect circuit breaker, delivered):** the generic,
   provider-neutral pieces needed for standalone safety now live in core without
   adding a new ledger:
   - `PtcRunner.Upstream.Effect.classify(runtime, server, tool)` returns
     `:read | :write | :unknown`; classify OpenAPI from `_ptc.method`, classify
     MCP from its (weak, untrusted) `readOnlyHint`/`destructiveHint` annotations,
     and fail closed on missing/conflicting metadata;
   - `Upstream.Eval.run_subagent/3` installs a default `continuation_guard` with
     `Keyword.put_new/3`, so a host-supplied guard completely owns policy when
     present;
   - the default guard scans `Turn.tool_calls` for upstream `"call"` entries,
     classifies their `{server, tool}`, continues for reads, and stops before the
     next LLM turn after any `:write` or `:unknown` call;
   - the default guard builder lives in
     `PtcRunner.Upstream.SideEffectGuard.default(runtime)`, so
     `run_subagent/3` only closes over `runtime` and installs the returned
     closure;
   - on stop, it returns `{:stop, {:error, step}}` where `step.fail.reason` is the
     core atom `:partial_side_effects`; it builds the failure with
     `Step.error(:partial_side_effects, message, next_state.memory,
     %{matched_calls: sanitized_calls})` and then
     `StepAssembler.finalize/3` using `turn_offset: -1` and `is_error: true`.
     `sanitized_calls` contains only `server`, `tool`, and `effect`; it never
     includes upstream args, results, or raw tool-call maps. A malformed `"call"`
     entry with missing `server` or `tool` is `:unknown` and stops fail-closed;
   - it does not drain `RunContext`, does not thread `:turn` into `RunContext`,
     does not compute `:args_hash`, and does not add `Step.upstream_calls`.

   This delivered the Phase-3 "safe by default" target for cooperative multi-turn
   bridge runs while preserving the existing host override surface. Word the
   guarantee narrowly: after an **observed completed turn** contains a
   write/unknown upstream call, core issues no further LLM turn. It does not
   prevent the first side effect, same-turn `pmap` fan-out, terminal-turn side
   effects, single-shot-path side effects, or dispatches lost to timeout/raise
   before a turn is produced. Pin tests on stable observables: `length(step.turns)`
   includes the observed side-effecting turn after a turn-boundary stop; do not
   assert directly on derived `usage.turns` counters.

4. **Phase 3b (optional audit-completeness ledger):** only if the in-flight
   timeout/transport-raise holes matter enough, add a provider-neutral
   pre-dispatch attempt record in core. Record on the `:proceed` arm immediately
   before `Runtime.call_tool`, include `server`, `tool`, `effect`, status, and
   any minimal correlation data a real consumer needs. Do **not** pull in
   `:args_hash` or `Step.upstream_calls` preemptively. Retire or replace the MCP
   `root_tools_with_ledger` / `call_with_ledger` decorator in the same migration
   so core, MCP, and `Turn.tool_calls` do not double- or triple-count attempts.
   Watch the drain contract: `Collector.drain` is **destructive** and resets to
   `[]` (`collector.ex:55-57`), and `run_subagent/3` drains exactly once at run
   end to return `{result, records}` (`eval.ex:38-41`). If a 3b guard drains
   per-turn for "records since last turn," it must re-accumulate into the
   bridge's returned `records` or that public contract silently becomes `[]`.
   (Phase 3a is immune — it reads the completed `Turn`, never drains.)

   <a id="phase-3b-decision-2026-06-09--defer"></a>
   #### Phase 3b decision (2026-06-09): **DEFER**

   A design investigation (5 parallel source audits + adversarial verification)
   confirms 3b is, today, **MCP-ledger-retirement only** — there is no
   correctness reason to build a core attempt-record surface yet. Build nothing
   in core until a trigger below fires.

   **Why defer (source-verified):**

   - **No consumer.** The only non-test caller of `Eval.run_subagent/3` is
     `mcp_server/.../agentic.ex:174`, and it **discards** the bridge records
     (`{result, _records}`), using its own ledger instead. `ptc_viewer` (a disk
     JSONL reader) and `demo` consume zero upstream records. The core
     `{result, records}` surface is exercised only by core tests asserting
     `RunContext`-native fields — never `effect`/`turn`/`args_hash`. The total
     absence of any record consumer is itself the decisive defer signal.
   - **The ledger works and is test-locked.** MCP closes the holes server-side
     via **pre-dispatch** `record_attempt` (`ledger.ex:60-78`) +
     `call_with_ledger`'s rescue/reraise (`agentic.ex:205-217`); the in-flight
     block is locked by `agentic_contract_test.exs:75` (`{:attempted_during_dispatch,
     true}`). No TODO/known-bug/audit-hole marker near `ledger.ex`.
   - **The holes are real but bite nobody.** `CallTool.dispatch` records
     POST-dispatch only (`call_tool.ex:151/165`, after `Runtime.call_tool`
     returns). So an upstream write can side-effect and then be lost: **H1** a
     raise in the post-`{:ok,value}` helpers (realistically only
     `Runtime.scrub`, a `GenServer.call` that `:exit`s if the Runtime died)
     unwinds past `RunContext.record`; **H2** a sandbox timeout / heap kill —
     an **untrappable** `Process.exit(pid, :kill)` (`sandbox.ex`) — destroys the
     worker mid-dispatch before the record message reaches the (separate-process)
     Collector. H3 is not a third hole — it is the shared window H1/H2 exploit.
     Worse, on a raise *through* the bridge, `with_run_context`'s `after
     RunContext.close` runs `Collector.stop` (**destroy, no drain**) and
     re-raises (`eval.ex:42-44`, `collector.ex:39-45`), losing *all* records.
     The upstream-side **call timeout is NOT a hole** — transports catch `:exit`
     and return `{:error, :timeout, _}`, which `dispatch` records via
     `error_entry`. These holes only bite a standalone (non-MCP) consumer that
     reads `run_subagent/3`'s records as an audit trail — none exists; MCP plugs
     all of them. The H2 fix is structural (a write into a separate process
     before dispatch), which is exactly why MCP's separate-process ledger closes
     it and a future core pre-dispatch record would too.
   - **Building now adds cost for a hypothetical.** The minimal correct design
     re-introduces the guard↔record coupling Phase 3a deliberately removed, needs
     a non-destructive attempt reader the append-only Collector lacks, and
     **still** would not close the raise-through-bridge hole without an extra
     drain-in-`after`.

   **Trigger to implement (any one):**

   1. a committed **non-MCP consumer** of `run_subagent/3` (or
      `run_lisp_with_records/3`) that reads `records` and needs
      killed-in-flight / raised writes audited;
   2. the **Phase-2 `SubAgent.run(runtime:)` facade** lands returning only
      `{:ok, step}` (records no longer reach callers via the tuple) — forces a
      `Step.upstream_calls` surface;
   3. **child/nested SubAgents** whose upstream calls must roll up to a parent
      that sees only the child `%Step{}`;
   4. a decision to **delete the MCP decorator** for maintenance reasons
      (e.g. to stop maintaining two effect classifiers). **Do not execute this
      trigger before migration Steps 1–2 below land**, or retiring the ledger
      *regresses* the in-flight-killed-write continuation block (a genuine,
      operator-config-reachable safety property — `retry_turns > 0` /
      `max_turns > 1` — that the pre-dispatch ledger provides and the Phase-3a
      `Turn`-reading guard does not).

   **When triggered — minimal record surface (do not pre-build):** core records
   gain only `"id"` (a `make_ref` correlation token) + `"effect"`
   (`Upstream.Effect.classify`, captured pre-dispatch on the `:proceed` arm so an
   interrupted write keeps its classification) + an `"attempted"` status value.
   Keep `args_hash` **OUT** (SHA-256 read by no consumer anywhere; if MCP wants
   byte parity, compute it in a thin MCP-side projection), `turn` **OUT** (it is
   the hardcoded literal `1` at `agentic.ex:223`, not a real signal — let the MCP
   projection stamp it), and `Step.upstream_calls` **OUT** (records already reach
   root via the tuple; a `%Step{}` field would be a second source of truth — the
   Q6 hazard). Use **fork (a)**: two correlated rows (`:attempted` + terminal),
   merged by a stateless end-of-run projection — the only design that keeps the
   single destructive drain (`collector.ex:55-57`) and the `{result, records}`
   contract without giving the append-only Collector an upsert. The MCP wire
   becomes a pure stateless projection over the drained core records.

   **When triggered — safe migration order (retire the ledger without
   double-counting or regression):**

   1. Add core pre-dispatch recording in `CallTool.dispatch` (write an
      `:attempted` row with `id`+`effect` *before* `Runtime.call_tool`; finalize
      to `:ok`/`:error` after; finalize to `:error` on raise via `try/rescue`)
      **plus** a non-destructive `RunContext` attempt reader. Lock with a core
      test that an attempt exists mid-dispatch and survives a transport raise.
      MCP unchanged, ledger still authoritative → **no double-count yet.**
   2. Add `SideEffectGuard.from_records/1` and default the bridge to it; lock the
      in-flight block at the guard level (mirror the `{:attempted_during_dispatch,
      true}` assertion). `put_new` at `eval.ex:130` lets MCP's explicit guard
      still win → no behaviour change.
   3. *(The only step that retires the ledger as a counting site — do
      atomically.)* Replace `continuation_guard(ledger)` with the core
      record-aware guard, and **re-source both** `side_effecting_attempted?` and
      `entries` from the drained core records in one change (`agentic.ex:475-477`
      reads both). Stop passing `on_upstream_call`; delete `call_with_ledger` /
      `root_tools_with_ledger`; move the `agentic_contract_test.exs:75` lock onto
      the core path.
   4. Pair fork (a) with **draining-in-`after`** (or a bridge catch-and-attach)
      so a raise-through-bridge still surfaces records; ship the outstanding §6
      raise-through-bridge fault test.
   5. Delete the `Ledger` module once unreferenced.

   Verify with `mix precommit` + the mcp `agentic_contract_test` + `codex review`
   at each step. The three counting/observation sites have **disjoint
   authority** — keep them so: `RunContext` call-cap atomics own *rate limiting*
   only; the (retiring) ledger owns *side-effect policy + wire projection*;
   Phase-3a's `Turn.tool_calls` guard stays *guard-only* and must never be
   projected to the audit surface (that would be a third count).

   **Caveat — byte-for-byte parity is asymmetric (correcting an over-strong
   reading).** Re-pointing the MCP `upstream_calls[]` (ledger-entries shape) onto
   core records is straightforward (only `effect`/`turn`/`args_hash` differ, all
   stampable). But the `upstream_results[]` `result_overview` (shape/preview) is
   built from the **raw** upstream value in the ledger (`agentic.ex:296-305`) and
   from the **scrubbed** value on the core path
   (`call_tool.ex:146-149` → `Runtime.scrub`). The raw value is discarded after
   dispatch and is not in the core record, so a thin adapter **cannot** reproduce
   today's raw-sourced preview bytes; a core-sourced projection would shift
   preview/shape from raw to `[REDACTED]`. Treat this as a deliberate decision,
   not a silent swap: the migration must **explicitly choose raw-vs-scrubbed
   preview semantics** (scrubbed is arguably the safer default) and lock it with a
   test on a *credentialed* runtime — none exists today, and whether the current
   raw-sourced preview is independently redacted at the MCP envelope/transport
   layer (the `PtcRunnerMcp.Credentials` ETS set) is itself unverified and must be
   confirmed before relying on either behaviour.

5. **Phase 3c (snapshot/capability convergence):** validate `requires` once at
   run-context open against a frozen-for-the-run snapshot, removing per-turn
   redundancy and §3.5 #2's live-catalog hazard. Keep the effect/guard primitives
   provider-neutral where practical: upstream is the first concrete provider,
   but the same concepts should be able to serve future local, sandbox, and
   SubAgent capability providers.

---

## 8. Why this is worth doing

- Restores the capability-prelude **fail-closed `requires` guarantee on the
  multi-turn path** (the path most production agents use) — and, via §3.5 #1, on
  the single-shot path too.
- Makes "multi-turn agent over MCP/HTTP upstreams" a **supported core
  capability** of `ptc_runner` standalone, independent of `mcp_server`.
- Lets `mcp_server` shrink toward its intended role (a stated direction in
  `root-upstream-runtime.md:36-44/69`): configure and expose `ptc_runner` as an
  MCP server, owning only *deployment* policy + protocol/UX (which upstreams,
  authorization, approval/denial, audit export). Phase 3a has moved generic
  classification and the default stop-after-observed-side-effect guard to core:
  standalone users are now safe by default for cooperative multi-turn bridge
  runs, while hosts can still replace the default with their own
  `continuation_guard`.
- Keeps the SubAgent loop's deliberate "just functions" decoupling intact: the
  only new coupling is a single, opaque `:runtime` handle passthrough behind a
  bridge, not lifecycle ownership woven through the loop.

---

## 9. Phase 1.5 — Implementation Checklist (do now, workflow-executable)

> **Status: T1–T5 delivered.** T1 (bridge → internal `Runner.run/2`, `Definition`-only),
> T2/T3 (Definition-contract + the now-superseded no-default-guard canary in
> `test/ptc_runner/upstream/eval_run_subagent_test.exs`), T4 (guide §5/§7 seam +
> side-effect-guard caveat), and T5 (this reconciliation) shipped together. The
> verification gate (precommit + mcp `agentic_contract_test.exs` + codex review)
> passed. The §6 raise-through-bridge fault test and the `:e2e` test stay
> **outstanding** — they are explicitly *not* closed by T2/T3.

**Scope.** Behaviour-preserving cleanups + honesty/test gaps the 2026-06-05
design review surfaced. **No architecture change.** The Phase-2 facade and the
optional Phase-3b record-surface work stay deferred; the Phase-3a default guard
is delivered. Each task is self-contained with an exact target, the change, and
an acceptance check, so it can be handed to a Claude workflow (suggested
decomposition at the end).

### Tasks

**T1 — Bridge re-enters the internal runner (code).**
- *File:* `lib/ptc_runner/upstream/eval.ex`.
- *Change:* in `run_subagent/3`, replace `PtcRunner.SubAgent.run(enriched,
  run_opts)` with `PtcRunner.SubAgent.Runner.run(enriched, run_opts)` (add the
  `Runner` + `Definition` aliases). Narrow `@spec run_subagent` agent arg from
  `struct()` to `PtcRunner.SubAgent.Definition.t()`; note `Definition`-only in the
  `@doc`. Add a one-line call-site comment: *internal runner, not the public facade
  — pre-empts facade↔bridge recursion when the Phase-2 `SubAgent.run(runtime:)`
  facade lands (§3.1); behaviour-preserving today since the `%Definition{}` clause
  of `SubAgent.run/2` is a pure forward to `Runner.run/2`.*
- *Why it's safe:* `enrich_agent` matches `%{tools: tools}`; only `%Definition{}`
  has a `:tools` field (`CompiledAgent` does not), so the bridge already only ever
  receives a `Definition`. The switch makes the typed contract match reality.
- *Accept:* `mix compile --warnings-as-errors`; `eval_run_subagent_test.exs` and
  the mcp_server `agentic_contract_test.exs` stay green.
- *Deps:* none. File-disjoint from T4 (parallel-safe).

**T2 — Definition-only contract test (test).**
- *File:* `test/ptc_runner/upstream/eval_run_subagent_test.exs`.
- *Change:* assert `run_subagent/3` runs a `%Definition{}` and **raises** a clear
  error for a non-Definition agent (e.g. a `%PtcRunner.SubAgent.CompiledAgent{}`
  or a bare string). Locks the contract T1 makes explicit.
- *Accept:* new test green.
- *Deps:* after T1. Shares the test file with T3 → one agent owns both.

**T3 — Standalone default side-effect guard (test, superseded by Phase 3a).**
- *File:* `test/ptc_runner/upstream/eval_run_subagent_test.exs`.
- *Change:* the old Phase-1.5 no-default canary has been flipped. A bridge run
  with no host guard now stops after write/unknown upstream calls, continues
  after read-classified calls, and still lets a host guard override the default.
- *Accept:* tests green; stop details are
  `%{matched_calls: [%{server, tool, effect}, ...]}` with no args/results.
- *Deps:* same test file as T2 (same owning agent).

**T4 — Guide honesty + the `run_subagent/3` seam (docs).**
- *File:* `docs/guides/capability-prelude.md`.
- *Change:* §7 names `Upstream.Eval.run_subagent/3` as the multi-turn
  SubAgent↔upstream seam (the analogue of `run_lisp/3`, the supported multi-turn
  entry today). §5/§7 now documents the delivered default side-effect guard:
  reads continue, write/unknown calls stop with `:partial_side_effects`, and
  hosts can pass `continuation_guard:` to replace the default.
- *Accept:* §7 names `run_subagent/3`; default guard behavior and host override
  are documented.
- *Deps:* none. File-disjoint from T1 (parallel-safe).

**T5 — Plan reconciliation (docs, last).**
- *File:* this plan.
- *Change:* flip the §0 / §3.1 / §6 / §7 markers for T1–T4 from *scheduled* to
  *delivered*; keep the §6 raise-through-bridge fault test and `:e2e` test as
  **outstanding** (they are NOT closed by T2/T3 — the canary pins behaviour, it
  does not exercise a raising path or a real LLM).
- *Deps:* after T1–T4 land and the verification gate is green.

### Verification gate (after T1–T4, before T5 / commit)

1. `mix precommit` — format, compile, credo, schema, spec, tests. Fix all
   failures.
2. `codex review` the diff as a hard quality gate (subagent-written code tends to
   need ~5–6 rounds; stop on the first clean round).
3. Commit directly to `main`. In this shared working dir, do isolated work in a
   git worktree and verify `git show --stat` before pushing; `git push` needs
   `--no-verify` (two unrelated mcp_stdio stdio flakes in this sandbox).

### Out of scope for Phase 1.5 (stay deferred)

- The `SubAgent.run(runtime:)` → bridge **facade** (Phase 2).
- A record-before-dispatch ledger remains optional Phase 3b work if audit
  completeness requires it. The core default `continuation_guard` / effect
  classification from Phase 3a is now delivered.
- The **raise-through-bridge** fault test and the **`:e2e`** test (still §6
  outstanding — track, don't fold into Phase 1.5).

### Suggested Claude workflow shape

- **Stage A (parallel):** `T1` (eval.ex code) ‖ `T4` (guide docs) — disjoint
  files, run concurrently; no worktree isolation needed.
- **Stage B (serial, after A):** one agent owns `eval_run_subagent_test.exs` and
  writes `T2` + `T3` together (single file → avoid a parallel-edit conflict).
- **Stage C (verify):** run `mix precommit`; on green, `codex review` the diff;
  loop fixes until a clean round.
- **Stage D (after green + clean):** `T5` plan reconciliation, then one commit
  (e.g. `feat(subagent): bridge → internal Runner.run; Definition-only;
  standalone-guard docs`) + push.
- Parallel agents that mutate overlapping files in a workflow need
  `isolation: 'worktree'`; here only the disjoint T1‖T4 run in parallel, so plain
  fan-out is fine.
