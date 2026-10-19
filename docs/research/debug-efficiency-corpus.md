# Debugging corpus feasibility inventory

This inventory was screened for #2028 on 2026-09-23. It contains **33 candidates and zero admission-ready incidents**. Candidate is not a scored observation. The 18 prelude-search candidates have retained captures awaiting adjudication ([below](#retained-seeded-packets)); no private run captures or adjudicated case packets are committed here. The runnable seven-case fixture in `scripts/labs/debug-efficiency/` is synthetic and is not part of this corpus. Repair reports 002–004 and their artifacts remain outside this cohort.

An admission-ready packet needs a frozen application/source revision, the incident input, a canonical trace and authorized private inspection snapshot, a checkable cause or a documented insufficiency, the expected supporting evidence IDs, and an independent adjudicator's sign-off. The source mutation or issue reporter supplies a candidate label, never a substitute for this review. Missing capture is an **eligibility failure**, not a wrong diagnosis. None of the 33 enters a denominator until this packet exists.

## Seeded families: 21 candidates

The first 15 are the exact five mutation operators for each of three applications in [`mutations.exs`](../../scripts/labs/prelude-search/support/mutations.exs); [`inputs.exs`](../../scripts/labs/prelude-search/support/inputs.exs) defines candidate inputs. Their independent cause is the source replacement, checkable against the unmutated source and oracle behavior. A mutation is not admitted merely because it exists: the chosen input must produce a verified oracle/observed difference and the captures must be preserved. The 18 rows below now have that capture, retained off main; each stays excluded until an independent adjudicator signs it.

| ID | Family (keep together) | Independently defined cause | Expected evidence / gap |
| --- | --- | --- | --- |
| I01 | intervals | `touches?` comparator flip | changed form + divergent boundary input; captured, adjudication pending |
| I02 | intervals | `touches?` tolerance off by one | changed form + divergent tolerance input; captured, adjudication pending |
| I03 | intervals | `ordered` swaps start/end branch | changed form + divergent reversed interval; captured, adjudication pending |
| I04 | intervals | `extend` swaps map keys | changed form + divergent merge output; captured, adjudication pending |
| I05 | intervals | `merge-with-tolerance` wrong default | changed form + omitted-tolerance input; captured, adjudication pending |
| N01 | normaliser | `canonical-token` comparator flip | changed form + boundary-length token; captured, adjudication pending |
| N02 | normaliser | `canonical-token` off-by-one threshold | changed form + boundary-length token; captured, adjudication pending |
| N03 | normaliser | `finish-token` drops empty-token branch | changed form + separator input; captured, adjudication pending |
| N04 | normaliser | `normalise` swaps result map keys | changed form + divergent result; captured, adjudication pending |
| N05 | normaliser | `normalise` wrong minimum default | changed form + omitted-minimum input; captured, adjudication pending |
| R01 | reconciliation | `classify` equality comparator flip | changed form + equal ledger entries; captured, adjudication pending |
| R02 | reconciliation | `ledger-map` adds one to amount | changed form + divergent amount; captured, adjudication pending |
| R03 | reconciliation | `classify` drops missing-right branch | changed form + missing-right entry; captured, adjudication pending |
| R04 | reconciliation | `classify` swaps amount fields | changed form + divergent classification; captured, adjudication pending |
| R05 | reconciliation | `ledger-map` wrong amount default | changed form + omitted amount; captured, adjudication pending |
| I00 | intervals, no bug | unmutated oracle bundle | matching independent oracle/result hashes; captured, adjudication pending |
| N00 | normaliser, no bug | unmutated oracle bundle | matching independent oracle/result hashes; captured, adjudication pending |
| R00 | reconciliation, no bug | unmutated oracle bundle | matching independent oracle/result hashes; captured, adjudication pending |

### Retained seeded packets

