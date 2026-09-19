# Corrective E1/E2 pilot artifacts

This directory retains experiment `prelude-search/002` for issue #1996.
It belongs on the retained experiment branch, not on main.

`authorization-and-budget.json` records the source revision, budget, and prior
validation reservations. `invocation.json`, `console.log`, and `completion.json`
record the actual invocation and termination. The launch supervisor enforces the
six-hour wall-clock limit and never restarts a stopped run. Credentials remain
outside this directory.

`live/` is written by the unchanged Phase 1 harness. Its protocol, per-case
applications, traces, private inspection records, selection results, and replay
fixtures are the measurement evidence. A case that stops before fixture export
may have raw evidence but no completed result row or replay fixture; that absence
must not be interpreted as zero cost or as a scored failure.

Reproduce a complete run with the exact options in `invocation.json`, using a
new output directory. For network-free replay, add `--replay --fixtures` pointing
to `live/fixtures`. The harness requires the saved protocol to match exactly and
checks fixture hashes. Partial-run replay coverage is recorded separately.

This run stopped on its second case with `llm_request_timeout`. The default
harness therefore did not write its terminal summary/index. `summarize.exs`
checks the retained stopped-case shape, indexes only existing fixtures, and
uses the harness report/comparison functions to generate report `002.json`.
It is experiment-specific and does not change the reusable harness.

Run `python3 research-artifacts/prelude-search/002/verify-replay.py` to compare
the retained live and replay prefixes. Run
`mix run research-artifacts/prelude-search/002/summarize.exs` to regenerate the
result file. No credentials are needed for either command. The full replay
command deliberately stops at the absent timeout fixture after verifying the
completed prefix; it must not be described as a successful full-matrix replay.

The retained selection trace and inspection can be copied into separate
profile input directories, then read with `mix ptc repl --profile
private-run-analysis-v2 --private-unattended`. For run
`cmd-7cvrzb4f83szap4h5h3fgt721r`, the `activity` collection shows twenty mission
`evaluation-stopped` events with status `continued`.
