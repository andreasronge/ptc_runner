# M2b Tier-2 analysis

Date: 2026-07-10

## Verdict

M2b was complete, non-aborted, and evidence-eligible at commit `27b49379`.
Kernel passed 4/5 and incumbent passed 2/5. The preregistered overall gate
failed because each cell independently required at least 3/5.

M2b exactly repeated M2's aggregate scores. Kernel also repeated the same four
passing cases and the same `engineering_expenses` failure. Incumbent repeated
2/5 but passed a different subset, so its aggregate is stable while its
case-level behavior is not.

## Diagnostic method

Before M2b, the preregistered ineligible paired diagnostic run captured exact
model-visible requests, model responses/programs, and evaluation results in a
local mode-`0600` report under `/tmp`. It used the same commit and frozen inputs
as M2b. No prompt, prelude, case, oracle, adapter, or runtime-policy change was
made between the diagnostic run and M2b. The private artifact is not evidence
and is not committed.

## Incumbent finding: output contract, not arithmetic

The diagnostic incumbent again scored 2/5, but it computed all five expected
numeric values. Its three failures wrapped correct scalars in one-entry maps.
The exact prompt explains the tendency: the return section demonstrates map
envelopes in both its bad and generic return examples even though the missions
request scalar values. Across M2, the diagnostic run, and M2b, map wrapping
moves between cases rather than tracking task difficulty.

This is evidence of unstable output-shape compliance under contradictory UX,
not evidence that the incumbent cannot perform the underlying filters,
aggregations, or persistence task. The typed oracle is correct to fail maps,
but the incumbent prompt should state that the returned value must match the
mission's requested type and should include scalar examples.

## Kernel finding: persistence occurred, representation gate failed

The diagnostic kernel first changed exactly the binding `engineering-ids`, and
the next model request received feedback listing that persisted binding. Its
terminal program read `engineering-ids` and returned the correct total. The
model therefore satisfied the visible persistence behavior.

The first program stored the 34 correct IDs as a list. The hidden persistence
oracle compares the re-executed value to a `MapSet` before dependency
counterfactuals run, so it emitted `required_persisted_value_not_defined` even
though the binding existed, contained the correct members, and was read by the
terminal program. M2b's safe trace independently confirms that the first turn
changed `engineering-ids`.

This exposes two evaluation defects:

1. The model-visible mission says to define `engineering-ids`; it does not
   require a set representation, while the hidden oracle does.
2. `required_persisted_value_not_defined` conflates a missing definition with
   a present value of the wrong representation or value.

The M2 and M2b verdicts remain unchanged because their preregistered oracle was
applied as frozen. For a future suite, either require a set explicitly in the
mission or compare the persisted ID collection extensionally before running
the existing dependency counterfactuals. Use distinct failure reasons for
missing, wrong value, wrong representation, and unused persistence.

## Repeatability and claim boundary

- Kernel: 4/5 in M2, diagnostic, and M2b, with the same failing case. This is
  strong descriptive repeatability for this five-case smoke.
- Incumbent: 2/5 in all three runs, but the passing cases changed. The stable
  aggregate masks substantial case-level variance.
- Neither result supports statistical superiority: there is one replicate per
  case, fixed order, one model, and a suite already used for diagnosis.
- A future comparative claim needs the registered holdout and powered design.

## Recommended next work

1. Treat M2/M2b as completed failed gates; do not rerun until behavior or the
   evaluation contract intentionally changes under a new preregistration.
2. Fix incumbent return-shape guidance generically, without case vocabulary.
3. Repair the persistence task/oracle alignment and failure taxonomy.
4. Add safe result-shape diagnostics and a case-oriented private viewer under
   R19/R27; retain raw cassettes only by explicit local opt-in.
5. Validate changes on mock/integration tests, then use a new cross-domain
   holdout rather than optimizing claims on these five known cases.
