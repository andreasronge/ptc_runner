# Prelude-search lab

This credential-free maintainer lab is the Phase 0 harness for reproducible
prelude search. It is source-checkout tooling, not a shipped example, and it
never calls a model.

The lab contains three purpose-written PTC-Lisp subjects: interval merging,
text normalisation, and two-ledger reconciliation. For each subject it chooses
one of five seeded semantic mutations, freezes both the original and mutated
application bundles, and generates seeded inputs. The five mutation operators
are comparator flip, boundary off-by-one, dropped edge-case clause, swapped map
key, and a wrong private-helper default. `ground-truth.json` records the
subject, function, changed form, and operator.

Every input is run against both frozen bundles. The first four fifths of the
inputs are marked `visible`; the remainder are marked `held-out`. The oracle
result is retained only in the private lab artifacts and is not an input to
any later model phase. `reached_mutation` means that the observed result hash
differs from the oracle result hash. That difference is an intentional proxy
for reaching the mutation, not statement-level coverage.

Each recorded execution is a real PtcRunner run. It leaves a canonical JSONL
trace, a private `.ptcins` inspection artifact, and the missing run input as
`<run-ref>.input.json` under the subject's owner-only `artifacts/` directory.
`executions.json` indexes those files and records the visible/held-out split.

Phase 0 then reads each sidecar input, executes the same immutable in-memory
bundle again, and compares its strict JSON result hash with the `run-result`
hash decoded from the recorded inspection artifact. The final table reports
the number of recorded executions, equal and unequal hashes, and average
milliseconds per re-execution. Any unequal result fails the command and is a
runtime finding; do not discard or work around it.

Run all subjects with the default seed and 100 recorded executions per subject
(40 visible inputs and 10 held-out inputs, each run once as oracle and once as
observed):

```console
mix run scripts/labs/prelude-search/run.exs --phase 0
```

Select one subject, seed, execution count, or artifact directory:

```console
mix run scripts/labs/prelude-search/run.exs --phase 0 \
  --subject intervals --seed 20260917 --executions 10 --output /tmp/prelude-search
```

The execution count must be a positive even number because every generated
input has an oracle and observed execution. Treat the `.ptcins` files and the
oracle records as private even though Phase 0 uses no credentials.
