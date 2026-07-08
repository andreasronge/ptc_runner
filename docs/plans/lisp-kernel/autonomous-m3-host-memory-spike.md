# Lisp Kernel — Autonomous M3 Host-Held Memory Spike

**Status:** goal brief for the next autonomous Codex session on
`exp/lisp-kernel`. Written 2026-07-08 after the M2 review. This spike was
deliberately reordered ahead of both logging/introspection and the S19
feedback A/B: the live red cases are confounded by statelessness, so policy
experiments on a memoryless loop would need re-running afterwards anyway.

Use this after the M2 prelude split. The `/goal` prompt should stay short and
point here; this document carries the detailed contract.

## Short Goal Prompt

```text
Run the autonomous M3 Host-Held Memory spike described in
docs/plans/lisp-kernel/autonomous-m3-host-memory-spike.md.

Goal: give kernel inner evals persistent PTC-Lisp memory across turns,
held by the host and never threaded through the prelude as a raw value.
Return a bounded memory_summary to the loop, render it in retry feedback,
cap memory bytes fail-closed, and measure whether persistence changes the
live red cases.

Work risk-first: prove def/defn round-trip through host-held memory first.
Commit after each coherent batch. Keep scope bounded: no owner-process
hardening (S12), no logging/introspection, no S19 A/B run, no sessions.
Update docs with evidence, blockers, commands, and live results.
```

## Objective

M2 proved policy lives in swappable preludes and gave the kernel an honest
eval harness. The strict-oracle live run is 3/5; both red cases share a
plausible root cause: every inner eval starts from `%{}`, so the model cannot
build state incrementally across retries.

This spike tests the next thesis:

> The kernel can preserve useful PTC-Lisp state across turns through
> host-held memory — without copying raw memory through the prelude — at a
> copy/heap cost the strict inner sandbox can afford.

This is the D1 question in its kernel-sized form, and it resolves registered
spike S2 (memory round-trip through the tool boundary) for the kernel path.
Record results under S2 and as D1 evidence; do **not** mint a new spike ID
without checking the registry (S20 is the next free number at time of
writing).

## Scope

Read first:

- `AGENTS.md`
- `docs/plans/lisp-kernel/architecture.md` (Capability Model, D1, D5)
- `docs/plans/lisp-kernel/roadmap.md`
- `docs/plans/lisp-kernel/spikes.md` (S2, S5, S12, S18, S19)
- `lib/ptc_runner/kernel.ex`, `lib/ptc_runner/kernel/eval.ex`
- `priv/preludes/agent/*.lisp`
- `test/ptc_runner/kernel*` and `test/ptc_runner/kernel/`

Substrate facts, verified 2026-07-08: `Lisp.run/2` already accepts a
`:memory` option and returns `step.memory`; a fail-closed `:memory_exceeded`
error exists. The spike wires shipped mechanism, it does not extend the
language runtime.

Allowed:

- add host-held memory state to `PtcRunner.Kernel.run/2` and the
  `eval-program` capability;
- extend the eval-program projection with a bounded `memory_summary`;
- update `agent.feedback/eval-feedback` (and, only if needed,
  `agent.prompt`) to render the summary;
- add a memory-persistence case to the mini eval suite;
- update docs with facts, evidence, and spike results.

Avoid:

- the S12 owner-process hardening (monitors, stale tokens, run-end
  invalidation, concurrent `pmap` access) — an `Agent` started in
  `Kernel.run/2` and stopped in an `after` block is the whole lifecycle for
  this spike;
- logging/introspection work beyond what the summary itself requires;
- running the S19 feedback A/B;
- cross-run persistence — memory is per-`Kernel.run` mission state only;
- sessions, compaction, MCP, Tier 2, self-improvement.

## Build Tasks

**Sequencing (risk-first).** Task 1's def/defn round-trip proof comes first —
if closures cannot survive the host boundary at acceptable cost, everything
else is moot and the spike stops with evidence. Then the summary (task 2),
feedback rendering (task 3), suite coverage (task 4), and the live probe
(task 5). Commit after each coherent batch — code together with its tests and
doc updates. If unrelated dirty state appears in the worktree, stop and
report it before touching anything.

1. **Host-held memory in `Kernel.run/2`**

   - Memory starts as `%{}` per run, held host-side (an `Agent` created in
     `run/2`, stopped in an `after` block). It is never passed into the
     outer run's context and never becomes a value the prelude holds —
     `agent.core` sees only summaries.
   - Each `eval-program` call reads current memory, runs the inner
     `Lisp.run/2` with `memory:`, and commits `step.memory` back.
   - **Failure semantics — decide and pin.** Recommended: REPL semantics —
     commit whatever memory the inner run returns, even when the program
     fails or errors, so definitions made before a failure survive the
     retry. Whichever way it goes, a `def`-then-`fail` test documents it.
   - **Byte cap, fail-closed.** Add a per-run memory byte cap (suggested
     1–2 MB for the spike) with a stable error reason
     (e.g. `memory_limit_exceeded`), surfaced to the loop like other eval
     errors — never a silent truncation or an ergonomic fallback. Heap
     arithmetic to respect: sandbox memory costs ~1.7× amplification and
     the inner eval has 10 MB total, so uncapped memory silently eats the
     model program's own headroom.
   - Log the memory byte size per eval through `tool/log` — this doubles as
     S5 copy-volume evidence.

