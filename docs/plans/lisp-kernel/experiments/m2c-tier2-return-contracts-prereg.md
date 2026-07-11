# M2c Tier 2 paired return-contract smoke preregistration

Date: 2026-07-11

## Purpose

Repeat the frozen Tier-2 pair with the same case-derived return contract
supplied to both adapters. The incumbent uses its existing SubAgent signature
validation; the kernel uses the new recoverable return-contract spike. M2c asks
whether model-visible, host-enforced terminal types resolve the scalar-envelope
failure class observed in M2/M2b.

This is a descriptive engineering comparison with M2 and M2b, not a powered
superiority experiment. M2 and M2b remain immutable failed gates.

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
  unsafe-debug collector, or stop-on-failure rule.
- Canonical report: `reports/kernel_eval/m2c-tier2.md`.

## Treatment

Pass `return_contracts: true` to both adapters. Derive contracts only from the
already-frozen case `expect` field:

- `:integer` -> `:int`
- `:number` / `:float` -> `:float`
- other supported oracle types use their corresponding existing signature
  type; unknown/`:any` uses `:any`.

The task, context, oracle, maximum turns, programs, model configuration, and
case order are unchanged. An invalid terminal value consumes a normal turn,
preserves committed memory, and returns bounded validation feedback. The host
oracle still scores only the final accepted value.

## Gate and endpoints

- Standing smoke gate: at least 3/5 independently in each cell.
- Primary descriptive endpoint: incumbent scalar type-mismatch count versus
  M2 and M2b.
- Secondary endpoints: per-cell pass count, validation-retry turns, kernel
  case stability, and `engineering_expenses` persistence outcome.
- Any abort, provenance/configuration ineligibility, trace-integrity failure,
  dataset/case hash mismatch, or incomplete pair fails the overall gate.
- No reruns, exclusions, prompt edits, or oracle edits after launch.

## Expected interpretation

Return contracts can correct terminal shape but cannot by themselves repair a
wrong computation or the known list-versus-set persistence-oracle mismatch. A
kernel result of 4/5 with the same engineering failure is therefore compatible
with a successful return-contract mechanism.

## Canonical command

```console
mix ptc.kernel_eval --suite tier2 --live --model deepseek --runs 1 --seed 17 \
  --paired --return-contracts --allow-failures \
  --report reports/kernel_eval/m2c-tier2.md
```

## Outcome

Run completed on 2026-07-11 at commit `d9472813`. The pair was complete,
non-aborted, provenance-eligible, and evidence-eligible. Both incumbent and
kernel passed 4/5, so the preregistered overall smoke gate passed. Canonical
evidence is in `reports/kernel_eval/m2c-tier2*`; comparison with M2/M2b is in
`reports/kernel_eval/m2c-analysis.md`.
