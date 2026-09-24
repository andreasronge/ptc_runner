# Seeded debugging corpus packets

These 18 private packets are retained for issue #2057 at tag
`research/debug-efficiency/corpus-seeded-001`. The tag and its branch are a
research artifact; they are not merged into main. All labels remain
`adjudication: pending` until an independent adjudicator reviews them.

Each case directory contains its selected Phase 0 execution index, frozen
bundle source and manifest, canonical trace, `.ptcins` inspection snapshot,
and `packet.json`. Mutated cases retain a divergent oracle/observed pair and
the lab's `ground-truth.json` as a candidate cause. No-bug cases retain an
unmutated oracle execution. `packet.json` records the application revision,
seed, zero-based input index, exact input, bundle and artifact hashes, and
evidence IDs. `summary.json` indexes all packet hashes. The selected records
come from credential-free Phase 0 runs; no model was called.

From the repository root, verify every packet in a fresh VM:

```console
mix run scripts/labs/prelude-search/run.exs --replay-artifacts scripts/labs/debug-efficiency/corpus-seeded-001/cases
```

Replay reconstructs the frozen bundles and checks inspection and result
hashes. It does not adjudicate the candidate cause or disposition. Keep the
`.ptcins` files private.
