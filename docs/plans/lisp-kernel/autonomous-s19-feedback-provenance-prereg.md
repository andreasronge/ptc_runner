# Lisp Kernel - Autonomous S19 Feedback Provenance + Preregistration

**Status:** goal brief for the next autonomous Codex session on
`exp/lisp-kernel`. Written 2026-07-08 after the host-held memory spike.

Use this after
[`autonomous-m3-host-memory-spike.md`](autonomous-m3-host-memory-spike.md).
This session proves attribution and freezes the follow-on experiment design.
It must not run the feedback A/B.

## Short Goal Prompt

```text
Run the autonomous S19 Feedback Provenance + Preregistration spike described
in docs/plans/lisp-kernel/autonomous-s19-feedback-provenance-prereg.md.

Goal: prove feedback-only bundle provenance for kernel runs and write the
preregistration for the next feedback-policy A/B, with host-held memory
behavior fixed. Do not run the A/B. Feedback variants may only change
agent.feedback wording/rendering policy and must preserve
untrusted_eval_result.memory_summary.

Work risk-first: first prove a swapped agent.feedback variant can be
attributed by component source hash in sanitized events/report evidence sourced
from prelude.metadata via Prelude.trace_summary/1, then write the prereg. Keep
scope bounded: no D4 TurnEvent integration, no S12 owner hardening, no sessions,
no prompt policy changes, no cross-domain holdout implementation, no statistics
claims. Update docs with commands, evidence, blockers, and the frozen A/B
contract.
```

## Objective

The memory spike did what it was predicted to do: the new memory-persistence
case passed, while `domain_tool` stayed red as the scalar-extraction control
and `context_aggregation` still burned the turn limit. That sharpens the next
question without answering it. The remaining lever for aggregation is policy:
feedback wording first, prompt policy later if feedback-only misses.

S19 is the gate before M3. It answers two narrower questions:

1. Can a kernel run be attributed to a specific `agent.feedback` variant by
   `prelude.metadata.components` and component `source_hash`es in sanitized
   events/report evidence?
2. Is the feedback-only A/B fully registered before any outcome-bearing run,
   with prompt prelude, cases, `max_turns`, model, runner, and host-held memory
   behavior fixed?

The deliverable is provenance evidence plus a preregistration document, not an
A/B result.

## Scope

Read first:

- `AGENTS.md`
- `docs/plans/lisp-kernel/architecture.md` (D4, D5, D14, verified facts 15-16,
  and the memory-summary vocabulary facts)
- `docs/plans/lisp-kernel/roadmap.md` (S19 and M3)
- `docs/plans/lisp-kernel/spikes.md` (S19 candidate note)
- `docs/plans/lisp-kernel/autonomous-m3-host-memory-spike.md`
- `lib/ptc_runner/kernel.ex`, `lib/ptc_runner/kernel/eval.ex`
- `priv/preludes/agent/core.lisp`, `prompt.lisp`, and `feedback.lisp`
- `test/ptc_runner/kernel*` and `test/ptc_runner/kernel/`

Start from the landed host-memory fix commit, with the memory summary and native
memory path already green. If unrelated dirty state is present, stop and report
it before touching code or preregistration hashes.

Allowed:

- add or extend focused deterministic provenance tests;
- add minimal bounded sanitized events/report fields if current eval output
  cannot attribute a run to component hashes;
- create committed feedback variant fixtures or experiment files for provenance
  tests;
- create an experiment preregistration artifact, suggested path
  `docs/plans/lisp-kernel/experiments/s19-feedback-ab-prereg.md`;
- update roadmap/spike docs with evidence and the final prereg link.

Avoid:

- running the A/B, including descriptive `--runs` comparisons;
- changing `agent.prompt`, `agent.core`, cases, model behavior, max-turns
  policy, or host-held memory behavior;
- D4 TurnEvent integration, S12 owner-process hardening, sessions, compaction,
  MCP, or cross-domain holdout implementation;
- adding raw prompts, raw model responses, raw eval programs, or raw memory
  values to reports;
- claiming statistical superiority from repeated temperature-0 runs.

## Build Tasks

**Sequencing is risk-first.** Prove attribution before writing the prereg. If
the run cannot be tied to a feedback component hash through the existing
sanitized events/report path without D4 TurnEvent work, stop and record that
blocker instead of designing the A/B on weak evidence.

1. **Provenance audit**

   - Pin the load-bearing provenance path. The kernel does not emit canonical
     TurnEvents yet; D4 remains out of scope for S19. S19 attribution evidence
     means the sanitized events callback and/or eval-runner report, sourced from
     `prelude.metadata.components` as exposed by
     `PtcRunner.Lisp.Prelude.trace_summary/1`.
   - Inspect the current prelude compilation, events, and report paths. Confirm
     whether `PtcRunner.Kernel.compile_prelude/1`, `Kernel.run/2`, and
     `PtcRunner.Kernel.Eval` already expose:
     - component namespace;
     - component source hash;
     - component ordering/dependency metadata;
     - enough sanitized event/report context to associate those hashes with a
       concrete run.
   - Record the actual source-backed contract in `architecture.md` or
     `spikes.md`; do not rely on intent from the roadmap.
   - If sanitized events/report evidence lacks sufficient provenance, add the
     smallest bounded field needed: hashes and namespaces, never source. Run
     the roadmap's seam-and-value-shape checklist for any new field: bounded,
     redaction-tested, and pinned at both producer and consumer ends.

