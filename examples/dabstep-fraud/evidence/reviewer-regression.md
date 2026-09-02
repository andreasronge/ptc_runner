# Reviewer regression spike

Status: WIP, recorded 2026-09-02.

## What changed

- `agent.core/run-outcome` can retain a bounded `:execution` summary beside
  each admitted generated program. Continued programs include their bounded
  observation; terminal programs record `:returned`; failures retain bounded
  diagnostics without the raw value.
- The DABStep workflow gives Luna the task, input, analyzer result, and the
  successful DeepSeek REPL steps. Rolled-back failures remain in the retained
  outcome and private trace but are omitted from this read-only correctness
  review.
- The reviewer can use the same read-only payment functions to execute an
  independent calculation. Prompt rendering is shared by the normal workflow
  and a reviewer-only regression application.
- Two reviewer cases have live and replay projects. The nightly regression
  asserts the meaning of the finding, not merely that Luna returned a non-empty
  array.

The final short reviewer instruction is:

> Check the programs and independently solve the task with run_ptc_lisp.
> Compare your result with the analyzer result before approving.

## Cases and results

### Captured wrong metric

The case is reduced from DeepSeek run `cmd-40vw2hcbwe10tw74g84hqddg0d`.
DeepSeek calculated the correct country totals but ranked absolute fraudulent
volume, chose NL, and returned `A. NL`. The correct metric is fraudulent volume
divided by total volume, for which BE is first.

Live Luna run `cmd-5kc7h8h2xvh4bcrkkg9ac1hmt8` independently scanned the
dataset and reported that the candidate must be `B. BE`, not `A. NL`.

### Seeded off by one

The analyzer program applies `(rest (get page "rows"))` on every page. The
fixture totals are the real output of that program, calculated through the
`analysis` mission REPL; it drops the first data row of every page. The winning
answer happens to remain `B. BE`, so a useful reviewer must identify the
unsupported totals rather than only compare answer strings.

Live Luna run `cmd-5kcrqw3agna5zxqmthcq4m5yxg` independently scanned all rows
and reported the exact `rest`/first-row/page defect.

## Prompt findings

The original optional wording was insufficient:

- `cmd-5p4sc546wzk1bvkyhjdfczwhj1` called only `fraud-definition` and approved
  the wrong-metric result.
- `cmd-76wkc8m9dngmrma5zpb0mmj171` did scan the data, but repeated the same
  absolute-volume mistake and approved.
- `cmd-6r9h2e28xmt0sczqbxv6d08mmm` returned a finding for the off-by-one case,
  but the finding itself was wrong: it selected NL by absolute volume and did
  not identify the pagination defect.

Requiring an independent solution and comparison produced the two accepted
live results above. Both successful sessions used two Luna turns. Contract
correction handled an exploratory first return with the wrong findings shape;
the corrected second return contained the final finding.

## Deterministic coverage

- `reviewer-replay.jsonl` records the two successful Luna exchanges.
- `ptc-project.reviewer-replay.json` runs without a model credential while
  executing Luna's recorded verification programs against the pinned data.
- `test/ptc_runner/kernel/dabstep_reviewer_regression_test.exs` is a nightly
  test because it launches the filesystem MCP process and scans the dataset.
- The focused nightly run passed: 2 tests, 0 failures.
- The focused agent-library and dependency tests passed: 164 tests, 0 failures.
- The refreshed full DeepSeek → DeepSeek → Luna replay passed and returned
  `{"ok":true,"value":"B. BE"}`.

## Remaining questions

- One successful recording proves the workflow and provides a stable
  regression; it does not estimate Luna's live detection rate. A later cohort
  can measure that separately without weakening the deterministic tests.
- The retained execution shape is still a spike-level API decision. Before a
  final PR, review its disclosure boundary, fixed per-entry observation cap,
  and returned-value omission once more.
- Failure filtering is intentionally an application policy. It is safe here
  because every mission effect is read-only; workflows with irreversible
  effects must not assume a failed evaluation had no external effect.
