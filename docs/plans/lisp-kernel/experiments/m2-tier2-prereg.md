# M2 Tier 2 paired smoke preregistration

Date: 2026-07-10

## Purpose

Run the kernel and incumbent SubAgent through the same five-case deterministic
Tier 2 suite as an informal parity smoke. This is capability-gap detection, not
a comparative performance or architecture claim.

## Frozen inputs

- Suite: `tier2`
- Dataset seed: `17`
- Each Tier 2 case carries that seed, and `run_cases/2` rejects missing or
  mismatched case/report seed metadata or case context that differs from the
  canonical dataset slice constructed for that seed.
- Dataset identity: `503d8233cce08aa825a00e14d49c6e13d2a9db931fa219a8cc3500866e8a0953`.
  Each report must record this `dataset_hash`; equality between cells alone is
  insufficient.
- Case-definition identity:
  `4b448ecc370db8260cc8b4537bd7ed61ae9c8c0c0bbec80203d754d362df4431`.
  Each report must record this `case_definition_hash`; equality between cells
  alone is insufficient. This separately freezes task wording, case selection,
  oracle, tags, limits, context, and tool names. The full seed-17 suite fails
  preflight if either preregistered hash changes.
- Model alias: `deepseek`, resolved once by the paired coordinator and recorded
  by both child reports.
- LLM source must be `registry`; `provenance_eligible`,
  `preregistered_config`, and `evidence_eligible` must all be true.
  Eligibility additionally requires a non-aborted, nonempty run, a valid Git
  commit, and the same clean worktree snapshot before, between, and after all
  cases. Injected callbacks are test-only evidence and invalidate a live cell.
- Runs per case: `1`
- Temperature: `0.0`
- Maximum output tokens: `512`; receive timeout: `60,000ms`; default transient
  HTTP retry policy (`max_retries: 3`).
- No role/prelude overrides, custom memory cap, or unsafe-debug collector.
- Both persistent report and trace-directory paths are required.
- Cases: product count, delivered-order filter, revenue aggregation, remote
  employee filter, and multi-turn engineering-expense cross-dataset join.
- Oracle: the fail-closed `expect` plus `constraint` contract in
  `PtcRunner.Kernel.Eval.Oracle`. Seed-derived integer answers use exact
  equality; floating aggregates use a ±0.01 range around the host-computed
  answer.

The bundle component hashes, repository commit, model/provider identity, prompt
hashes, action hashes, trace paths, and trace write/drop integrity are recorded
by the generated report rather than copied into this document before the run.

## Cells and order

1. Incumbent shakedown.
2. Kernel cell.

Both cells use the same seed, suite, model alias, case order, and one replicate.
The incumbent runs first so a model/configuration failure is visible before any
kernel-specific attribution.

## Gate

- Smoke bar: at least 3 of 5 cases pass in each cell.
- Any trace write error, missing turn, unexpected turn, dataset-hash mismatch,
  missing report, or unknown oracle term fails the affected cell regardless of
  its returned answer.
- The `engineering_expenses` case must define `engineering-ids` in its first
  committed trace turn and require that persisted symbol at runtime in a later
  committed return-producing program. The host re-executes the definition to
  verify the exact host-derived ID set and requires it to be the only changed
  definition, then re-executes the terminal program against multiple
  program-derived ID subsets. Every returned value must equal the host-computed
  expense total for its exact subset; a counterfactual error does not. A dead
  reference, hard-coded answer, backup definition, rollback, or later read of
  `data/employees` fails the case as recomputation. Uncommitted attempts before
  the definition do not change which turn is first committed.
- Live adapters may translate provider envelopes but must not replace or
  rewrite model-authored PTC-Lisp programs.
- No retries, exclusions, prompt edits, suite edits, or stopping-rule changes
  are allowed after the paired live attempt starts. An exclusive attempt
  manifest is created before the first model request; canonical artifacts are
  create-once, and the manifest's terminal `completed` or `aborted` state is
  published last. Infrastructure failure stops the run and is recorded; it
  does not become a task failure.

## Commands

```console
mix ptc.kernel_eval --suite tier2 --live --model deepseek --runs 1 --seed 17 \
  --paired --allow-failures \
  --report reports/kernel_eval/m2-tier2.md
```

The paired manifest verifies distinct canonical paths and equality of commit,
resolved model, dataset hash, case-definition hash, and configuration hash.
Apply the preregistered `pass_count >= 3` gate to each child JSON report.
`--allow-failures` permits 3/5 or 4/5 task outcomes to be recorded; an
infrastructure-aborted pair remains invalid regardless of count.

## Explicit non-goals

- No statistical or superiority claim.
- No kernel-versus-incumbent optimization based on these five outcomes.
- No parallel `agent.core`, sessions, compaction, MCP, or self-improvement.
- R21/R22 and S11/S12 launch checks are closed in
  [`../m2-lifecycle-audit.md`](../m2-lifecycle-audit.md). This authorization is
  limited to the frozen sequential paired command below.

## Outcome

Not run. Lifecycle launch work is complete, the provider key/model resolution
is available, and mock mode passes both variants. The frozen paired live command
is ready to run from a clean worktree.
