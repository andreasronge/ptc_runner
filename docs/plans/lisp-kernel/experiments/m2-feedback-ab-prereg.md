# M2 bounded-feedback A/B/C preregistration

Date: 2026-07-10

Status: registered before any live run of these refreshed cells. No outcome run
has been performed.

## Purpose and claim boundary

Run a descriptive feedback-policy shakedown after the M2 bounded-feedback
refresh. This is not the historical S19 experiment and must not inherit or
overwrite its outcome. Results may expose directional instability and safety
regressions; they do not support statistical superiority or an M3 claim.

## Frozen cells

All cells use `priv/preludes/agent/prompt.lisp` at source hash
`9bcaa98e2f05d8a1a08a1f44bbe3b1a5a23b27bbb6af33419d1582f5b1d556eb`
and `priv/preludes/agent/core.lisp` at source hash
`7465d62ddc39b73969860acd45604bccbb3537aa2962ce662430d98cd5ed429a`.

| Cell | Feedback policy | Source hash |
| --- | --- | --- |
| A | candidate baseline memory-summary guidance | `c7babc612f8e87a2556898ac4cea31668baa0ff73153636a48b38c1faa74ab0b` |
| B | explicit persisted-name reuse guidance | `d39fae64506909201a5b3c542b504713984656c9f133423d9414138874282c8c` |
| C | no memory-summary guidance | `ae83f8c52d178b906e2034c0937b7bc5b516825d4657ac67240e993db6d27e21` |

Each cell exports the same `feedback-max-chars` and
`feedback-truncation-hint` interface and applies the same bounded projection.
The cells differ only in memory-reuse guidance. None is an exact copy of the
deployed default: its normal retry instruction matches Cell C, while its
truncation fallback still states that persisted definitions remain available.

## Frozen execution

- Runner: `PtcRunner.Kernel.FeedbackAB` through `mix ptc.kernel_feedback_ab`.
- Suite: `mini`; cases and `max_turns` come from
  `PtcRunner.Kernel.Eval.mini_cases/0`.
- Case-definition hash:
  `754473db7fa9d831a22a5d108765e732b574ac8bfdb283e25ce03472a2da14e5`.
- Model: `deepseek`, resolved through `PtcRunner.LLM.Registry` at run time.
- LLM source must be `registry` and the top-level report must record
  `preregistered_config: true`, `complete: true`, and
  `evidence_eligible: true`. Eligibility requires the exact suite, all six
  cases, all three cells, five repeats, seed, requested model alias,
  temperature, token/timeout limits, case-definition hash, persistent top-level
  report path exactly `reports/kernel_eval/m2-feedback-ab-live.md`, and no
  early-stop or unsafe-debug option. Injected callbacks,
  selectors, altered parameters, and partial schedules are test/debug-only and
  ineligible.
- Every row must record the same valid Git commit, which is also recorded at
  the top level; a schedule spanning different commits is ineligible.
- Temperature: `0.0`.
- Maximum output tokens: `512`; receive timeout: `60,000ms`.
- Repeats: five per `{case_id, cell}`.
- Block order seed: `m2-feedback-ab-order-v1`.
- Preflight/setup failures exit before an outcome report because no cell has
  started; the command error is the diagnostic. After the first cell starts,
  abort on transport, trace-integrity, or provenance failures and do not rerun
  an undesirable model outcome. A runtime abort report retains all completed
  rows plus the abort reason and is written before the command exits
  unsuccessfully.
- Reports are new M2 artifacts and must not use the historical
  `s19-feedback-ab-live` path.

Exact command:

```bash
mix ptc.kernel_feedback_ab --live --model deepseek --runs 5 \
  --allow-failures --report reports/kernel_eval/m2-feedback-ab-live.md
```

## Endpoints and outcome

Primary descriptive endpoint: pass/fail by `{case_id, cell}`. Guard endpoints:
bounded feedback remains at most 4,096 characters, provenance hashes match,
and `memory_persistence` remains green in every cell. Secondary observations
are turns, eval counts, and sanitized trace integrity.

Outcome: not run.
