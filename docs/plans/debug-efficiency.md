# Bounded debugging-efficiency comparison

Status: proposed, 2026-09-21. Protocol decision #2028; documentation closeout
#2027. No live experiment is authorized. The retained
[debug-efficiency program](../research/debug-efficiency.md) owns hypotheses,
evaluation rules, limits and backlog. This plan only stages the next decision.

## Outcome

Choose whether Jev-assisted evidence selection is worth pursuing for a
read-only PtcRunner debugging assistant. Compare end-to-end time and cost at
comparable diagnosis quality and coverage against simple baselines.

## Sequence and gates

1. **Corpus feasibility.** Inventory roughly 30–50 distinct candidate incidents
   with independent causes/evidence and explicit unanswerable cases. Group
   splits by application or failure family. Assess #2021's missing diagnostics
   before treating any affected case as answerable. Proposed cap: two
   engineering days for feasibility and minimal setup, then stop/review.
2. **Freeze the protocol in #2028.** Name the exact corpus, alternatives,
   model versions, evidence surface, output contract, quality/coverage
   tolerances, useful cost/latency gains, uncertainty method, engineering and
   spend caps, per-case limits, retry and failure policies. File the approved
   experiment separately; neither this plan nor the program grants spend.
3. **Run the bounded comparison.** Use the initial alternatives in the program.
   Develop on one set and evaluate frozen finalists on an untouched set.
   Record all requests, costs, failures, selected evidence and live duration_ms.
   Verify orchestration by replay; never substitute replay time for live speed.
4. **Make a disposition.** Keep the simplest useful approach, stop an
   unpromising line, or propose one targeted follow-up. A small inconclusive
   sample does not automatically authorize more runs or infrastructure.

## Scope control

The first comparison excludes patch application, debugger self-repair,
recursive investigation, generated subqueries and dynamic feedback generation.
Later alternatives must target a measured bottleneck and retain the fixed
baseline and independent scorer. Consider generating questions offline and
freezing them before adding generation to every incident's critical path.

Runtime capture fixes remain ordinary work. Full Jev product integration and
a research manager are unnecessary for the first valid measurement. Track
engineering effort alongside provider cost so cheap inference cannot conceal
an expensive implementation detour.

## Historical disposition

The original prelude-search implementation ladder is retired. Its harness
and reports remain; the [program](../research/prelude-search.md) records
002–004 and leaves H1–H3 open while repair research is paused. #2010 and #2022
publish reports, #2009/#2024 retain artifacts without merging, and #2020
supersedes #2019. Historical reports and tagged artifacts are unchanged.

Delete this staging plan when #2028's protocol decision is completed; the
retained program and experiment issue then own any approved work.