[#2057](https://github.com/andreasronge/ptc_runner/issues/2057) captured all 18 prelude-search candidates with Phase 0, without a model call, at source revision `4e03b2061e6f70750fee78593e568c70ab75d7c7`. The packets contain private inspection records, so they live only on tag `research/debug-efficiency/corpus-seeded-001` (commit `ab72b5a96`), under `scripts/labs/debug-efficiency/corpus-seeded-001/`; that tag is never merged. Every mutation produced an oracle/observed difference on the selected input, so none is ineligible. Each no-bug case retains an unmutated run whose result matches the independent oracle hash. Every packet records `adjudication: pending`.

The seed fixes the operator (`rem(seed, 5)`), the input index is zero-based into that seed's Phase 0 inputs, and the packet digest covers the frozen bundles, input, trace, inspection snapshot and result hashes listed in the tag's `summary.json`. All 18 replayed with 0 mismatches on main `c7cb05523` (2026-10-12):

```console
mix run scripts/labs/prelude-search/run.exs --replay-artifacts <checkout of the tag>/scripts/labs/debug-efficiency/corpus-seeded-001/cases
```

| ID | Eligibility | Seed | Input index | Executions | Packet SHA-256 |
| --- | --- | --- | --- | --- | --- |
| I00 | eligible | 20260920 | 0 | 10 | `4b6ac793eace863b5833261b64741eab825dbbba643d12ad0e6654d1b94d96fb` |
| I01 | eligible | 20260920 | 0 | 10 | `572c2f8fedf6782d0d0ad69672adcc7271b620f4ecd0ba18d3df3ddb1bdb5082` |
| I02 | eligible | 20260921 | 1 | 10 | `473e42447e36810c8590aff826c2965c0c24a1f40a0033efaf21d00a82dc817b` |
| I03 | eligible | 20260922 | 0 | 10 | `59a1c441493b9ff96be7a82ba3135084ade00d87511e4ecc94d2b486720cbb08` |
| I04 | eligible | 20260923 | 0 | 10 | `957d60fbe37baaedcf6a37c724ed9e03f5134f8d1a9d7c8df6561ba9c48e5dc4` |
| I05 | eligible | 20260924 | 5 | 20 | `89cb0cd8ec288e7e30c954086f0e9b106652fd5a122eade78b82f9f43af6ca1e` |
| N00 | eligible | 20260920 | 0 | 10 | `40d9800225a1d95ff6a57a89f2fa06c330c07605177ccfd8a5cd4067fe14f6b4` |
| N01 | eligible | 20260920 | 0 | 10 | `71fc49950c4886bee4ff0215840f6a90a94af2920bf3c4d373a90cdb2764c948` |
| N02 | eligible | 20260921 | 0 | 10 | `8213c85ed7299e88a964a28c81d30fda96107610aa9668e2a5b045267f8d35b0` |
| N03 | eligible | 20260922 | 2 | 10 | `705fcfba7cd7d37d853683ba7c54c2004f2f11996885b86f8a36ecebe863e2d0` |
| N04 | eligible | 20260923 | 0 | 10 | `e9a7068d18e6822f4adb074db5c7b9e2f1e7b8068710f102872496118ab5b05b` |
| N05 | eligible | 20260924 | 0 | 10 | `47a618d04d3bd26e9f3d18da6bbaaf749b3bb3ccdcb1e6e7c674c2e5ac788794` |
| R00 | eligible | 20260920 | 0 | 10 | `522c50f6d8669a49fefa5a3af02cb96f9e4edfd2dfbf2c37dea67d3e82491987` |
| R01 | eligible | 20260920 | 0 | 10 | `fe7d46525b815b0361c4491c0954e9dc74a8e39c992903725a022f194d11f9a9` |
| R02 | eligible | 20260921 | 0 | 10 | `9ff246952e98f50a50223e47d9df12f79cf083eb86f7958665ea7709e4675dc6` |
| R03 | eligible | 20260922 | 0 | 10 | `e75bb17eec93ed7b58d4b231a83f0ec07b4ae7574eca15f2e4de19ae6b1527f7` |
| R04 | eligible | 20260923 | 1 | 10 | `710d5aec8e5e5819951c9d336f7e44e0b6f4101e1a3334f5c7f506e729e83080` |
| R05 | eligible | 20260924 | 0 | 10 | `f6a60a6914c2b906e60ecd6ccf49076711847ba718971aa7930e3c975f2df870` |

The three shipped [debugging example variants](../../examples/debug-a-failed-run/variants/README.md) add distinct application shapes. The [command-boundary tests](../../test/ptc_runner/kernel/debug_a_failed_run_example_test.exs) check the first and third; the second is intentionally underdetermined. Their test assertions and source are checkable candidate labels, but the test-created captures are temporary, so all remain excluded.

| ID | Family | Candidate cause or correct disposition | Expected evidence / gap |
| --- | --- | --- | --- |
| D01 | pricing dependency | reached `pricing.rule` adds 2 to subtotal | generated call, reached source, observed expected total; retained capture absent |
| D02 | ambiguous pricing | two components fit one observation; abstain | both implementations and one observation; need a second discriminating capture |
| D03 | fulfillment workflow | `main` passes order ID instead of returned reservation ID | generated shipping call and inventory result; retained capture absent |

## Real regression families: 12 candidates

These are reported incidents, with provenance linked to the original issue. The issue narrative is **provisional** ground truth, even where a fix exists. Independent adjudication must inspect the reproducer and fixing test/diff, then freeze a capture from the affected revision. The gap for every row is that no such paired capture and signed label is retained here. Each is excluded. Closely related issues stay in one family; #1866 consolidates #1861/#1862, so those two are *one* candidate rather than two incidents.

| ID | Family | Provenance and reported cause/evidence to verify |
| --- | --- | --- |
| G01 | limits | [#2014](https://github.com/andreasronge/ptc_runner/issues/2014): two binding workflow clocks; verify default/raised-limit reproduction |
| G02 | gateway | [#1984](https://github.com/andreasronge/ptc_runner/issues/1984): one-run reservation still releasing; verify release client journey |
| G03 | artifact root | [#1924](https://github.com/andreasronge/ptc_runner/issues/1924): task timeout under full-suite load; verify failing seed and test fix |
| G04 | provider cleanup | [#1904](https://github.com/andreasronge/ptc_runner/issues/1904): launcher watchdog extends close; verify timing/cleanup trace |
| G05 | provider cleanup | [#1905](https://github.com/andreasronge/ptc_runner/issues/1905): cleanup reason lost; verify failed close and diagnostic fix |
| G06 | REPL argument diagnostics | [#1866](https://github.com/andreasronge/ptc_runner/issues/1866): invalid arguments withheld / one-eval routing; verify both reproductions as one family packet |
| G07 | artifact publication | [#1856](https://github.com/andreasronge/ptc_runner/issues/1856): shared output/envelope race; verify concurrent command outputs |
| G08 | artifact publication | [#1855](https://github.com/andreasronge/ptc_runner/issues/1855): interruption leaves no published evidence; verify staged files and signal behavior |
| G09 | CLI compile | [#1850](https://github.com/andreasronge/ptc_runner/issues/1850): compile failure lacks actionable diagnostic; verify provided manifest and CLI output |
| G10 | inspection count | [#1828](https://github.com/andreasronge/ptc_runner/issues/1828): turns discarded in count materialization; verify snapshot and fix |
| G11 | trace capacity | [#1810](https://github.com/andreasronge/ptc_runner/issues/1810): normal event bound kills run; verify boundary reproduction and trace |
| G12 | acquisition | [#1825](https://github.com/andreasronge/ptc_runner/issues/1825): captured document charged twice; verify descriptor and accounting test |

The reported bugs include different user surfaces, but several share an application or failure family. A future split must keep I, N, R, D, provider cleanup, REPL, and artifact publication groups intact. Proposed development groups are I, N, D and REPL; untouched evaluation groups are R, gateway, limits, artifact root, provider cleanup, artifact publication, CLI, inspection, trace and acquisition. This is a **proposed partition**, not a frozen evaluation set. Screening may move whole families before any model is run; it may not move cases after seeing evaluation answers.

## Eligibility and effort decision

[#2021](https://github.com/andreasronge/ptc_runner/issues/2021) demonstrates that a final handled mission evaluation may have source and status but no authoritative diagnostic. A case needing that error cannot be labeled answerable from the current private snapshot. It must await a capture fix and a new capture, or be labeled insufficient evidence by independent review. D02 is intentionally insufficient even with complete available evidence. An absent capture is exclusion, not D02-like abstention.

The preparation used approximately 0.2 engineering day in this worktree (source/issue screening, inventory, synthetic runner and validation). No #2030 Jev lab hardening was attempted; the shared proposed two-day cap has about 1.8 days remaining. The target of 30–50 *eligible* incidents is not established. The gap is 33 retained, independently adjudicated packets, including no-bug and insufficient-evidence packets. Stop corpus admission here; creating or claiming them without captures would manufacture coverage.