2. **Feedback-only variant proof**

   - Define two conforming `agent.feedback` variants in committed, stable
     sources under a fixture or experiment path. Hashes frozen in the prereg
     must be reproducible from byte-identical committed files, not from an
     ephemeral in-memory string.
   - Variant A should represent the current/default feedback wording.
   - Variant B may adjust only generic wording about bounded memory summaries
     and retry guidance. It must be domain-blind and must preserve the
     `untrusted_eval_result.memory_summary` envelope.
   - The prereg may also include one admissible secondary feedback-only cell:
     a recency-weighted memory-summary renderer that is verbose for last-turn
     definitions and names-only for older definitions. It is allowed only if it
     remains entirely inside `agent.feedback`, preserves the same envelope, and
     does not change prompt/core/host behavior.
   - Prove the variant swap changes only the feedback component source hash:
     `agent.core` and `agent.prompt` hashes must remain identical across the
     two compiled bundles.
   - Prove sanitized events/report evidence can attribute a run to A or B
     without raw prompt or prelude source leakage.

3. **Preregistration document**

   Create the preregistration after the provenance proof, not before. Include:

   - date, branch, repo commit, and whether the worktree was clean;
   - frozen suite, dataset seed/hash or dataset construction hash, and case
     list;
   - a cells table with exact feedback variant labels and frozen component
     source hashes;
   - committed variant source paths plus the full variant sources embedded
     verbatim in the prereg;
   - primary cell pair: kernel with feedback A vs kernel with feedback B;
   - fixed controls: prompt prelude, `agent.core`, cases, `max_turns`, model,
     runner command, dataset construction, host-held memory cap/order, and
     memory-summary boundary;
   - primary endpoint and case focus. Recommended: `context_aggregation`
     pass/fail is primary; `memory_persistence` must remain green in both
     cells; `domain_tool` is a scalar-extraction ownership control expected not
     to move under feedback-only changes;
   - metrics plan. For a true M3 run, metrics must come from canonical turn
     logs once D4 exists: correctness, turns, tool calls, repeated reads by
     `args_hash`, tokens, and trace/write-error counts. If D4 is still absent,
     the prereg must label the follow-on run as a non-M3 descriptive shakedown
     using the current sanitized events/report path;
   - stratified reporting plan: at minimum by case, task family, turn-count
     band, tool shape, oracle strength, and data-visibility mode when those
     labels exist;
   - correction policy for secondary metrics and secondary cells;
   - run count. If N is only a descriptive shakedown, say so explicitly and
     label the follow-on run as non-M3 evidence that cannot support the M3
     verdict. If it is conclusion-bearing, include the full Tier-3 required
     field set from `roadmap.md`, including minimum detectable effect, alpha,
     power, and computed N;
   - blocked randomized order by `{case_id, replicate}` when multiple repeats
     are planned;
   - retry, exclusion, stopping, and rerun rules;
   - exact command or command template for the later A/B run;
   - outcome section stub that says "not run in this session";
   - claim boundaries: directional evidence only unless the prereg supplies a
     real inferential plan.

4. **Documentation updates**

   - Link the new preregistration from `roadmap.md` S19/M3 once it exists.
   - Record S19 evidence in `spikes.md`: provenance pass/fail, commands, and
     whether any code change was needed.
   - If any provenance/report shape changes, record the new stable contract in
     `architecture.md`.
   - Keep the docs honest if the work stops at a blocker.

5. **Verification**

   Minimum deterministic checks:

   - focused ExUnit provenance tests for feedback-only source-hash attribution
     through sanitized events/report evidence;
   - focused event/report redaction tests if evidence fields changed;
   - `mix ptc.kernel_eval --suite mini` in mock mode if the eval report changed;
   - `mix precommit` before any commit;
   - independent `codex review` until clean before declaring the brief ready.

   The variant-swap proof is deterministic/mock-only. Do not run a live A/B.
   A single live smoke is allowed only if events/report plumbing changed; it
   must use one bundle only, one non-comparative case, and must not report
   variant-vs-variant outcomes.

## Deliverables

- S19 provenance evidence, including commands and pass/fail status.
- A preregistration doc for the later feedback-only A/B.
- Roadmap/spike links to the prereg and evidence.
- Tests for any code/report shape changes.
- Independent review notes or a clean review verdict.
- No A/B outcome table.

## Stop Conditions

Stop and report the blocker if any of these occur:

- sanitized events/report evidence cannot attribute a run to a feedback
  component hash;
- attribution requires D4 TurnEvent integration or broad introspection work
  outside S19;
- the feedback variants need `agent.prompt`, `agent.core`, case, runner, model,
  or host-memory changes;
- preserving `untrusted_eval_result.memory_summary` becomes ambiguous;
- the work starts producing outcome-bearing A/B data instead of preregistration.

## Non-Goals

- Run the S19/M3 feedback A/B.
- Harden host-held state handles or concurrent access semantics.
- Implement cross-domain holdout cases.
- Make a statistical claim.
- Change the live model, demo cases, max-turns policy, or memory behavior.
