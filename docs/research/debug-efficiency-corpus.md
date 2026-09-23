# Debugging corpus feasibility inventory

This inventory was screened for #2028 on 2026-09-23. It contains **33 candidates and zero admission-ready incidents**. Candidate is not a scored observation. No private run captures or adjudicated case packets are committed here. The runnable seven-case fixture in `scripts/labs/debug-efficiency/` is synthetic and is not part of this corpus. Repair reports 002–004 and their artifacts remain outside this cohort.

An admission-ready packet needs a frozen application/source revision, the incident input, a canonical trace and authorized private inspection snapshot, a checkable cause or a documented insufficiency, the expected supporting evidence IDs, and an independent adjudicator's sign-off. The source mutation or issue reporter supplies a candidate label, never a substitute for this review. Missing capture is an **eligibility failure**, not a wrong diagnosis. None of the 33 enters a denominator until this packet exists.

## Seeded families: 21 candidates

The first 15 are the exact five mutation operators for each of three applications in [`mutations.exs`](../../scripts/labs/prelude-search/support/mutations.exs); [`inputs.exs`](../../scripts/labs/prelude-search/support/inputs.exs) defines candidate inputs. Their independent cause is the source replacement, checkable against the unmutated source and oracle behavior. Phase 0 can generate traces and `.ptcins` files, but no output directory from such a run is retained in this checkout. A mutation is not admitted merely because it exists: the chosen input must produce a verified oracle/observed difference and the captures must be preserved. Each row below lacks that capture and is excluded today.

| ID | Family (keep together) | Independently defined cause | Expected evidence / gap |
| --- | --- | --- | --- |
| I01 | intervals | `touches?` comparator flip | changed form + divergent boundary input; capture absent |
| I02 | intervals | `touches?` tolerance off by one | changed form + divergent tolerance input; capture absent |
| I03 | intervals | `ordered` swaps start/end branch | changed form + divergent reversed interval; capture absent |
| I04 | intervals | `extend` swaps map keys | changed form + divergent merge output; capture absent |
| I05 | intervals | `merge-with-tolerance` wrong default | changed form + omitted-tolerance input; capture absent |
| N01 | normaliser | `canonical-token` comparator flip | changed form + boundary-length token; capture absent |
| N02 | normaliser | `canonical-token` off-by-one threshold | changed form + boundary-length token; capture absent |
| N03 | normaliser | `finish-token` drops empty-token branch | changed form + separator input; capture absent |
| N04 | normaliser | `normalise` swaps result map keys | changed form + divergent result; capture absent |
| N05 | normaliser | `normalise` wrong minimum default | changed form + omitted-minimum input; capture absent |
| R01 | reconciliation | `classify` equality comparator flip | changed form + equal ledger entries; capture absent |
| R02 | reconciliation | `ledger-map` adds one to amount | changed form + divergent amount; capture absent |
| R03 | reconciliation | `classify` drops missing-right branch | changed form + missing-right entry; capture absent |
| R04 | reconciliation | `classify` swaps amount fields | changed form + divergent classification; capture absent |
| R05 | reconciliation | `ledger-map` wrong amount default | changed form + omitted amount; capture absent |
| I00 | intervals, no bug | unmutated oracle bundle | matching independent oracle/result hashes; capture absent |
| N00 | normaliser, no bug | unmutated oracle bundle | matching independent oracle/result hashes; capture absent |
| R00 | reconciliation, no bug | unmutated oracle bundle | matching independent oracle/result hashes; capture absent |

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