2. **Bounded `memory_summary` in the eval projection**

   Extend the `eval-program` result map with a `memory_summary` containing
   only:

   - defined names (sorted);
   - names changed by this eval;
   - per name: kind (`value` | `function`) and a small preview;
   - an explicit omitted/too-large marker when a preview or the summary
     itself is truncated.

   Raw memory values never appear in the projection, the trace, or the
   events stream. Bound every list and preview; growing D5's projection
   shape beyond demonstrated need is out of scope.

3. **Feedback renders the summary**

   Update `agent.feedback/eval-feedback` so retry feedback tells the model
   which definitions are now available, inside the existing
   `untrusted_eval_result` envelope, without dumping values. Keep wording
   domain-blind and generic ("these names are defined"), never case-shaped
   hints.

   **Policy-interface note.** `eval-feedback [result cfg]` keeps its arity,
   but `result` grows the `memory_summary` key that conforming variants are
   expected to render. Update the policy-interface section of the M2 brief's
   contract in `architecture.md`/`roadmap.md` where recorded, and amend the
   S19 preregistration so A/B variants are written against the new result
   shape rather than a stale contract.

4. **Tests (deterministic, mock)**

   - turn 1 `(def x 41)` without return; turn 2 `(return (+ x 1))` → 42;
   - `defn` persists: turn 1 defines `(defn inc2 [n] (+ n 2))`, turn 2
     calls it — the closure round-trip is the S2 core;
   - `def`-then-`fail`: pins the chosen failure semantics;
   - a large definition is summarized/truncated in `memory_summary`, never
     echoed in full;
   - byte cap exceeded → stable `memory_limit_exceeded`-style error, run
     fails closed;
   - model programs still cannot call private kernel tools from the inner
     eval (re-pin with memory active);
   - raw memory values are absent from sanitized traces and eval-runner
     reports — extend the existing redaction test.

   Add a sixth mini-suite case (e.g. `memory_persistence`: def in turn 1,
   use in turn 2, exact-value oracle) so the harness covers persistence
   permanently, in mock and live modes.

5. **Live payoff probe**

   Run only if `OPENROUTER_API_KEY` is available, on the blessed DeepSeek
   model, with `--allow-failures`:

   - re-run the full live mini suite; record the oracle-checked table;
   - watch `context_aggregation` specifically: does persistence turn the
     5-turn burn into convergence? Record turns/evals before vs after;
   - record the new `memory_persistence` case live.

   Record results honestly either way — "memory did not move the red cases"
   is a valid, useful outcome that sharpens S19's scope. Retry-behavior
   cases need `max_turns` headroom (4–6), not the default 3.

## Verification

Run, in order:

1. existing focused kernel tests;
2. new memory tests;
3. mini eval suite in mock mode (now 6 cases);
4. `mix format`;
5. live DeepSeek mini run, if `OPENROUTER_API_KEY` is present;
6. `mix precommit`;
7. `codex review` over the session's commits as the final gate — fix or
   explicitly defer each finding in the final report.

## Deliverables

- Host-held memory threading in `Kernel.run/2` with byte cap and pinned
  failure semantics.
- Bounded `memory_summary` in the eval projection; feedback prelude renders
  it inside the untrusted envelope.
- Mock test coverage per task 4, including the redaction extension.
- A sixth mini-suite case covering persistence.
- Live before/after evidence for the red cases, or an explicit blocked note.
- Updated docs:
  - `spikes.md` S2 result (kernel path) and S5 copy-volume data points;
  - `architecture.md` D1 evidence and D5 projection-shape note;
  - `roadmap.md` progress and the S19 preregistration amendment;
- Final report: what changed, commands run, mock results, live results,
  copy-volume observations, and whether D1 should resolve toward host-held
  memory.

## Stop Conditions

Stop and document evidence if:

- def/defn closures cannot round-trip through host-held memory with shipped
  mechanism;
- memory threading weakens inner-eval isolation in any observable way
  (private-tool reachability, prelude access to raw memory);
- copy volume or heap amplification makes the strict 10 MB inner eval
  unusable at realistic memory sizes;
- the byte cap cannot fail closed with a stable error;
- the summary cannot stay bounded without becoming useless to the model;
- the work starts growing into S12 owner-process hardening or
  logging/introspection.

## Non-Goals

- S12 host-held state handle hardening (owner process, monitors, stale
  tokens, concurrency).
- Logging/introspection features beyond the bounded summary.
- Running the S19 feedback-policy A/B (it runs after this, against the
  amended contract).
- Cross-run or cross-mission persistence.
- Sessions, compaction, MCP, compiled agents, Tier 2, self-improvement.
- Statistical claims of any kind from the live probe.

## Why Before Logging and the A/B

Two dependencies point the same direction. Logging/introspection becomes
materially more valuable once there are memory summaries and diffs to
report. And the S19 A/B compares feedback policies on retry behavior —
which this spike changes; running it first would produce results that need
re-running. If memory fixes a red case outright, S19 narrows to the cases
memory did not fix, which is a better experiment.
