# M2c paired return-contract analysis

Date: 2026-07-11

## Verdict

M2c completed at commit `d9472813` with eligible evidence. Incumbent passed
4/5 and kernel passed 4/5. Both cells exceeded the preregistered 3/5 smoke bar,
so M2c passed its overall gate.

This does not replace the failed M2/M2b gates: M2c is a different treatment in
which both adapters receive model-visible, host-enforced return contracts.

## Comparison

| run | incumbent | kernel | incumbent scalar type mismatches | overall gate |
| --- | ---: | ---: | ---: | --- |
| M2 | 2/5 | 4/5 | 3 | fail |
| M2b | 2/5 | 4/5 | 3 | fail |
| M2c typed returns | 4/5 | 4/5 | 0 | pass |

The preregistered primary endpoint moved in the expected direction: incumbent
scalar-envelope failures fell from three to zero. It passed all four
single-dataset scalar tasks. This is direct descriptive evidence that the
return contract addresses the observed shape-compliance failure class.

## Retry and trajectory cost

The incumbent used 11 committed actions/evals across five cases in M2c:
1, 1, 3, 2, and 4. M2 used 13 and M2b used 9. The contract did not simply make
every task one-shot; it made invalid terminal shapes recoverable within the
existing turn budget.

The kernel used 8 actions/evals: four one-shot scalar successes and four turns
on `engineering_expenses`. M2 and M2b each used 6. Thus the treatment improved
paired gate correctness but did not reduce work uniformly.

## Engineering case

Both variants failed `engineering_expenses`, for different immediate reasons:

- Incumbent returned the correct numeric total but failed
  `required_persisted_value_not_defined`. Its first committed turn inspected
  samples rather than defining `engineering-ids`; later uncommitted errors and
  a terminal definition cannot satisfy the frozen first-committed-turn rule.
- Kernel defined `engineering-ids` on its first committed turn, then repeated
  the same non-returning definition program twice before returning `0.0` on the
  fourth turn. The host oracle therefore failed the numeric between constraint.

Return typing cannot repair either sequencing/persistence behavior or a wrong
numeric value. The kernel trace still confirms that return contracts leave the
known persistence task as the dominant unresolved case.

## Claim boundary

- M2c is one replicate per case with fixed order and one model.
- The suite and its failure modes have informed implementation.
- The comparison is descriptive and does not establish statistical or
  architectural superiority.
- Stronger claims require the registered cross-domain holdout and powered
  design.

## Recommendation

Promote recoverable return contracts from spike to supported kernel behavior
after API review and hardening. Keep the persistence task/oracle repair
separate: align its model-visible collection requirement with the hidden
extensional check and improve its failure taxonomy before using it again.
