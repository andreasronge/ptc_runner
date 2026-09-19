# Prelude-search 004: stopped corrective pilot

Artifact only; never merge. [Frozen authorization](https://github.com/andreasronge/ptc_runner/issues/1996#issuecomment-5744271571). Source `608c2a92d17a58164357d2d99f0cd201f5d8de7c`.

53 of 240 planned cases completed, then the next three-turn case stopped on `model_output_truncated` at 16384 output tokens. All completed cases replay exactly with zero new spend; the failed case is not synthesized or replayed. H1 remains inconclusive. Only thirteen full interval instances plus one additional one-turn case were completed; the other subjects were not reached.

Completed cost: 69916 microusd. Failed-case known cost recovered via private inspection: 3524 microusd. Actual known recording cost: 73440 microusd. Conservative accounting retains the full 100000 microusd failed-case reservation, so recording spent-or-reserved is 169916 microusd; remaining corrective allowance is 4513646 microusd. No restart occurred.

`invocation.json`, `live/protocol.json`, `completion.json`, `live/stopped-case.json` and `result.json` establish source, protocol, termination and measurements. `stopped-case-analysis.json` summarizes retained private queries proving output truncation rather than a request timeout. `analysis-findings.json` links the separate terminal mission diagnostic gap to #2021. Original absolute temporary paths document capture locations; use the relocated `traces/` and `inspection/` directories when opening them.

`replay/` is the complete finished-prefix replay. `prefix-validation/` is an earlier, explicitly labeled 32-case snapshot, not the final recording. Regenerate checks/results from the artifact branch root with:

```console
python3 research-artifacts/prelude-search/003/verify-replay.py research-artifacts/prelude-search/004
python3 research-artifacts/prelude-search/003/build-result.py research-artifacts/prelude-search/004
```

The separate report-only branch carries the interpretation and compact JSON. Keep raw model captures and fixtures on this artifact branch.
