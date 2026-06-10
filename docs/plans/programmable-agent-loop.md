# Programmable Agent Loop — Discussion Notes

**Status:** exploratory discussion notes, not a plan or requirements document.
Companion to
[`ptc-lisp-conversation-control-plane.md`](ptc-lisp-conversation-control-plane.md)
(runtime control surface) and
[`capability-prelude-discovery.md`](capability-prelude-discovery.md)
(authority model). This doc explores a third axis: making the **SubAgent loop's
policy layer** programmable from preludes, so humans — and eventually LLMs
through a gated workflow — can adapt prompt rendering, feedback, compaction,
context projection, and plan/progress vocabulary per domain without forking the
loop.

## Why This Exists

Two observations from working with the current system:

1. **Loop policy is closed.** `SubAgent.Loop` hardcodes the things a domain
   most wants to tune: turn feedback construction
   (`lib/ptc_runner/sub_agent/loop/turn_feedback.ex`), mission-log injection
   (`loop.ex`, `maybe_inject_mission_log_in_messages`), compaction strategy
   (`compaction.ex` — Phase 1 ships only `:trim`; custom strategies are
   explicitly deferred), and context projection (`filter_context` /
   `Exposure`). The journal capability (`(task ...)` / `(step-done ...)`)
   bakes one progress vocabulary into the prompt cards for every domain.
2. **Program persistence across turns already exists; hooks do not.** A
   `defn` from turn N survives in `user_ns` to turn N+1, and preludes provide
   human-curated function libraries. The LLM can already build and reuse
   programs; what it cannot do — and what humans cannot do per-domain without
   Elixir changes — is influence the loop *around* the programs.

The hypothesis: a small set of host-defined hook points, implementable as pure
PTC-Lisp functions in a prelude, is the right core abstraction. The analogy is
Emacs — a small core, with most of what feels like "the editor" implemented in
the extension language, inspectable and replaceable. ptc_runner has the piece
Emacs never had: a sandbox. Hooks can run under the same 1s/10MB discipline as
user programs.

## Guiding Principle: Failure Path vs Optimization Path

The boundary rule for what may become a hook:

> Anything on the **failure-recovery path** stays host-owned. Anything on the
> **optimization path** can be prelude-owned.

Rationale: hooks run policy, and policy is a luxury that assumes things are
going well. Compaction triggers exactly when context is overflowing — the
worst moment to depend on model- or prelude-authored scaffolding. So:

