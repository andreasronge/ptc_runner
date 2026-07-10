# M2b Tier 2 paired smoke preregistration

Date: 2026-07-10

## Purpose

Repeat the failed but eligible M2 paired smoke after adding observation-only
diagnostic tooling. M2b tests repeatability of the informal capability gate; it
is not a statistical comparison or an architecture-superiority claim. The M2
outcome remains immutable and is not replaced by this run.

The diagnostic rerun declared below may be inspected before M2b, but no prompt,
prelude, case, oracle, adapter, model, or runtime-policy change is permitted
between that diagnostic run and M2b. If diagnosis motivates such a change,
M2b is cancelled and a new preregistration is required after the change.

## Frozen inputs

- Suite: `tier2`; dataset seed: `17`; one run per case.
- Dataset hash:
  `503d8233cce08aa825a00e14d49c6e13d2a9db931fa219a8cc3500866e8a0953`.
- Case-definition hash:
  `4b448ecc370db8260cc8b4537bd7ed61ae9c8c0c0bbec80203d754d362df4431`.
- Model alias: `deepseek`, resolved once by the paired coordinator.
- Cell order: incumbent first, kernel second.
- Runs: `1`; temperature: `0.0`; maximum output tokens: `512`; receive
  timeout: `60,000ms`; transient HTTP retries: `3`.
- No case selection, role/prelude override, custom memory cap, injected LLM,
  stop-on-failure rule, or unsafe-debug collector.
- Canonical report: `reports/kernel_eval/m2b-tier2.md`, with coordinator-derived
  child reports and trace directories.
- Eligibility requires the same lifecycle, provenance, trace-integrity,
  repository, and create-once conditions as M2.

## Gate

- At least 3 of 5 cases pass independently in the incumbent cell.
- At least 3 of 5 cases pass independently in the kernel cell.
- Any abort, provenance/configuration ineligibility, trace-integrity failure,
  dataset/case hash mismatch, or incomplete pair fails the overall gate.
- The `engineering_expenses` persistence oracle is unchanged from M2.

## Diagnostic run

Before M2b, one full paired rerun may use `--unsafe-debug-report` with all
artifacts under a local temporary directory. It is diagnosis only:

- it must be marked evidence-ineligible by the harness;
- its raw report is mode `0600`, local-only, and must not be committed;
- it may inspect exact model-visible requests, responses, programs, and eval
  feedback;
- it cannot count toward M2 or M2b and cannot authorize a policy edit before
  M2b.

## Canonical command

```console
mix ptc.kernel_eval --suite tier2 --live --model deepseek --runs 1 --seed 17 \
  --paired --allow-failures \
  --report reports/kernel_eval/m2b-tier2.md
```

Apply `pass_count >= 3` separately to both child JSON reports.

## Interpretation

M2b is an engineering replication after the suite has already informed
analysis. Even if it passes, stronger efficacy or genericity claims require the
registered cross-domain holdout and a powered experiment. If M2b disagrees with
M2, report both outcomes and treat the difference as run-to-run instability.

## Outcome

Not run.
