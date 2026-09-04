# Handover: debug-a-failed-run revisit

Paste this into a fresh session that continues the work. Dates are absolute.

## Where things are

- Branch `revisit/debug-repair-examples`, worktree `ptc_runner-revisit-debug-repair-examples`,
  merged with `origin/main` at `4f969c896` on 2026-09-04. It adds only
  `scripts/labs/debug-nav-bench/`: `README.md` (the study), the bench harness, the
  `debug.terminal.clj` component, a deterministic probe, and the decision files of three
  measurement rounds. The example and the runtime are untouched on this branch.
- Runtime fixes that landed on main from this work, all closed on 2026-09-04: #1809
  (`21222394d`, nested observations render complete when they fit), #1810 (`b41ffa55f`, a
  private run at an event ceiling ends as `event_capture_limit_exceeded` and keeps its
  artifacts; the 256-event default still applies to private runs), #1800 (`73472f90e`,
  analysis-profile argument errors name what is wrong). Still open: #1783 (REPL-side preview
  stubbing), and the adjacent #1509 and #1787.
- Verified on merged main after the fixes: the shipped `debugger-agent` at 14 turns completes
  in 11 and 12 turns for about $0.002 and names `pricing.rule`; a 20-turn navigation run at
  the default event ceiling completes with trace, inspection and result written.

## What the study established

- The three repair arms are correct on the first try with one model call each. Promotion works
  through the stable CLI with `ptc materialize ... --from-result RESULT --result-pointer
  /candidate_source` followed by `ptc run ... --component-override-descriptor`, and
  `mix ptc.repair` runs the shipped suites 3 of 3 green. The example README knows neither.
- Prescribed traversal order plus DeepSeek v4 Flash measured 9 of 9 across the three failure
  shapes, including abstaining on the ambiguous target and finding the workflow-routing defect
  outside the dependency closure by reading the workflow prelude on its own.
- Luna under the shipped prompt was 2 of 9: it explains the arithmetic on the ambiguous target
  and still calls it a diagnosis, and it obeys the prompt's stopping rule at the dependency
  leaves. With verdict definitions, a decision-based stopping rule, the environment sentence,
  and the two terminal actions it was 6 of 6. DeepSeek without a prescribed order wanders and
  overflows the 4096-token output ceiling on the ambiguous target.
- The terminal actions are domain-blind: `diagnose` demands the frozen source hash and a
  verbatim excerpt, `abstain` refutes missing evidence the capture holds. No round-3 run named
  a wrong component. Two excerpt refusals were whitespace, and the abstain refusal wording
  should allow "read, but its contract is undetermined".
- The report schema accepts `diagnosed` with no `component_id`; one Luna run used that shape.

## The example refresh, in order

1. README: rewrite promotion around `ptc materialize --from-result`; document `mix ptc.repair`
   and the suites as checkout-only or delete the suites; break the circular pointer with
   `ptc docs debugging-a-failed-run`; mention `ptc transcript` and `ptc run --progress`.
2. `debugger-agent`: keep the prescribed order and DeepSeek. Select `debug.terminal` into the
   evidence mission (copy from the lab, collapse whitespace in the excerpt check first), add
   the verdict definitions and the environment sentence to the task, require `component_id`
   when the decision is `diagnosed`, and consider `max_turns` 20 for headroom. Add
   `-ambiguous` and `-workflow-control` project files for the debugger-agent; the host
   documents already exist.
3. Replace "a verified live run" in the example README and in the "What to expect" section of
   `docs/reference/debug-navigation.md` with measured rates from a fresh bench run, at least
   three samples per target, using `scripts/labs/debug-nav-bench/run.sh`.
4. Tests: extend `test/ptc_runner/kernel/debug_a_failed_run_example_test.exs` with a
   deterministic terminal-action case modelled on `probe.sh` (fabricated reports, refused and
   accepted), and update the schema case. Nothing needs a model.
5. The example tree is embedded by `ptc init --example`; run `mix ptc.gen_docs` if anything
   generated changes, then `mix precommit`, then an ordinary push so the hooks run. Follow the
   coding-agent review workflow before the PR.

## Possible future improvements

- A host-supplied `debug.nav/open` result in the initial task, the way the repair arm builds its
  packet before turn one; saves two or three turns per run.
- Measure the third prompt together with the prescribed order for DeepSeek; only the
  order-free form was measured with it.
- Decide whether `model_output_truncated` should cost a turn rather than the run for agent
  loops, or set `limits.llm_request_output_tokens` above the 4096 application default in
  agent manifests; the host's `params.max_tokens` alone does not raise it.
- A hybrid arm where the host walk covers the standard shape and the model must notice a
  clean closure and navigate beyond it; the workflow-routing target is the test case.
- A fourth failure topology, more samples, and a third model for the bench.
- `ptc repair` in the stable CLI so release users can run the held-out suites.
- #1783 for the REPL side of the preview renderer.

## Gotchas

- Never edit in the shared checkout; use the worktree. Never push a real PR with `--no-verify`.
- The bench expects a materialized example whose three targets have been run; a promotion rerun
  leaves a passing run beside the failed one, which both models handled.
- `ptc repl` has no `--envelope`; `--continue-on-error` needs two or more `-e`;
  `analysis/counters` takes `{"run_id" ...}`; pass `--run RID` on large capture directories.
- Analyze artifacts through `ptc repl --profile private-run-analysis-v2 --private-unattended`,
  never with ad-hoc parsers. `turns.sh` and `score-cell.sh` in the lab wrap the queries.
- Whole 36-run matrix costs about a quarter of a dollar; keep at most six runs in parallel.