- **Host-owned, never hooks:** sandbox limits, budgets, the capability
  boundary and grants, effect classification, side-effect/continuation guards,
  the compaction *trigger and floor* (it WILL fire at the threshold; the
  result WILL fit), exactly-once mechanics (see
  [`upstream-runtime-roadmap.md` §4](upstream-runtime-roadmap.md#4-mcp-ledger-boundary)
  — a core pre-dispatch attempt ledger is *mechanism*, and a loop-policy
  consumer of records would be a Phase 3b trigger).
- **Prelude-ownable policy:** prompt section rendering, feedback phrasing and
  detail level, what compaction summarizes or pins, context
  sampling/projection, plan/progress vocabulary, domain verification
  predicates, orchestration patterns.

A second consequence of the same principle: **every hook has a host-owned
fallback.** A hook that crashes, times out, or returns malformed data is
recorded as a hook failure and the built-in behavior takes over — supervision
thinking applied to policy. The mission must never die because a renderer was
clever.

## The Hook Model

Hooks are **pure functions over loop state, returning data** — never
performing effects. Purity is the load-bearing constraint: it makes hooks
sandboxable (run with `tools: %{}`, no `discovery_exec`), traceable,
replayable, and benchmarkable, and it keeps them out of every exactly-once
question.

Candidate V1 hook points (names non-binding):

```clojure
(ns mydomain.loop-policy
  {:visibility :hidden})

(defn render-feedback
  "Turn a failed turn into LLM feedback text."
  [fail state]
  (str "Program failed: " (:reason fail)
       ". Available helpers: " (:helper-names state)))

(defn project-context
  "Choose what the LLM sees of a large context."
  [ctx mission]
  {:keys (keys ctx)
   :samples (sample-relevant ctx mission)})

(defn compact
  "Domain-aware compaction: what to pin, what to drop."
  [state budget]
  {:pin [:plan :open-questions]
   :drop-before (- (:turn state) 3)})

(defn on-turn-end
  "Annotate or steer after each turn. Returns directives, not effects."
  [state turn]
  {:annotations {:progress (summarize-progress state)}})
```

Hook contracts the host enforces:

- **Input:** a bounded, redacted projection of loop state (never raw
  credentials, never unscrubbed upstream payloads). Designing this projection
  is most of the work; it should reuse the descriptor/trace-safety rules from
  [`capability-prelude-discovery.md`](capability-prelude-discovery.md).
- **Output:** data validated against a per-hook schema (`PtcRunner.Schema`
  exists). Malformed output ⇒ fallback, recorded.
- **Execution:** one sandboxed eval per hook call, no tools, no discovery,
  tight timeout (likely well under the 1s default). BEAM process spawn cost
  makes this affordable per turn.
- **Rendering safety:** any hook-produced text that reaches the prompt goes
  through `PtcRunner.SubAgent.UntrustedRenderer` envelopes, same as tool
  output. A hook is *policy*, but its output is still model-visible text and
  must not become an injection channel.
- **Attribution:** hook identity and failures land in the trace
  (`Step.prelude_trace` is the existing precedent for prelude attribution).

## Feasibility Audit (what exists today)

Researched against the source; this direction is incremental, not greenfield.

| Hook point | Today | Gap |
| --- | --- | --- |
| Prompt rendering | `system_prompt` already accepts a **function** (`fn default -> modified end`), map (`:prefix`/`:suffix`/`:language_spec`/`:output_format`), or string; `:language_spec` accepts a callback (`system_prompt.ex` moduledoc). Prompt cards have byte budgets (`PromptRegistry`, `priv/prompts/README.md`). | Hooks are Elixir-only and whole-prompt; no Lisp-implementable, section-level surface. Prompt cards are a natural *output contract* for a `render-prompt` hook. |
| Turn feedback | Hardcoded in `SubAgent.Loop.TurnFeedback`. | No hook at all. Likely the highest-value first site: feedback phrasing is domain-sensitive and purely textual. |
| Compaction | `compaction:` config with `token_counter: fun/1` (Elixir hook); Phase 1 = `:trim` only; custom strategies + `:summarize` deferred to the Phase 2 stub ([`pressure-triggered-context-compaction-phase-2.md`](pressure-triggered-context-compaction-phase-2.md)). | Strategy is host-module-only. A `compact` hook supplies *what to pin/summarize*; the trigger and size floor stay host-owned per the principle above. Phase 2's open questions (summary watermark/cache, state plumbing) apply to the hook variant unchanged. |
| Context projection | `filter_context` (AST-driven dataset filtering), `Exposure`, `ctx`-style sampling ideas in the control-plane doc. | Projection policy is not programmable; a pure `project-context` hook fits the existing data flow. |
| Plan/progress | Journal capability: `(task ...)`, `(step-done ...)`, mission-log injection into prompts (`capability-journal.md`, `loop.ex`). | One global vocabulary; durability and authority issues are a separate *mechanism* discussion (ledger; roadmap §4). The prelude side here is only the *vocabulary* (`plan/*` verbs) and its rendering. |
| Invoking Lisp hooks from the host | Already possible with the public API: `Lisp.run/2` with the prelude attached, hook-call source, `memory:`, and `tools: %{}` is a pure, sandboxed hook invocation. `RuntimeCallable` shows the pattern for context-bound callables if a direct-apply API is wanted later. | No first-class `apply_export/4`-style host API; per-call sandbox spawn is the V1 cost. If `PtcRunner.Lisp.RunEnv` ships ([`capability-kernel-runtime.md`](capability-kernel-runtime.md)), hook invocation is a clean second consumer for it. |
| Stateful policy | Preludes are V1-stateless by design (guide §V1 scope); namespace-scoped `private_env` exists in the eval machinery. | Stateful hook policy needs the "stateful prelude wrappers" deferred item from `capability-prelude-discovery.md`; V1 hooks should be stateless (state lives in loop memory, passed in). |
| Attribution / debugging | `Step.prelude_trace`; trace/journal infrastructure; `ptc_viewer`. | Hook calls and fallbacks need their own trace records so a policy regression is attributable. |

Conclusion: nothing here requires new evaluator machinery. The V1 mechanism is
"the Loop calls named prelude exports via sandboxed eval at fixed points, with
schema-validated results and built-in fallbacks." The hard work is the state
projection contract and the discipline of keeping hooks few and coarse.

## Two Ways to Persist Programs Across Turns

Both already work and hooks compose with both:

1. **Prelude-resident programs** — human-curated, versioned, reviewed. The
   right home for policy hooks and domain helpers.
2. **Turn-N definitions used in turn N+1** — `defn` persists in `user_ns`.
   The right home for mission-scoped helpers the LLM derives on the fly.
   Combined with
   [`function-passing-between-subagents.md`](function-passing-between-subagents.md)
   (direct AST injection), these helpers also flow to child agents.

A regenerated program plus ledger-backed replay (mechanism side, roadmap §4)
makes re-running cheap; persistent definitions plus hooks make regeneration
*rarer*. They attack the same waste from two sides.

## Slow Loop vs Live Loop (how much control the LLM gets)

There is a real trend toward giving LLMs control over their own scaffolding.
The productive version of that trend is **slow-loop** self-modification —
visible in mainstream agent harnesses as skills/memory files edited *between*
runs and gated by review — not an agent rewriting its prompt renderer
mid-mission. Live self-modification destroys attribution: when a mission
fails, was it the task, the model, or the policy the model rewrote three turns
earlier?

Proposed split:

- **Live (mid-mission), allowed:** defining functions (already shipped);
  selecting among *pre-approved* policies, e.g.
  `(loop/set-feedback-style :terse)` where the host validates the choice
  against a granted set.
- **Slow loop, where real optimization happens:** missions produce traces →
  an LLM reads traces and proposes a prelude diff → the benchmark harness
  (`demo/`, the ablation/pass-rate infrastructure) A/Bs it against the
  incumbent → a human promotes. This makes "the LLM optimizes its own
  harness" a *measured* claim instead of an article of faith, and it is the
  LLM-authored-prelude proposal workflow already on the deferred list in
  `capability-prelude-discovery.md`, pointed at loop policy.

Hardcoded harnesses bake orchestration patterns into prose and fixed schemas
because general-purpose extension languages cannot be handed to a model with
capability bounds. A sandboxed Lisp is exactly the missing piece: an
orchestration prelude (`(verify-adversarially candidates {:judges 3})`,
map-reduce-with-inherited-helpers patterns over SubAgents) makes such patterns
first-class values — callable, inspectable via the control-plane introspection
forms, and evolvable through the slow loop.

## Risks

- **Hook soup / inner platform.** Many fine-grained hooks make the loop
  impossible to reason about. Counter: few, coarse hooks with data contracts;
  resist adding a hook until two domains need it.
- **Prompt injection via renderers.** Hook output is model-visible text
  derived partly from tool results. Counter: purity, bounded inputs,
  `UntrustedRenderer` envelopes on all hook-rendered content, and the
  LLM-authored path gated by approval.
- **Degraded-model failure.** Policy that must work when the model is
  failing (compaction floor, budget stops, guards) must not be hooked at all
  — this is the boundary principle, restated because it is the one most
  tempting to violate.
- **Attribution.** Without per-hook trace records and prelude identity in
  `Step`, policy regressions are undebuggable. Trace support is part of V1,
  not a follow-up.
- **Performance.** One sandbox eval per hook per turn is cheap on the BEAM
  but not free; hooks default to absent (zero cost) and the projection given
  to hooks must be bounded so copying stays small.

## Relationship to Other Plan Docs

- [`capability-prelude-discovery.md`](capability-prelude-discovery.md) —
  authority side. Hook installation is profile/host policy; hooks are curated
  exports with metadata (`:visibility :hidden`, future grants). The
  LLM-authored proposal workflow defined there is the slow loop's gate.
- [`capability-kernel-runtime.md`](capability-kernel-runtime.md) — a future
  `RunEnv` gains a second committed consumer here (hook invocation wants a
  typed, minimal eval-input surface).
- [`ptc-lisp-conversation-control-plane.md`](ptc-lisp-conversation-control-plane.md)
  — introspection: hooks should be discoverable (`doc`, `meta`, source
  inspection) like any export; historical traces are the slow loop's raw
  material.
- [`upstream-runtime-roadmap.md`](upstream-runtime-roadmap.md) §4 — the
  mechanism counterpart: exactly-once / attempt recording is host mechanism
  (a pre-dispatch ledger), never hook policy. A loop-policy consumer of
  bridge records would constitute a Phase 3b trigger.
- [`function-passing-between-subagents.md`](function-passing-between-subagents.md)
  — inherited closures + an orchestration prelude compose into reusable
  multi-agent patterns.
- [`future-directions.md`](future-directions.md) — idea backlog; its §1 call
  ledger is the concrete mechanism design this doc treats as host-owned, and
  its §5 skill promotion is the slow loop applied to domain helpers.

## Open Questions

- What is the minimal V1 hook set? (Current guess: `render-feedback` first —
  highest domain value, lowest risk — then `project-context`, then `compact`
  vocabulary, then `render-prompt` sections.)
- What exactly is in the loop-state projection passed to hooks, and what is
  its redaction contract?
- Are hooks named exports in a reserved namespace (e.g. `loop-policy/*`), or
  declared in prelude/profile metadata?
- Do hooks run in the *same* sandbox process as the turn's program eval (one
  spawn, sequenced) or separate per-hook spawns (isolation, simpler limits)?
- How do hook results appear in traces — full input/output capture, or
  bounded summaries with the same payload policy as tool calls?
- Should compaction Phase 2 (`:summarize`, custom strategies — see
  [`pressure-triggered-context-compaction-phase-2.md`](pressure-triggered-context-compaction-phase-2.md))
  be implemented as the `compact` hook directly, skipping a parallel
  Elixir-module strategy API?
- When child SubAgents run, do parent hooks apply to children, or must the
  child's prelude declare its own? (Likely: never inherit implicitly — same
  rule as capability profiles.)
