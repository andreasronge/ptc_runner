# Shipped helper judge corpus

This no-model lab captures `prompt.audit/segments`, `measure`, `delta`, and
`cap/fold-pages` using the prelude-search Phase 0 freeze, inspection, and replay
path. It uses only pure callbacks and frozen pages. Prompt seeds come from the
existing prompt-audit fixtures and tests; pagination seeds come from the
cap/fold-pages tests. Each helper also has deterministic generated variations.

Regenerate the committed corpus from the repository root:

```console
mix run scripts/labs/helper-corpus/run.exs
```

Replay the committed corpus in a fresh VM:

```console
mix run scripts/labs/helper-corpus/run.exs --replay-artifacts scripts/labs/helper-corpus/corpus
```

`corpus/index.json` states the measurement boundary and lists unrepresented
source arms. Each helper's `executions.json` records the exact input, the
visible or withheld split, a declared branch intent, frozen bundle identity,
strict JSON result hash, failure envelope, aggregate Kernel usage, and elapsed
milliseconds. Branch labels declare intended paths; they are not measured
coverage. The split is checked for disjoint input values on generation.
The withheld values belong only in the retained corpus, never in a later
proposer's prompt. The `.ptcins` and trace files are inspection evidence;
keep the corpus private when adding any non-fixture inputs.

The replay command reconstructs frozen bundles from the corpus, checks artifact
and input digests, then compares result hashes. Failure outcomes use a strict
JSON hash of the published Kernel failure envelope together with the explicit
failure value; successful outcomes use the run-result hash. The test copies the
corpus, runs replay in a fresh VM, and checks both bundle identity and changed
results from a behavior-changing helper mutation.
